{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent                    (forkIO, threadDelay)
import           Control.Concurrent.MVar               (newEmptyMVar, putMVar,
                                                        takeMVar)
import           Control.Exception                     (SomeException,
                                                        fromException, throwIO,
                                                        try)
import           Control.Monad.IO.Class                (liftIO)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Builder               as Builder
import qualified Data.ByteString.Lazy                  as LBS
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (NodeAddress (..))
import           Database.Redis.Internal.MultiplexPool
import           Database.Redis.Resp                   (Encodable (..),
                                                        RespData (..))
import           Test.Hspec

-- ---------------------------------------------------------------------------
-- Mock client for testing without a real Redis connection
-- (Same pattern as MultiplexerSpec)
-- ---------------------------------------------------------------------------

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef ByteString)   -- sendBuf
                -> !(IORef [ByteString]) -- recvQueue
                -> !(IORef Int)          -- closeCount
                -> !Bool                 -- failSend
                -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close (MockConnected _ _ closeCount _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send (MockConnected sendBuf _ _ failSend) lbs = liftIO $
    if failSend
      then throwIO $ userError "injected send failure"
      else do
        let !bs = LBS.toStrict lbs
        atomicModifyIORef' sendBuf $ \old -> (old <> bs, ())
  receive (MockConnected sRef recvQueue _ _) = liftIO $ recvLoop sRef recvQueue

recvLoop :: IORef ByteString -> IORef [ByteString] -> IO ByteString
recvLoop sRef recvQueue = do
  mChunk <- atomicModifyIORef' recvQueue $ \xs ->
    case xs of
      []     -> ([], Nothing)
      (y:ys) -> (ys, Just y)
  case mChunk of
    Just chunk -> return chunk
    Nothing -> do
      threadDelay 1000
      recvLoop sRef recvQueue

createMockClient :: IO (MockClient 'Connected, ByteString -> IO ())
createMockClient = do
  sendBuf <- newIORef BS.empty
  recvQueue <- newIORef []
  closeCount <- newIORef 0
  let client = MockConnected sendBuf recvQueue closeCount False
      addRecv bs = atomicModifyIORef' recvQueue $ \xs -> (xs ++ [bs], ())
  return (client, addRecv)

createTrackedClient
  :: IORef Int
  -> Bool
  -> IO (MockClient 'Connected, ByteString -> IO ())
createTrackedClient closeCount failSend = do
  sendBuf <- newIORef BS.empty
  recvQueue <- newIORef []
  let client = MockConnected sendBuf recvQueue closeCount failSend
      addRecv bs = atomicModifyIORef' recvQueue $ \xs -> (xs ++ [bs], ())
  return (client, addRecv)

-- | Total version of 'head' that avoids the -Wx-partial warning in tests.
firstOf :: [a] -> a
firstOf (x:_) = x
firstOf []    = error "firstOf: empty list"

encodeResp :: RespData -> ByteString
encodeResp = LBS.toStrict . Builder.toLazyByteString . encode

encodeCmd :: [ByteString] -> Builder.Builder
encodeCmd args =
  Builder.byteString ("*" <> bshow (length args) <> "\r\n")
  <> foldMap (\a -> Builder.byteString ("$" <> bshow (BS.length a) <> "\r\n" <> a <> "\r\n")) args
  where bshow x = LBS.toStrict (Builder.toLazyByteString (Builder.intDec x))

-- | A mock connector that creates MockClients and tracks per-node addRecv functions.
-- Returns (connector, getAddRecv) where getAddRecv retrieves the addRecv function
-- for a specific node after it has been connected.
type AddRecvMap = IORef [(NodeAddress, ByteString -> IO ())]

createMockConnector :: IO (NodeAddress -> IO (MockClient 'Connected), AddRecvMap)
createMockConnector = do
  mapRef <- newIORef []
  let connector addr = do
        (client, addRecv) <- createMockClient
        atomicModifyIORef' mapRef $ \xs -> (xs ++ [(addr, addRecv)], ())
        return client
  return (connector, mapRef)

createCountingConnector
  :: Maybe Int
  -> Bool
  -> IO
       ( NodeAddress -> IO (MockClient 'Connected)
       , AddRecvMap
       , IORef Int
       , IORef Int
       )
createCountingConnector failAt firstSendFails = do
  mapRef <- newIORef []
  attempts <- newIORef 0
  closeCount <- newIORef 0
  let connector addr = do
        attempt <- atomicModifyIORef' attempts $ \count ->
          let next = count + 1
          in (next, next)
        case failAt of
          Just failureIndex | attempt == failureIndex ->
            throwIO $ userError "injected connector failure"
          _ -> do
            (client, addRecv) <-
              createTrackedClient closeCount (firstSendFails && attempt == 1)
            atomicModifyIORef' mapRef $ \xs -> (xs ++ [(addr, addRecv)], ())
            return client
  return (connector, mapRef, attempts, closeCount)

-- | Get addRecv functions for a given node address.
getAddRecvs :: AddRecvMap -> NodeAddress -> IO [ByteString -> IO ()]
getAddRecvs mapRef addr = do
  xs <- readIORef mapRef
  return [f | (a, f) <- xs, a == addr]


-- ---------------------------------------------------------------------------
-- Test nodes
-- ---------------------------------------------------------------------------

node1, node2, node3 :: NodeAddress
node1 = NodeAddress "127.0.0.1" 6379
node2 = NodeAddress "127.0.0.2" 6380
node3 = NodeAddress "127.0.0.3" 6381

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  roundRobinSpec
  lazyCreationSpec
  multiNodeRoutingSpec
  poolClosureSpec
  constructionFailureSpec
  replacementFailureSpec
  askingSpec

roundRobinSpec :: Spec
roundRobinSpec = describe "Round-robin routing" $ do
  it "sequential submits to same node rotate across multiplexers" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 3  -- 3 muxes per node

    -- First submit triggers lazy creation of 3 multiplexers for node1
    addRecvFns <- do
      -- We need to feed responses for the first command to trigger creation,
      -- but the connector creates clients lazily. Submit from a thread and
      -- then feed responses once the connections are established.
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- submitToNode pool node1 (encodeCmd ["PING"])
        putMVar resultMVar r

      -- Wait for connections to be created
      threadDelay 50000
      fns <- getAddRecvs addRecvMap node1
      -- Should have 3 connections (one per mux)
      length fns `shouldBe` 3

      -- Feed response to first mux (round-robin starts at 0)
      (firstOf fns) (encodeResp (RespSimpleString "PONG1"))
      r <- takeMVar resultMVar
      r `shouldBe` RespSimpleString "PONG1"
      return fns

    -- Second submit should go to mux index 1
    do
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- submitToNode pool node1 (encodeCmd ["PING"])
        putMVar resultMVar r
      threadDelay 10000
      (addRecvFns !! 1) (encodeResp (RespSimpleString "PONG2"))
      r <- takeMVar resultMVar
      r `shouldBe` RespSimpleString "PONG2"

    -- Third submit should go to mux index 2
    do
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- submitToNode pool node1 (encodeCmd ["PING"])
        putMVar resultMVar r
      threadDelay 10000
      (addRecvFns !! 2) (encodeResp (RespSimpleString "PONG3"))
      r <- takeMVar resultMVar
      r `shouldBe` RespSimpleString "PONG3"

    -- Fourth submit should wrap around to mux index 0
    do
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- submitToNode pool node1 (encodeCmd ["PING"])
        putMVar resultMVar r
      threadDelay 10000
      (firstOf addRecvFns) (encodeResp (RespSimpleString "PONG4"))
      r <- takeMVar resultMVar
      r `shouldBe` RespSimpleString "PONG4"

    closeMultiplexPool pool

  it "single multiplexer skips round-robin counter" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 1  -- single mux per node

    -- Submit multiple commands — all go to the same (only) mux
    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar resultMVar r
    threadDelay 50000
    fns <- getAddRecvs addRecvMap node1
    length fns `shouldBe` 1
    (firstOf fns) (encodeResp (RespSimpleString "OK"))
    r1 <- takeMVar resultMVar
    r1 `shouldBe` RespSimpleString "OK"

    -- Second command still goes to same mux
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar resultMVar r
    threadDelay 10000
    (firstOf fns) (encodeResp (RespSimpleString "OK2"))
    r2 <- takeMVar resultMVar
    r2 `shouldBe` RespSimpleString "OK2"

    closeMultiplexPool pool

lazyCreationSpec :: Spec
lazyCreationSpec = describe "Lazy creation" $ do
  it "node muxes created on first access, not at pool creation" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 2

    -- At creation, no connections should exist
    fns <- getAddRecvs addRecvMap node1
    length fns `shouldBe` 0

    -- Access node1 — should trigger creation
    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar resultMVar r
    threadDelay 50000

    -- Now node1 should have 2 connections
    fns1 <- getAddRecvs addRecvMap node1
    length fns1 `shouldBe` 2

    -- node2 should still have 0
    fns2 <- getAddRecvs addRecvMap node2
    length fns2 `shouldBe` 0

    -- Feed response and clean up
    (firstOf fns1) (encodeResp (RespSimpleString "OK"))
    _ <- takeMVar resultMVar

    closeMultiplexPool pool

  it "second access to same node reuses existing muxes" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 2

    -- First access creates muxes
    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar resultMVar r
    threadDelay 50000
    fns1 <- getAddRecvs addRecvMap node1
    (firstOf fns1) (encodeResp (RespSimpleString "OK"))
    _ <- takeMVar resultMVar

    -- Second access should NOT create new connections
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar resultMVar r
    threadDelay 10000
    fns2 <- getAddRecvs addRecvMap node1
    -- Still only 2 connections (not 4)
    length fns2 `shouldBe` 2

    -- Feed response via the second mux (round-robin moved to index 1)
    (fns2 !! 1) (encodeResp (RespSimpleString "OK2"))
    _ <- takeMVar resultMVar

    closeMultiplexPool pool

multiNodeRoutingSpec :: Spec
multiNodeRoutingSpec = describe "Multi-node routing" $ do
  it "commands to different nodes use different multiplexers" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 1

    -- Submit to node1
    r1MVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["SET", "k1", "v1"])
      putMVar r1MVar r
    threadDelay 50000

    -- Submit to node2
    r2MVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node2 (encodeCmd ["SET", "k2", "v2"])
      putMVar r2MVar r
    threadDelay 50000

    -- Verify both nodes got separate connections
    fns1 <- getAddRecvs addRecvMap node1
    fns2 <- getAddRecvs addRecvMap node2
    length fns1 `shouldBe` 1
    length fns2 `shouldBe` 1

    -- Feed different responses to confirm independent routing
    (firstOf fns1) (encodeResp (RespSimpleString "OK1"))
    (firstOf fns2) (encodeResp (RespSimpleString "OK2"))

    r1 <- takeMVar r1MVar
    r2 <- takeMVar r2MVar
    r1 `shouldBe` RespSimpleString "OK1"
    r2 `shouldBe` RespSimpleString "OK2"

    closeMultiplexPool pool

  it "three nodes each get independent multiplexer groups" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 2

    -- Access all three nodes
    mvars <- mapM (\node -> do
      mv <- newEmptyMVar
      _ <- forkIO $ do
        r <- submitToNode pool node (encodeCmd ["PING"])
        putMVar mv r
      return mv
      ) [node1, node2, node3]
    threadDelay 50000

    -- Each node should have exactly 2 connections
    mapM_ (\node -> do
      fns <- getAddRecvs addRecvMap node
      length fns `shouldBe` 2
      ) [node1, node2, node3]

    -- Feed responses and verify
    mapM_ (\(node, mv) -> do
      fns <- getAddRecvs addRecvMap node
      (firstOf fns) (encodeResp (RespSimpleString "PONG"))
      r <- takeMVar mv
      r `shouldBe` RespSimpleString "PONG"
      ) (zip [node1, node2, node3] mvars)

    closeMultiplexPool pool

poolClosureSpec :: Spec
poolClosureSpec = describe "Pool closure" $ do
  it "closes transports once and rejects later submissions without reconnecting" $ do
    (connector, addRecvMap, attempts, closeCount) <-
      createCountingConnector Nothing False
    pool <- createMultiplexPool connector 1

    -- Create muxes for two nodes
    r1MVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["PING"])
      putMVar r1MVar r
    threadDelay 50000
    fns1 <- getAddRecvs addRecvMap node1
    (firstOf fns1) (encodeResp (RespSimpleString "OK"))
    _ <- takeMVar r1MVar

    r2MVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node2 (encodeCmd ["PING"])
      putMVar r2MVar r
    threadDelay 50000
    fns2 <- getAddRecvs addRecvMap node2
    (firstOf fns2) (encodeResp (RespSimpleString "OK"))
    _ <- takeMVar r2MVar

    closeMultiplexPool pool
    closeMultiplexPool pool
    readIORef attempts `shouldReturn` 2
    readIORef closeCount `shouldReturn` 2

    result <- try (submitToNode pool node1 $ encodeCmd ["PING"])
      :: IO (Either SomeException RespData)
    result `shouldSatisfy` \case
      Left err -> fromException err == Just MultiplexPoolClosed
      Right _  -> False
    readIORef attempts `shouldReturn` 2
    readIORef closeCount `shouldReturn` 2

  it "closeMultiplexPool on empty pool does not crash" $ do
    (connector, _) <- createMockConnector
    pool <- createMultiplexPool connector 2
    -- Close without ever using it
    closeMultiplexPool pool
    -- Close again — should be idempotent
    closeMultiplexPool pool

constructionFailureSpec :: Spec
constructionFailureSpec = describe "Partial multiplexer construction" $
  mapM_ (\failureIndex ->
    it ("closes all transports created before connector failure " <> show failureIndex) $ do
      (connector, _, attempts, closeCount) <-
        createCountingConnector (Just failureIndex) False
      pool <- createMultiplexPool connector 3

      result <- try (submitToNode pool node1 $ encodeCmd ["PING"])
        :: IO (Either SomeException RespData)
      result `shouldSatisfy` either (const True) (const False)
      readIORef attempts `shouldReturn` failureIndex
      readIORef closeCount `shouldReturn` (failureIndex - 1)
      closeMultiplexPool pool
      readIORef closeCount `shouldReturn` (failureIndex - 1)
    ) [1..3]

replacementFailureSpec :: Spec
replacementFailureSpec = describe "Multiplexer replacement failure" $ do
  it "closes the dead transport and leaves no replacement behind" $ do
    (connector, _, attempts, closeCount) <-
      createCountingConnector (Just 2) True
    pool <- createMultiplexPool connector 1

    result <- try (submitToNode pool node1 $ encodeCmd ["PING"])
      :: IO (Either SomeException RespData)
    result `shouldSatisfy` either (const True) (const False)
    readIORef attempts `shouldReturn` 2
    readIORef closeCount `shouldReturn` 1

    closeMultiplexPool pool
    readIORef closeCount `shouldReturn` 1

askingSpec :: Spec
askingSpec = describe "ASKING support (submitToNodeWithAsking)" $ do
  it "consumes the ASKING +OK and returns only the command response" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 1

    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNodeWithAsking pool node1
             (encodeCmd ["ASKING"])
             (encodeCmd ["GET", "mykey"])
      putMVar resultMVar r
    threadDelay 50000

    -- Feed two responses: +OK for ASKING, then the real GET response
    fns <- getAddRecvs addRecvMap node1
    length fns `shouldBe` 1
    (firstOf fns) (encodeResp (RespSimpleString "OK"))       -- ASKING response
    (firstOf fns) (encodeResp (RespBulkString "myvalue"))    -- GET response

    r <- takeMVar resultMVar
    -- Should return the GET response, not the ASKING +OK
    r `shouldBe` RespBulkString "myvalue"

    closeMultiplexPool pool

  it "sends ASKING to the target node, not the original node" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 1

    -- Submit ASKING+SET to node2 (the ASK target)
    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNodeWithAsking pool node2
             (encodeCmd ["ASKING"])
             (encodeCmd ["SET", "migratingkey", "val"])
      putMVar resultMVar r
    threadDelay 50000

    -- node1 should have no connections
    fns1 <- getAddRecvs addRecvMap node1
    length fns1 `shouldBe` 0

    -- node2 should have the connection and receive both responses
    fns2 <- getAddRecvs addRecvMap node2
    length fns2 `shouldBe` 1
    (firstOf fns2) (encodeResp (RespSimpleString "OK"))  -- ASKING response
    (firstOf fns2) (encodeResp (RespSimpleString "OK"))  -- SET response

    r <- takeMVar resultMVar
    r `shouldBe` RespSimpleString "OK"

    closeMultiplexPool pool

  it "regular submitToNode only consumes one response" $ do
    (connector, addRecvMap) <- createMockConnector
    pool <- createMultiplexPool connector 1

    resultMVar <- newEmptyMVar
    _ <- forkIO $ do
      r <- submitToNode pool node1 (encodeCmd ["GET", "normalkey"])
      putMVar resultMVar r
    threadDelay 50000

    fns <- getAddRecvs addRecvMap node1
    -- Only feed one response — no ASKING involved
    (firstOf fns) (encodeResp (RespBulkString "normalvalue"))

    r <- takeMVar resultMVar
    r `shouldBe` RespBulkString "normalvalue"

    closeMultiplexPool pool
