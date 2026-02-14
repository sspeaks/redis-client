{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent      (forkIO, threadDelay)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception       (SomeException, try)
import           Control.Monad.IO.Class  (liftIO)
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LBS
import           Data.IORef              (IORef, atomicModifyIORef', newIORef,
                                          readIORef)
import           Database.Redis.Client   (Client (..), ConnectionStatus (..))
import           Database.Redis.Resp     (Encodable (..), RespData (..))
import           Multiplexer
import           Test.Hspec

-- ---------------------------------------------------------------------------
-- Mock client for testing without a real Redis connection
-- ---------------------------------------------------------------------------

-- | A mock client that uses IORef-based queues for send/receive.
-- Sent data is accumulated in sendBuf; recv reads from recvBuf.
data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef ByteString)  -- sendBuf (accumulates sent data)
                -> !(IORef [ByteString]) -- recvQueue (list of chunks to return)
                -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close _ = return ()
  send (MockConnected sendBuf _) lbs = liftIO $ do
    let !bs = LBS.toStrict lbs
    atomicModifyIORef' sendBuf $ \old -> (old <> bs, ())
  receive (MockConnected sRef recvQueue) = liftIO $ recvLoop sRef recvQueue

-- | Polling recv loop — retries until data is available.
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

-- | Create a mock client and return (client, addRecvData).
-- addRecvData pushes response bytes that the reader thread will consume.
createMockClient :: IO (MockClient 'Connected, ByteString -> IO ())
createMockClient = do
  sendBuf <- newIORef BS.empty
  recvQueue <- newIORef []
  let client = MockConnected sendBuf recvQueue
      addRecv bs = atomicModifyIORef' recvQueue $ \xs -> (xs ++ [bs], ())
  return (client, addRecv)

-- | Encode a RespData to strict ByteString (for feeding to mock recv).
encodeResp :: RespData -> ByteString
encodeResp = LBS.toStrict . Builder.toLazyByteString . encode

-- | Encode a RESP command as a Builder (for submitting to multiplexer).
encodeCmd :: [ByteString] -> Builder.Builder
encodeCmd args =
  Builder.byteString ("*" <> bshow (length args) <> "\r\n")
  <> foldMap (\a -> Builder.byteString ("$" <> bshow (BS.length a) <> "\r\n" <> a <> "\r\n")) args
  where bshow x = LBS.toStrict (Builder.toLazyByteString (Builder.intDec x))

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  slotPoolSpec
  responseSlotSpec
  commandQueueBatchingSpec
  multiplexerLifecycleSpec
  isMultiplexerAliveSpec

slotPoolSpec :: Spec
slotPoolSpec = describe "SlotPool" $ do
  it "allocation returns a valid slot" $ do
    pool <- createSlotPool 64
    -- acquireSlot is not exported, but submitCommandPooled uses it internally.
    -- We test via the public API: create multiplexer, submit, verify response.
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "OK"))
    resp <- submitCommandPooled pool mux (encodeCmd ["PING"])
    resp `shouldBe` RespSimpleString "OK"
    destroyMultiplexer mux

  it "slots are reusable (return-and-reuse)" $ do
    pool <- createSlotPool 4
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit multiple commands sequentially — slots should be reused from pool
    let n = 20
    mapM_ (\i -> do
      addRecv (encodeResp (RespInteger i))
      resp <- submitCommandPooled pool mux (encodeCmd ["GET", "key"])
      resp `shouldBe` RespInteger i
      ) [1..n]
    destroyMultiplexer mux

  it "striped distribution across cores does not crash" $ do
    -- Verify that pool creation with various sizes works
    pool1 <- createSlotPool 1
    pool2 <- createSlotPool 16
    pool3 <- createSlotPool 1024
    -- Use each pool to ensure stripes are functional
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool1 mux (encodeCmd ["PING"])
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool2 mux (encodeCmd ["PING"])
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool3 mux (encodeCmd ["PING"])
    destroyMultiplexer mux

responseSlotSpec :: Spec
responseSlotSpec = describe "ResponseSlot" $ do
  it "write-then-read returns correct value" $ do
    pool <- createSlotPool 16
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit a command; the reader thread writes the response to the slot
    addRecv (encodeResp (RespBulkString "hello"))
    resp <- submitCommandPooled pool mux (encodeCmd ["GET", "key"])
    resp `shouldBe` RespBulkString "hello"
    destroyMultiplexer mux

  it "waitSlot blocks until filled (async submit)" $ do
    pool <- createSlotPool 16
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit async — slot should not be filled yet
    slot <- submitCommandAsync pool mux (encodeCmd ["GET", "key"])
    -- Feed response after a short delay
    _ <- forkIO $ do
      threadDelay 50000  -- 50ms delay
      addRecv (encodeResp (RespBulkString "delayed"))
    resp <- waitSlot pool slot
    resp `shouldBe` RespBulkString "delayed"
    destroyMultiplexer mux

commandQueueBatchingSpec :: Spec
commandQueueBatchingSpec = describe "Command queue batching" $ do
  it "multiple enqueued commands are drained together" $ do
    pool <- createSlotPool 64
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)

    -- Submit 5 commands concurrently, then feed 5 responses
    let n = 5
    results <- newIORef ([] :: [RespData])
    barriers <- mapM (\_ -> newEmptyMVar) [1..n]

    -- Submit commands from separate threads
    mapM_ (\(i, barrier) -> forkIO $ do
      resp <- submitCommandPooled pool mux (encodeCmd ["GET", LBS.toStrict $ Builder.toLazyByteString $ Builder.intDec i])
      atomicModifyIORef' results $ \rs -> (rs ++ [resp], ())
      putMVar barrier ()
      ) (zip [1..n] barriers)

    -- Give commands time to be enqueued
    threadDelay 10000

    -- Feed all responses at once (they should be batched)
    let allResponses = mconcat $ map (\i -> encodeResp (RespInteger (fromIntegral (i :: Int)))) [1..n]
    addRecv allResponses

    -- Wait for all to complete
    mapM_ takeMVar barriers

    -- Verify all responses received
    rs <- readIORef results
    length rs `shouldBe` n
    destroyMultiplexer mux

multiplexerLifecycleSpec :: Spec
multiplexerLifecycleSpec = describe "Multiplexer lifecycle" $ do
  it "create and submit returns correct response" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "PONG"))
    resp <- submitCommand mux (encodeCmd ["PING"])
    resp `shouldBe` RespSimpleString "PONG"
    destroyMultiplexer mux

  it "destroy then submit throws MultiplexerDead" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    -- Small delay for destroy to take effect
    threadDelay 10000
    result <- try $ submitCommand mux (encodeCmd ["PING"])
    case result of
      Left (e :: SomeException) -> show e `shouldContain` "MultiplexerDead"
      Right _ -> expectationFailure "Expected MultiplexerDead exception"

  it "submit-after-destroy with pooled also throws MultiplexerDead" $ do
    pool <- createSlotPool 16
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    threadDelay 10000
    result <- try $ submitCommandPooled pool mux (encodeCmd ["GET", "key"])
    case result of
      Left (e :: SomeException) -> show e `shouldContain` "MultiplexerDead"
      Right _ -> expectationFailure "Expected MultiplexerDead exception"

  it "handles multiple sequential commands correctly" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Send multiple commands and verify ordering
    addRecv (encodeResp (RespSimpleString "OK"))
    r1 <- submitCommand mux (encodeCmd ["SET", "k1", "v1"])
    r1 `shouldBe` RespSimpleString "OK"

    addRecv (encodeResp (RespBulkString "v1"))
    r2 <- submitCommand mux (encodeCmd ["GET", "k1"])
    r2 `shouldBe` RespBulkString "v1"

    addRecv (encodeResp (RespInteger 1))
    r3 <- submitCommand mux (encodeCmd ["DEL", "k1"])
    r3 `shouldBe` RespInteger 1

    addRecv (encodeResp RespNullBulkString)
    r4 <- submitCommand mux (encodeCmd ["GET", "k1"])
    r4 `shouldBe` RespNullBulkString

    destroyMultiplexer mux

  it "handles RespArray responses" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    let arrResp = RespArray [RespBulkString "v1", RespBulkString "v2", RespNullBulkString]
    addRecv (encodeResp arrResp)
    resp <- submitCommand mux (encodeCmd ["MGET", "k1", "k2", "k3"])
    resp `shouldBe` arrResp
    destroyMultiplexer mux

  it "handles RespError responses without crashing" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespError "ERR wrong number of arguments"))
    resp <- submitCommand mux (encodeCmd ["GET"])
    resp `shouldBe` RespError "ERR wrong number of arguments"
    destroyMultiplexer mux

isMultiplexerAliveSpec :: Spec
isMultiplexerAliveSpec = describe "isMultiplexerAlive" $ do
  it "returns True for a live multiplexer" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    alive <- isMultiplexerAlive mux
    alive `shouldBe` True
    destroyMultiplexer mux

  it "returns False after destroy" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    threadDelay 10000
    alive <- isMultiplexerAlive mux
    alive `shouldBe` False
