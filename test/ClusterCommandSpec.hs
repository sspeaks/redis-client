{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent                    (forkIO, threadDelay)
import           Control.Concurrent.MVar               (newEmptyMVar, newMVar,
                                                        putMVar, takeMVar)
import           Control.Concurrent.STM                (newTVarIO)
import           Control.Monad.IO.Class                (liftIO)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Builder               as Builder
import qualified Data.ByteString.Lazy                  as LBS
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import qualified Data.Map.Strict                       as Map
import           Data.Time.Clock                       (getCurrentTime)
import qualified Data.Vector                           as V
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..),
                                                        SlotRange (..))
import           Database.Redis.Cluster.Client
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..),
                                                        createPool)
import           Database.Redis.Internal.MultiplexPool (closeMultiplexPool,
                                                        createMultiplexPool)
import           Database.Redis.Resp                   (Encodable (..),
                                                        RespData (..))
import           System.Timeout                        (timeout)
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Redirection error parsing" $ do
    describe "MOVED error parsing" $ do
      it "parses valid MOVED error" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 6381)

      it "parses MOVED error with different slot" $ do
        let result = parseRedirectionError "MOVED" "MOVED 12345 192.168.1.100:7000"
        result `shouldBe` Just (RedirectionInfo 12345 "192.168.1.100" 7000)

      it "handles MOVED error with hostname containing colons" $ do
        -- IPv6 addresses would need special handling
        -- For now, test that we handle hostnames correctly
        let result = parseRedirectionError "MOVED" "MOVED 3999 redis-node-1.example.com:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "redis-node-1.example.com" 6381)

      it "returns Nothing for malformed MOVED error" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with invalid slot" $ do
        let result = parseRedirectionError "MOVED" "MOVED notanumber 127.0.0.1:6381"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with invalid port" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:notaport"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with missing colon" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.16381"
        result `shouldBe` Nothing

    describe "ASK error parsing" $ do
      it "parses valid ASK error" $ do
        let result = parseRedirectionError "ASK" "ASK 3999 127.0.0.1:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 6381)

      it "parses ASK error with different slot" $ do
        let result = parseRedirectionError "ASK" "ASK 8765 10.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 8765 "10.0.0.1" 6379)

      it "returns Nothing for malformed ASK error" $ do
        let result = parseRedirectionError "ASK" "ASK 3999"
        result `shouldBe` Nothing

      it "returns Nothing for wrong error type prefix" $ do
        let result = parseRedirectionError "ASK" "MOVED 3999 127.0.0.1:6381"
        result `shouldBe` Nothing

    describe "Edge cases" $ do
      it "handles slot 0" $ do
        let result = parseRedirectionError "MOVED" "MOVED 0 127.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 0 "127.0.0.1" 6379)

      it "handles slot 16383 (max)" $ do
        let result = parseRedirectionError "MOVED" "MOVED 16383 127.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 16383 "127.0.0.1" 6379)

      it "handles high port numbers" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:65535"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 65535)

      it "handles hostname instead of IP" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 redis-node-1:6379"
        result `shouldBe` Just (RedirectionInfo 3999 "redis-node-1" 6379)

      it "returns Nothing for extra whitespace" $ do
        let result = parseRedirectionError "MOVED" "MOVED  3999  127.0.0.1:6381  "
        -- Tighter parsing rejects non-standard formatting (Redis never produces this)
        result `shouldBe` Nothing

      it "handles port 0" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:0"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 0)

      it "returns Nothing for extra fields after host:port" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:6381 extra-data"
        -- Tighter parsing rejects trailing data (Redis never produces this)
        result `shouldBe` Nothing

  describe "detectRedirection (byte-level fast path)" $ do
    it "returns Nothing for non-error responses (RespBulkString)" $ do
      detectRedirection (RespBulkString "OK") `shouldBe` Nothing

    it "returns Nothing for non-error responses (RespSimpleString)" $ do
      detectRedirection (RespSimpleString "OK") `shouldBe` Nothing

    it "returns Nothing for non-error responses (RespInteger)" $ do
      detectRedirection (RespInteger 42) `shouldBe` Nothing

    it "returns Nothing for non-redirect errors" $ do
      detectRedirection (RespError "ERR unknown command") `shouldBe` Nothing

    it "returns Nothing for short error messages" $ do
      detectRedirection (RespError "ERR") `shouldBe` Nothing

    it "returns Nothing for empty error message" $ do
      detectRedirection (RespError "") `shouldBe` Nothing

    it "detects MOVED redirect" $ do
      detectRedirection (RespError "MOVED 3999 127.0.0.1:6381")
        `shouldBe` Just (Left (RedirectionInfo 3999 "127.0.0.1" 6381))

    it "detects ASK redirect" $ do
      detectRedirection (RespError "ASK 3999 127.0.0.1:6381")
        `shouldBe` Just (Right (RedirectionInfo 3999 "127.0.0.1" 6381))

    it "returns Nothing for errors starting with M but not MOVED" $ do
      detectRedirection (RespError "MASTERDOWN Link with MASTER is down") `shouldBe` Nothing

    it "returns Nothing for errors starting with A but not ASK" $ do
      detectRedirection (RespError "AUTH required") `shouldBe` Nothing

  describe "ClusterError types" $ do
    it "creates MovedError correctly" $ do
      let err = MovedError 3999 (NodeAddress "127.0.0.1" 6381)
      show err `shouldContain` "MovedError"
      show err `shouldContain` "3999"

    it "creates AskError correctly" $ do
      let err = AskError 3999 (NodeAddress "127.0.0.1" 6381)
      show err `shouldContain` "AskError"
      show err `shouldContain` "3999"

    it "creates ClusterDownError correctly" $ do
      let err = ClusterDownError "Cluster is down"
      show err `shouldContain` "ClusterDownError"
      show err `shouldContain` "Cluster is down"

    it "creates TryAgainError correctly" $ do
      let err = TryAgainError "Try again later"
      show err `shouldContain` "TryAgainError"

    it "creates CrossSlotError correctly" $ do
      let err = CrossSlotError "Keys in request don't hash to the same slot"
      show err `shouldContain` "CrossSlotError"

    it "creates MaxRetriesExceeded correctly" $ do
      let err = MaxRetriesExceeded "Max retries (3) exceeded"
      show err `shouldContain` "MaxRetriesExceeded"
      show err `shouldContain` "3"

    it "creates TopologyError correctly" $ do
      let err = TopologyError "No node found for slot 3999"
      show err `shouldContain` "TopologyError"

    it "creates ConnectionError correctly" $ do
      let err = ConnectionError "Connection timeout"
      show err `shouldContain` "ConnectionError"

  describe "ClusterConfig" $ do
    it "creates valid cluster config" $ do
      let poolConfig = PoolConfig
            { maxConnectionsPerNode = 1,
              connectionTimeout = 5000,
              maxRetries = 3,
              useTLS = False
            }
          config = ClusterConfig
            { clusterSeedNode = NodeAddress "127.0.0.1" 7000,
              clusterPoolConfig = poolConfig,
              clusterMaxRetries = 3,
              clusterRetryDelay = 100000,
              clusterTopologyRefreshInterval = 600
            }
      clusterMaxRetries config `shouldBe` 3
      clusterRetryDelay config `shouldBe` 100000
      clusterTopologyRefreshInterval config `shouldBe` 600

  describe "RedirectionInfo" $ do
    it "creates valid redirection info" $ do
      let redir = RedirectionInfo 3999 "127.0.0.1" 6381
      redirSlot redir `shouldBe` 3999
      redirHost redir `shouldBe` "127.0.0.1"
      redirPort redir `shouldBe` 6381

    it "shows redirection info correctly" $ do
      let redir = RedirectionInfo 3999 "127.0.0.1" 6381
      show redir `shouldContain` "3999"
      show redir `shouldContain` "127.0.0.1"
      show redir `shouldContain` "6381"

    it "compares redirection info for equality" $ do
      let redir1 = RedirectionInfo 3999 "127.0.0.1" 6381
          redir2 = RedirectionInfo 3999 "127.0.0.1" 6381
          redir3 = RedirectionInfo 4000 "127.0.0.1" 6381
      redir1 `shouldBe` redir2
      redir1 `shouldNotBe` redir3

  askRedirectSpec

-- ---------------------------------------------------------------------------
-- Mock client (same pattern as MultiplexPoolSpec)
-- ---------------------------------------------------------------------------

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef ByteString)   -- sendBuf
               -> !(IORef [ByteString]) -- recvQueue
               -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close _ = return ()
  send (MockConnected sendBuf _) lbs = liftIO $ do
    let !bs = LBS.toStrict lbs
    atomicModifyIORef' sendBuf $ \old -> (old <> bs, ())
  receive (MockConnected sRef recvQueue) = liftIO $ recvLoop sRef recvQueue

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
  let client = MockConnected sendBuf recvQueue
      addRecv bs = atomicModifyIORef' recvQueue $ \xs -> (xs ++ [bs], ())
  return (client, addRecv)

type AddRecvMap = IORef [(NodeAddress, ByteString -> IO ())]

createMockConnector :: IO (NodeAddress -> IO (MockClient 'Connected), AddRecvMap, IORef Int)
createMockConnector = do
  mapRef <- newIORef []
  connCount <- newIORef 0
  let connector addr = do
        (client, addRecv) <- createMockClient
        atomicModifyIORef' mapRef $ \xs -> (xs ++ [(addr, addRecv)], ())
        atomicModifyIORef' connCount $ \n -> (n + 1, ())
        return client
  return (connector, mapRef, connCount)

getAddRecvs :: AddRecvMap -> NodeAddress -> IO [ByteString -> IO ()]
getAddRecvs mapRef addr = do
  xs <- readIORef mapRef
  return [f | (a, f) <- xs, a == addr]

firstOf :: [a] -> a
firstOf (x:_) = x
firstOf []    = error "firstOf: empty list"

encodeResp :: RespData -> ByteString
encodeResp = LBS.toStrict . Builder.toLazyByteString . encode

-- | Build a test topology where all 16384 slots map to a single node.
mkTopology :: NodeAddress -> IO ClusterTopology
mkTopology addr = do
  now <- getCurrentTime
  let nodeIdBS = "test-node-id-1"
      node = ClusterNode nodeIdBS addr Master [SlotRange 0 16383 nodeIdBS []] []
      slotVec = V.replicate 16384 nodeIdBS
      addrVec = V.replicate 16384 addr
      nodeMap = Map.singleton nodeIdBS node
  return $ ClusterTopology slotVec addrVec nodeMap now

-- | Build a ClusterClient backed by a mock connector and a given topology.
mkClusterClient
  :: (NodeAddress -> IO (MockClient 'Connected))
  -> ClusterTopology
  -> IO (ClusterClient MockClient)
mkClusterClient connector topo = do
  topoVar   <- newTVarIO topo
  pool      <- createPool poolCfg
  muxPool   <- createMultiplexPool connector 1
  refreshLk <- newMVar ()
  return $ ClusterClient topoVar pool clusterCfg connector refreshLk muxPool
  where
    poolCfg = PoolConfig
      { maxConnectionsPerNode = 1
      , connectionTimeout     = 5000
      , maxRetries            = 3
      , useTLS                = False
      }
    clusterCfg = ClusterConfig
      { clusterSeedNode                = NodeAddress "127.0.0.1" 6379
      , clusterPoolConfig              = poolCfg
      , clusterMaxRetries              = 5
      , clusterRetryDelay              = 1000
      , clusterTopologyRefreshInterval = 600
      }

-- ---------------------------------------------------------------------------
-- ASK redirect integration tests
-- ---------------------------------------------------------------------------

node1, node2 :: NodeAddress
node1 = NodeAddress "127.0.0.1" 6379
node2 = NodeAddress "127.0.0.2" 6380

askRedirectSpec :: Spec
askRedirectSpec = describe "ASK redirect integration (executeKeyedClusterCommand)" $ do
  it "on ASK error, retries with ASKING prefix at the redirected node" $ do
    result <- timeout 5000000 $ do
      (connector, addRecvMap, _) <- createMockConnector
      topo <- mkTopology node1  -- all slots → node1
      client <- mkClusterClient connector topo

      -- Run executeKeyedClusterCommand in a thread
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- executeKeyedClusterCommand client "mykey" ["GET", "mykey"]
        putMVar resultMVar r

      -- Wait for node1 connection, then reply with ASK redirect to node2
      threadDelay 50000
      fns1 <- getAddRecvs addRecvMap node1
      length fns1 `shouldSatisfy` (>= 1)
      -- node2 should have no connections yet (not in topology)
      fns2Before <- getAddRecvs addRecvMap node2
      length fns2Before `shouldBe` 0
      (firstOf fns1) (encodeResp (RespError "ASK 3999 127.0.0.2:6380"))

      -- The retry should connect to node2 with ASKING + GET
      threadDelay 50000
      fns2 <- getAddRecvs addRecvMap node2
      length fns2 `shouldSatisfy` (>= 1)
      -- Feed +OK for ASKING, then the real response
      (firstOf fns2) (encodeResp (RespSimpleString "OK"))
      (firstOf fns2) (encodeResp (RespBulkString "myvalue"))

      r <- takeMVar resultMVar
      r `shouldBe` Right (RespBulkString "myvalue")

      closeMultiplexPool (clusterMultiplexPool client)
    result `shouldBe` Just ()

  it "ASK redirect does NOT trigger topology refresh" $ do
    result <- timeout 5000000 $ do
      (connector, addRecvMap, connCount) <- createMockConnector
      topo <- mkTopology node1
      client <- mkClusterClient connector topo

      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- executeKeyedClusterCommand client "testkey" ["SET", "testkey", "val"]
        putMVar resultMVar r

      threadDelay 50000
      fns1 <- getAddRecvs addRecvMap node1
      (firstOf fns1) (encodeResp (RespError "ASK 100 127.0.0.2:6380"))

      threadDelay 50000
      fns2 <- getAddRecvs addRecvMap node2
      (firstOf fns2) (encodeResp (RespSimpleString "OK"))  -- ASKING
      (firstOf fns2) (encodeResp (RespSimpleString "OK"))  -- SET

      r <- takeMVar resultMVar
      r `shouldBe` Right (RespSimpleString "OK")

      -- Exactly 2 connections total: 1 for node1 (mux) + 1 for node2 (ASK redirect).
      -- A topology refresh would have created a 3rd connection to the seed node,
      -- and then hung waiting for CLUSTER SLOTS data (caught by the 5s timeout).
      totalConns <- readIORef connCount
      totalConns `shouldBe` 2

      closeMultiplexPool (clusterMultiplexPool client)
    result `shouldBe` Just ()

  it "successful command without redirection returns directly" $ do
    result <- timeout 5000000 $ do
      (connector, addRecvMap, _) <- createMockConnector
      topo <- mkTopology node1
      client <- mkClusterClient connector topo

      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- executeKeyedClusterCommand client "key1" ["GET", "key1"]
        putMVar resultMVar r

      threadDelay 50000
      fns1 <- getAddRecvs addRecvMap node1
      (firstOf fns1) (encodeResp (RespBulkString "directvalue"))

      r <- takeMVar resultMVar
      r `shouldBe` Right (RespBulkString "directvalue")

      closeMultiplexPool (clusterMultiplexPool client)
    result `shouldBe` Just ()
