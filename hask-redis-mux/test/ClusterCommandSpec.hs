{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent                       (forkFinally, forkIO,
                                                           killThread,
                                                           threadDelay)
import           Control.Concurrent.MVar                  (newEmptyMVar,
                                                           newMVar, putMVar,
                                                           takeMVar,
                                                           tryTakeMVar)
import           Control.Concurrent.STM                   (TVar, atomically,
                                                           check, modifyTVar',
                                                           newTVarIO, readTVar,
                                                           readTVarIO)
import           Control.Exception                        (SomeAsyncException,
                                                           SomeException,
                                                           finally,
                                                           fromException,
                                                           throwIO, try)
import qualified Control.Exception                        as Exception
import           Control.Monad                            (forM_, replicateM_)
import           Control.Monad.IO.Class                   (liftIO)
import           Data.ByteString                          (ByteString)
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Builder                  as Builder
import qualified Data.ByteString.Char8                    as BS8
import qualified Data.ByteString.Lazy                     as LBS
import           Data.IORef                               (IORef,
                                                           atomicModifyIORef',
                                                           newIORef, readIORef)
import qualified Data.Map.Strict                          as Map
import           Data.Time.Clock                          (getCurrentTime)
import qualified Data.Vector                              as V
import           Data.Word                                (Word16)
import           Database.Redis.Client                    (Client (..),
                                                           ConnectionStatus (..))
import           Database.Redis.Cluster                   (ClusterNode (..),
                                                           ClusterTopology (..),
                                                           NodeAddress (..),
                                                           NodeRole (..),
                                                           SlotRange (..),
                                                           calculateSlot,
                                                           findNodeAddressForSlot)
import           Database.Redis.Cluster.Client
import           Database.Redis.Cluster.Commands          (CommandRouting (..),
                                                           classifyCommand)
import           Database.Redis.Cluster.ConnectionPool    (PoolConfig (..),
                                                           createPool)
import           Database.Redis.Cluster.Internal.Topology (commitRefreshedTopology,
                                                           mergeRefreshedTopology,
                                                           patchMovedSlot,
                                                           provisionalMovedPatches)
import           Database.Redis.Connector                 (ConnectionPhase (..),
                                                           ConnectionSetupException (..),
                                                           withConnectionTimeout)
import           Database.Redis.Internal.MultiplexPool    (closeMultiplexPool,
                                                           createMultiplexPool)
import           Database.Redis.Resp                      (Encodable (..),
                                                           RespData (..))
import           GHC.Clock                                (getMonotonicTimeNSec)
import           System.Timeout                           (timeout)
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Redis 7.2 smart-proxy command grammar" $ do
    let keyed command arguments key =
          classifyCommand command arguments `shouldBe` KeyedRoute key
        rejected command arguments =
          classifyCommand command arguments `shouldSatisfy` isError
        isError (CommandError _) = True
        isError _                = False
    it "extracts SET's key and rejects malformed option grammar" $ do
      keyed "SET" ["{a}key", "value", "EX", "10", "GET"] "{a}key"
      rejected "SET" ["key", "value", "EX", "0"]
      rejected "SET" ["key", "value", "NX", "XX"]
    it "classifies MEMORY and OBJECT subcommands without guessing" $ do
      keyed "MEMORY" ["USAGE", "key", "SAMPLES", "5"] "key"
      keyed "OBJECT" ["ENCODING", "key"] "key"
      rejected "MEMORY" ["USAGE"]
      rejected "OBJECT" ["HELP"]
    it "validates counted sorted-set and function forms" $ do
      classifyCommand "ZUNION" ["2", "{a}one", "{a}two", "WITHSCORES"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      classifyCommand "ZINTERSTORE" ["{a}out", "2", "{a}one", "{a}two", "AGGREGATE", "SUM"]
        `shouldBe` MultiKeyRoute ["{a}out", "{a}one", "{a}two"]
      keyed "EVAL" ["return 1", "1", "script-key", "argument"] "script-key"
      classifyCommand "FCALL" ["f", "2", "{a}one", "{a}two"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      rejected "ZDIFF" ["2", "one"]
      rejected "EVALSHA" ["sha", "-1"]
    it "splits XREAD and XREADGROUP STREAMS keys from IDs" $ do
      classifyCommand "XREAD" ["COUNT", "1", "STREAMS", "{a}one", "{a}two", "0", "$"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      classifyCommand "XREADGROUP" ["GROUP", "g", "c", "NOACK", "STREAMS", "key", ">"]
        `shouldBe` KeyedRoute "key"
      rejected "XREAD" ["STREAMS", "key"]
    it "accepts fractional blocking timeouts and validates multi-key forms" $ do
      classifyCommand "BLPOP" ["{a}one", "{a}two", "0.25"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      classifyCommand "MSET" ["{a}one", "1", "{a}two", "2"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      classifyCommand "RENAME" ["{a}one", "{a}two"]
        `shouldBe` MultiKeyRoute ["{a}one", "{a}two"]
      rejected "MSET" ["key", "value", "orphan"]
    it "fails closed for unknown commands and identifies GEO store targets" $ do
      rejected "FUTURECOMMAND" ["not-a-key"]
      classifyCommand "GEOSEARCH" ["{a}source", "FROMLONLAT", "0", "0", "BYRADIUS", "1", "km", "STORE", "{a}destination"]
        `shouldBe` MultiKeyRoute ["{a}source", "{a}destination"]
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

      it "rejects port 0" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:0"
        result `shouldBe` Nothing

      it "rejects negative and out-of-range slots" $ do
        parseRedirectionError "MOVED" "MOVED -1 127.0.0.1:6379"
          `shouldBe` Nothing
        parseRedirectionError "MOVED" "MOVED 16384 127.0.0.1:6379"
          `shouldBe` Nothing

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

  describe "central cluster reply classification" $ do
    it "classifies all supported Redis Cluster error tokens" $ do
      classifyClusterReply
        (RespError "MOVED 3999 127.0.0.1:6381")
        `shouldBe`
          Left (MovedError 3999 $ NodeAddress "127.0.0.1" 6381)
      classifyClusterReply
        (RespError "ASK 3999 127.0.0.1:6381")
        `shouldBe`
          Left (AskError 3999 $ NodeAddress "127.0.0.1" 6381)
      classifyClusterReply
        (RespError "TRYAGAIN Slot is migrating")
        `shouldBe`
          Left (TryAgainError "TRYAGAIN Slot is migrating")
      classifyClusterReply
        (RespError "CLUSTERDOWN The cluster is down")
        `shouldBe`
          Left (ClusterDownError "CLUSTERDOWN The cluster is down")
      classifyClusterReply
        (RespError "CROSSSLOT Keys do not hash to one slot")
        `shouldBe`
          Left (CrossSlotError "CROSSSLOT Keys do not hash to one slot")

    it "requires an exact case-sensitive token boundary" $ do
      let ordinary message =
            classifyClusterReply (RespError message)
              `shouldBe` Left (RedisCommandError message)
      mapM_ ordinary
        [ "TRYAGAINLY not the cluster token"
        , "TRYAGAIN\twrong delimiter"
        , "tryagain wrong case"
        , "CLUSTERDOWNTIME different token"
        , "CROSSSLOTTERY different token"
        , "MOVEDLY 1 127.0.0.1:6379"
        , "ASKED 1 127.0.0.1:6379"
        ]

    it "preserves malformed redirects and ordinary server errors verbatim" $ do
      classifyClusterReply (RespError "MOVED invalid payload")
        `shouldBe` Left (RedisCommandError "MOVED invalid payload")
      classifyClusterReply (RespError "WRONGTYPE full server cause")
        `shouldBe` Left (RedisCommandError "WRONGTYPE full server cause")

    it "passes non-error replies through unchanged" $ do
      classifyClusterReply (RespBulkString "value")
        `shouldBe` Right (RespBulkString "value")

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

    it "creates ConnectionTimeoutError without credentials" $ do
      let timeoutError =
            ConnectionSetupTimeout PlaintextConnectionSetup node1 5
          err = ConnectionTimeoutError timeoutError
      show err `shouldContain` "PlaintextConnectionSetup"
      show err `shouldContain` "127.0.0.1"

    it "creates ClusterClientClosed correctly" $ do
      ClusterClientClosed `shouldBe` ClusterClientClosed

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
  askRedirectAdditionalSpec
  askRedirectSuccessSpec
  movedRedirectSpec
  clusterLifecycleSpec
  clusterAuthenticationSpec
  clusterErrorClassificationSpec

-- ---------------------------------------------------------------------------
-- Mock client (same pattern as MultiplexPoolSpec)
-- ---------------------------------------------------------------------------

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef ByteString)   -- sendBuf
               -> !(IORef [ByteString]) -- recvQueue
               -> !(IORef Int)          -- closeCount
               -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close (MockConnected _ _ closeCount) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send (MockConnected sendBuf _ _) lbs = liftIO $ do
    let !bs = LBS.toStrict lbs
    atomicModifyIORef' sendBuf $ \old -> (old <> bs, ())
  receive (MockConnected sRef recvQueue _) = liftIO $ recvLoop sRef recvQueue

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
  let client = MockConnected sendBuf recvQueue closeCount
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

createLifecycleConnector
  :: RespData
  -> IO (NodeAddress -> IO (MockClient 'Connected), IORef Int, IORef Int)
createLifecycleConnector response = do
  connectionCount <- newIORef 0
  closeCount <- newIORef 0
  let connector _ = do
        sendBuf <- newIORef BS.empty
        recvQueue <- newIORef [encodeResp response]
        atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
        return $ MockConnected sendBuf recvQueue closeCount
  return (connector, connectionCount, closeCount)

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

mkTwoMasterTopology
  :: NodeAddress
  -> NodeAddress
  -> IO ClusterTopology
mkTwoMasterTopology firstAddress secondAddress = do
  now <- getCurrentTime
  let firstId = "test-node-id-1"
      secondId = "test-node-id-2"
      firstRange = SlotRange 0 8191 firstId []
      secondRange = SlotRange 8192 16383 secondId []
      firstNode =
        ClusterNode firstId firstAddress Master [firstRange] []
      secondNode =
        ClusterNode secondId secondAddress Master [secondRange] []
      slotVec =
        V.replicate 8192 firstId <> V.replicate 8192 secondId
      addrVec =
        V.replicate 8192 firstAddress
          <> V.replicate 8192 secondAddress
      nodeMap = Map.fromList
        [(firstId, firstNode), (secondId, secondNode)]
  return $ ClusterTopology slotVec addrVec nodeMap now

validClusterSlots :: RespData
validClusterSlots =
  RespArray
    [ RespArray
        [ RespInteger 0
        , RespInteger 16383
        , RespArray
            [ RespBulkString "127.0.0.1"
            , RespInteger 6379
            , RespBulkString "test-node-id-1"
            ]
        ]
    ]

testPoolConfig :: PoolConfig
testPoolConfig = PoolConfig
  { maxConnectionsPerNode = 1
  , connectionTimeout     = 5000
  , maxRetries            = 3
  , useTLS                = False
  }

testClusterConfig :: ClusterConfig
testClusterConfig = ClusterConfig
  { clusterSeedNode                = node1
  , clusterPoolConfig              = testPoolConfig
  , clusterMaxRetries              = 5
  , clusterRetryDelay              = 1000
  , clusterTopologyRefreshInterval = 600
  }

-- | Build a ClusterClient backed by a mock connector and a given topology.
mkClusterClient
  :: (NodeAddress -> IO (MockClient 'Connected))
  -> ClusterTopology
  -> IO (ClusterClient MockClient)
mkClusterClient connector topo = do
  topoVar   <- newTVarIO topo
  pool      <- createPool testPoolConfig
  muxPool   <- createMultiplexPool connector 1
  refreshLk <- newMVar ()
  return $ ClusterClient topoVar pool testClusterConfig connector refreshLk muxPool

clusterLifecycleSpec :: Spec
clusterLifecycleSpec = describe "Cluster client lifecycle" $ do
  it "closes the discovery connection when topology parsing fails" $ do
    (connector, connectionCount, closeCount) <-
      createLifecycleConnector (RespSimpleString "not cluster slots")

    result <- try (createClusterClient testClusterConfig connector)
      :: IO (Either SomeException (ClusterClient MockClient))
    case result of
      Left _  -> return ()
      Right _ -> expectationFailure "Expected topology parsing failure"
    readIORef connectionCount `shouldReturn` 1
    readIORef closeCount `shouldReturn` 1

  it "does not make a successful direct MOVED retry depend on refresh validation" $ do
    let incompleteTopology =
          RespArray
            [ RespArray
                [ RespInteger 0
                , RespInteger 100
                , RespArray
                    [ RespBulkString "127.0.0.1"
                    , RespInteger 6379
                    , RespBulkString "partial-node"
                    ]
                ]
            ]
    connectionCount <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    let connector _ = do
          connectionIndex <- atomicModifyIORef' connectionCount $ \count ->
            (count + 1, count)
          sendBuf <- newIORef BS.empty
          recvQueue <- newIORef
            [ encodeResp $
                if connectionIndex == 0
                  then RespError "MOVED 3999 127.0.0.2:6380"
                  else if connectionIndex == 1
                    then RespBulkString "redirected-value"
                  else incompleteTopology
            ]
          return $ MockConnected sendBuf recvQueue closeCount
    topology <- mkTopology node1
    client <- mkClusterClient connector topology

    outcome <- timeout 1000000 $
      executeKeyedClusterCommand client "key" ["GET", "key"]
    outcome `shouldBe` Just (Right $ RespBulkString "redirected-value")
    readIORef connectionCount `shouldReturn` 4
    closeClusterClient client

  it "returns a connection refresh validation failure as TopologyError without retrying" $ do
    let incompleteTopology =
          RespArray
            [ RespArray
                [ RespInteger 0
                , RespInteger 100
                , RespArray
                    [ RespBulkString "127.0.0.1"
                    , RespInteger 6379
                    , RespBulkString "partial-node"
                    ]
                ]
            ]
    connectionCount <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    let connector _ = do
          connectionIndex <- atomicModifyIORef' connectionCount $ \count ->
            (count + 1, count)
          if connectionIndex == 0
            then throwIO $ userError "injected command connection failure"
            else do
              sendBuf <- newIORef BS.empty
              recvQueue <- newIORef [encodeResp incompleteTopology]
              return $ MockConnected sendBuf recvQueue closeCount
    topology <- mkTopology node1
    client <- mkClusterClient connector topology

    outcome <- timeout 1000000 $
      executeKeyedClusterCommand client "key" ["GET", "key"]
    case outcome of
      Just (Left (TopologyError err)) ->
        err `shouldContain` "does not cover slot 101"
      other ->
        expectationFailure $
          "Expected immediate TopologyError after connection refresh, got: "
            ++ show other
    readIORef connectionCount `shouldReturn` 2
    closeClusterClient client

  it "closes the discovery pool when later initialization fails" $ do
    (connector, connectionCount, closeCount) <-
      createLifecycleConnector validClusterSlots
    let failMuxCreation _ _ =
          throwIO $ userError "injected multiplexer pool initialization failure"

    result <- try $
      createClusterClientWithFactories
        createPool failMuxCreation testClusterConfig connector
      :: IO (Either SomeException (ClusterClient MockClient))
    case result of
      Left _  -> return ()
      Right _ -> expectationFailure "Expected multiplexer pool initialization failure"
    readIORef connectionCount `shouldReturn` 1
    readIORef closeCount `shouldReturn` 1

  it "closes once and keeps both cluster pools terminal" $ do
    (connector, connectionCount, closeCount) <-
      createLifecycleConnector validClusterSlots
    client <- createClusterClient testClusterConfig connector

    closeClusterClient client
    closeClusterClient client
    readIORef connectionCount `shouldReturn` 1
    readIORef closeCount `shouldReturn` 1

    keyless <- executeKeylessClusterCommand client
      (ping :: RedisCommandClient MockClient RespData)
    keyless `shouldBe` Left ClusterClientClosed
    keyed <- executeKeyedClusterCommand client "key" ["GET", "key"]
    keyed `shouldBe` Left ClusterClientClosed
    readIORef connectionCount `shouldReturn` 1
    readIORef closeCount `shouldReturn` 1

  it "bounds retries while failed TLS/AUTH cleanup is still unwinding" $ do
    attempts <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    cleanupFinished <- newIORef (0 :: Int)
    cleanupRelease <- newEmptyMVar
    stalled <- newEmptyMVar
    topology <- mkTopology node1
    topologyVar <- newTVarIO topology
    discoveryPool <- createPool testPoolConfig
    refreshLock <- newMVar ()
    let retryConfig = testClusterConfig
          { clusterPoolConfig =
              testPoolConfig
                { connectionTimeout = 1
                , useTLS = True
                }
          , clusterMaxRetries = 2
          , clusterRetryDelay = 1000
          }
        connector _ = do
          atomicModifyIORef' attempts $ \count -> (count + 1, ())
          _ <- Exception.onException
            (takeMVar stalled)
            (do
              atomicModifyIORef' closeCount $ \count -> (count + 1, ())
              takeMVar cleanupRelease
              atomicModifyIORef' cleanupFinished $ \count ->
                (count + 1, ()))
          sendBuf <- newIORef BS.empty
          recvQueue <- newIORef []
          return $ MockConnected sendBuf recvQueue closeCount
        boundedConnector =
          withConnectionTimeout 1 TLSConnectionSetup connector

    muxPool <- createMultiplexPool boundedConnector 1
    let client = ClusterClient
          topologyVar discoveryPool retryConfig connector refreshLock muxPool
    started <- getMonotonicTimeNSec
    result <- executeKeyedClusterCommand client "key" ["GET", "key"]
    finished <- getMonotonicTimeNSec
    let elapsedSeconds =
          fromIntegral (finished - started) / 1000000000 :: Double

    result `shouldSatisfy` \case
      Left (MaxRetriesExceeded _) -> True
      _                           -> False
    elapsedSeconds `shouldSatisfy` \elapsed ->
      elapsed >= 1.5 && elapsed < 4
    readIORef attempts `shouldReturn` 2
    timeout 1000000 (awaitIORefValue closeCount 2)
      `shouldReturn` Just ()
    replicateM_ 2 $ putMVar cleanupRelease ()
    timeout 1000000 (awaitIORefValue cleanupFinished 2)
      `shouldReturn` Just ()
    readIORef closeCount `shouldReturn` 2
    closeClusterClient client
    readIORef closeCount `shouldReturn` 2

  it "keeps synchronous connection failures inside the retry bound" $ do
    attempts <- newIORef (0 :: Int)
    topology <- mkTopology node1
    topologyVar <- newTVarIO topology
    discoveryPool <- createPool testPoolConfig
    refreshLock <- newMVar ()
    let retryConfig = testClusterConfig
          { clusterMaxRetries = 2
          , clusterRetryDelay = 1000
          }
        connector :: NodeAddress -> IO (MockClient 'Connected)
        connector _ = do
          atomicModifyIORef' attempts $ \count -> (count + 1, ())
          throwIO $ userError "injected connection failure"

    muxPool <- createMultiplexPool connector 1
    let client = ClusterClient
          topologyVar discoveryPool retryConfig connector refreshLock muxPool
    result <- executeKeyedClusterCommand client "key" ["GET", "key"]

    result `shouldSatisfy` \case
      Left (MaxRetriesExceeded _) -> True
      _                           -> False
    readIORef attempts `shouldReturn` 4
    closeClusterClient client

  it "rethrows caller cancellation instead of retrying it" $ do
    attempts <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    connectorStarted <- newEmptyMVar
    stalled <- newEmptyMVar
    topology <- mkTopology node1
    topologyVar <- newTVarIO topology
    discoveryPool <- createPool testPoolConfig
    refreshLock <- newMVar ()
    let retryConfig = testClusterConfig
          { clusterPoolConfig =
              testPoolConfig { connectionTimeout = 5 }
          , clusterMaxRetries = 3
          }
        connector _ = do
          atomicModifyIORef' attempts $ \count -> (count + 1, ())
          putMVar connectorStarted ()
          _ <- Exception.onException
            (takeMVar stalled)
            (atomicModifyIORef' closeCount $ \count -> (count + 1, ()))
          sendBuf <- newIORef BS.empty
          recvQueue <- newIORef []
          return $ MockConnected sendBuf recvQueue closeCount
        boundedConnector =
          withConnectionTimeout 5 PlaintextConnectionSetup connector

    muxPool <- createMultiplexPool boundedConnector 1
    let client = ClusterClient
          topologyVar discoveryPool retryConfig connector refreshLock muxPool
    finished <- newEmptyMVar
    owner <- forkFinally
      (executeKeyedClusterCommand client "key" ["GET", "key"])
      (putMVar finished)
    timeout 1000000 (takeMVar connectorStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 (takeMVar finished)
    case outcome of
      Just (Left err) ->
        (Exception.fromException err :: Maybe SomeAsyncException)
          `shouldSatisfy` \case
            Just _  -> True
            Nothing -> False
      _ -> expectationFailure "caller cancellation was not rethrown"
    readIORef attempts `shouldReturn` 1
    timeout 1000000 (awaitIORefValue closeCount 1)
      `shouldReturn` Just ()
    readIORef closeCount `shouldReturn` 1
    closeClusterClient client

awaitIORefValue :: IORef Int -> Int -> IO ()
awaitIORefValue ref expected = do
  actual <- readIORef ref
  if actual == expected
    then return ()
    else threadDelay 1000 >> awaitIORefValue ref expected

-- ---------------------------------------------------------------------------
-- ASK redirect integration tests
-- ---------------------------------------------------------------------------

node1, node2, node3 :: NodeAddress
node1 = NodeAddress "127.0.0.1" 6379
node2 = NodeAddress "127.0.0.2" 6380
node3 = NodeAddress "127.0.0.3" 6381

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

-- ---------------------------------------------------------------------------
-- Per-connection cluster authentication
-- ---------------------------------------------------------------------------

data AuthMockClient (status :: ConnectionStatus) where
  AuthMockConnected
    :: !(IORef ByteString)
    -> !(TVar Int)
    -> !(IORef [IO ByteString])
    -> !(IORef Int)
    -> !(IORef Int)
    -> AuthMockClient 'Connected

instance Client AuthMockClient where
  connect = error "AuthMockClient: connect not supported"
  close (AuthMockConnected _ _ _ closes _) =
    liftIO $ incrementRef closes
  abort (AuthMockConnected _ _ _ _ aborts) =
    liftIO $ incrementRef aborts
  send (AuthMockConnected sent sendCount _ _ _) lbs =
    liftIO $ do
      atomicModifyIORef' sent $ \old ->
        (old <> LBS.toStrict lbs, ())
      atomically $ modifyTVar' sendCount (+ 1)
  receive (AuthMockConnected _ _ script _ _) =
    liftIO $ nextScriptedReceive script

data AuthConnectionRecord = AuthConnectionRecord
  { authRecordAddress   :: !NodeAddress
  , authRecordIndex     :: !Int
  , authRecordSent      :: !(IORef ByteString)
  , authRecordSendCount :: !(TVar Int)
  , authRecordCloses    :: !(IORef Int)
  , authRecordAborts    :: !(IORef Int)
  }

type AuthScript = NodeAddress -> Int -> IO [IO ByteString]

createAuthMockConnector
  :: AuthScript
  -> IO
      ( NodeAddress -> IO (AuthMockClient 'Connected)
      , IO [AuthConnectionRecord]
      )
createAuthMockConnector scriptFor = do
  counts <- newIORef Map.empty
  records <- newIORef []
  let connector addr = do
        index <- atomicModifyIORef' counts $ \current ->
          let index = Map.findWithDefault 0 addr current
          in (Map.insert addr (index + 1) current, index)
        sent <- newIORef BS.empty
        sendCount <- newTVarIO 0
        script <- scriptFor addr index >>= newIORef
        closes <- newIORef 0
        aborts <- newIORef 0
        let record = AuthConnectionRecord
              addr index sent sendCount closes aborts
        atomicModifyIORef' records $ \existing ->
          (existing ++ [record], ())
        return $ AuthMockConnected sent sendCount script closes aborts
  return (connector, readIORef records)

nextScriptedReceive :: IORef [IO ByteString] -> IO ByteString
nextScriptedReceive script = do
  next <- atomicModifyIORef' script $ \case
    []       -> ([], Nothing)
    (x : xs) -> (xs, Just x)
  case next of
    Just action -> action
    Nothing     -> throwIO $ userError "Mock response script exhausted"

incrementRef :: IORef Int -> IO ()
incrementRef ref =
  atomicModifyIORef' ref $ \count -> (count + 1, ())

replyWith :: RespData -> IO ByteString
replyWith = return . encodeResp

commandBytes :: [ByteString] -> ByteString
commandBytes =
  LBS.toStrict . Builder.toLazyByteString . encodeCommandBuilder

authCommandFor :: ClusterAuthentication -> ByteString
authCommandFor = commandBytes . authCommandArguments

authCommandArguments :: ClusterAuthentication -> [ByteString]
authCommandArguments (ClusterPassword password) =
  ["AUTH", password]
authCommandArguments (ClusterACL username password) =
  ["HELLO", "2", "AUTH", username, password]

recordSentBytes :: AuthConnectionRecord -> IO ByteString
recordSentBytes = readIORef . authRecordSent

findAuthRecord
  :: [AuthConnectionRecord]
  -> NodeAddress
  -> Int
  -> AuthConnectionRecord
findAuthRecord records addr index =
  case [record | record <- records
               , authRecordAddress record == addr
               , authRecordIndex record == index] of
    [record] -> record
    _        -> error $ "Missing connection record for " ++ show (addr, index)

countOccurrences :: ByteString -> ByteString -> Int
countOccurrences needle = go 0
  where
    go count haystack
      | BS.null needle = count
      | otherwise =
          case BS.breakSubstring needle haystack of
            (_, suffix) | BS.null suffix -> count
            (_, suffix) ->
              go (count + 1) $ BS.drop (BS.length needle) suffix

twoMasterClusterSlots :: RespData
twoMasterClusterSlots =
  RespArray
    [ slotRange 0 8191 node1 "node-1"
    , slotRange 8192 16383 node2 "node-2"
    ]
  where
    slotRange start end addr nodeId =
      RespArray
        [ RespInteger start
        , RespInteger end
        , RespArray
            [ RespBulkString $ BS.pack $ map (fromIntegral . fromEnum) $
                nodeHost addr
            , RespInteger $ fromIntegral $ nodePort addr
            , RespBulkString nodeId
            ]
        ]

singleMasterClusterSlots :: NodeAddress -> ByteString -> RespData
singleMasterClusterSlots addr nodeId =
  RespArray
    [ RespArray
        [ RespInteger 0
        , RespInteger 16383
        , RespArray
            [ RespBulkString $ BS.pack $ map (fromIntegral . fromEnum) $
                nodeHost addr
            , RespInteger $ fromIntegral $ nodePort addr
            , RespBulkString nodeId
            ]
        ]
    ]

keyForSlotRange :: (Word16 -> Bool) -> ByteString
keyForSlotRange predicate = findKey (0 :: Int)
  where
    findKey number
      | predicate (calculateSlot candidate) = candidate
      | otherwise = findKey (number + 1)
      where
        candidate = BS8.pack $ "auth-key-" ++ show number

clusterAuthenticationSpec :: Spec
clusterAuthenticationSpec =
  describe "per-connection cluster authentication" $ do
    it "authenticates the seed with AUTH before topology discovery" $ do
      let credentials = ClusterPassword "password-secret"
      (connector, getRecords) <- createAuthMockConnector $ \_ _ ->
        return
          [ replyWith $ RespSimpleString "OK"
          , replyWith validClusterSlots
          ]
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["CLUSTER", "SLOTS"] 1
      sent <- recordSentBytes seedRecord
      sent `shouldBe`
        authCommandFor credentials <> commandBytes ["CLUSTER", "SLOTS"]
      closeClusterClient client

    it "authenticates ACL users with HELLO 2 before topology discovery" $ do
      let credentials = ClusterACL "acl-user" "acl-password-secret"
      (connector, getRecords) <- createAuthMockConnector $ \_ _ ->
        return
          [ replyWith $ RespArray
              [ RespBulkString "proto", RespInteger 2 ]
          , replyWith validClusterSlots
          ]
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["CLUSTER", "SLOTS"] 1
      sent <- recordSentBytes seedRecord
      sent `shouldBe`
        authCommandFor credentials <> commandBytes ["CLUSTER", "SLOTS"]
      closeClusterClient client

    it "initializes pooled and keyed connections once across two masters" $ do
      let credentials = ClusterPassword "multi-master-secret"
          key1 = keyForSlotRange (< 8192)
          key2 = keyForSlotRange (>= 8192)
          script addr index
            | addr == node1 && index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith twoMasterClusterSlots
                  , replyWith $ RespSimpleString "PONG"
                  ]
            | addr == node1 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespBulkString "node-one"
                  ]
            | otherwise =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespBulkString "node-two"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      executeKeyedClusterCommand client key1 ["GET", key1]
        `shouldReturn` Right (RespBulkString "node-one")
      executeKeyedClusterCommand client key2 ["GET", key2]
        `shouldReturn` Right (RespBulkString "node-two")
      executeKeylessClusterCommand client ping
        `shouldReturn` Right (RespSimpleString "PONG")
      records <- getRecords
      length records `shouldBe` 3
      mapM_ (\record -> do
          awaitCommandCount record
            (if authRecordAddress record == node1 && authRecordIndex record == 0
              then ["PING"]
              else ["GET", if authRecordAddress record == node1 then key1 else key2])
            1
          sent <- recordSentBytes record
          countOccurrences (authCommandFor credentials) sent `shouldBe` 1
          BS.isPrefixOf (authCommandFor credentials) sent `shouldBe` True
        ) records
      closeClusterClient client

    it "authenticates ASK targets before ASKING and the redirected command" $ do
      let credentials = ClusterPassword "ask-secret"
          key = "ask-key"
          script addr index
            | addr == node1 && index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith validClusterSlots
                  ]
            | addr == node1 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespError "ASK 3999 127.0.0.2:6380"
                  ]
            | otherwise =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespSimpleString "OK"
                  , replyWith $ RespBulkString "ask-value"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "ask-value")
      records <- getRecords
      let targetRecord = findAuthRecord records node2 0
      awaitCommandCount targetRecord ["GET", key] 1
      sent <- recordSentBytes targetRecord
      sent `shouldBe`
        authCommandFor credentials
          <> commandBytes ["ASKING"]
          <> commandBytes ["GET", key]
      closeClusterClient client

    it "authenticates a direct MOVED target and its refresh connection" $ do
      let credentials = ClusterPassword "moved-secret"
          key = "moved-key"
          script addr index
            | addr == node1 && index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ singleMasterClusterSlots node1 "node-1"
                  ]
            | addr == node1 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespError "MOVED 3999 127.0.0.2:6380"
                  ]
            | index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespBulkString "moved-value"
                  ]
            | otherwise =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ singleMasterClusterSlots node2 "node-2"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "moved-value")
      records <- getRecords
      let targetRecord = findAuthRecord records node2 0
      awaitCommandCount targetRecord ["GET", key] 1
      targetSent <- recordSentBytes targetRecord
      targetSent `shouldBe`
        authCommandFor credentials <> commandBytes ["GET", key]
      let refreshRecord = findAuthRecord records node2 1
      awaitCommandCount refreshRecord ["CLUSTER", "SLOTS"] 1
      refreshSent <- recordSentBytes refreshRecord
      refreshSent `shouldBe`
        authCommandFor credentials <> commandBytes ["CLUSTER", "SLOTS"]
      closeClusterClient client

    it "reapplies authentication after a failed multiplexer is replaced" $ do
      let credentials = ClusterPassword "replacement-secret"
          key = "replacement-key"
          script _addr index
            | index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith validClusterSlots
                  , replyWith validClusterSlots
                  ]
            | index == 1 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , throwIO $ userError "worker receive failed"
                  ]
            | otherwise =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespBulkString "replacement-value"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "replacement-value")
      records <- getRecords
      length records `shouldBe` 3
      mapM_ (\record -> do
          awaitCommandCount record (authCommandArguments credentials) 1
          sent <- recordSentBytes record
          BS.isPrefixOf (authCommandFor credentials) sent `shouldBe` True
        ) records
      closeClusterClient client

    it "reapplies authentication after a pooled connection is discarded" $ do
      let credentials = ClusterPassword "pool-reconnect-secret"
          script _ index
            | index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith validClusterSlots
                  ]
            | otherwise =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith $ RespSimpleString "PONG"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      _ <- executeKeylessClusterCommand client $
        liftIO $ throwIO $ userError "discard pooled connection"
      executeKeylessClusterCommand client ping
        `shouldReturn` Right (RespSimpleString "PONG")
      records <- getRecords
      length records `shouldBe` 2
      mapM_ (\record -> do
          awaitCommandCount record (authCommandArguments credentials) 1
          sent <- recordSentBytes record
          BS.isPrefixOf (authCommandFor credentials) sent `shouldBe` True
        ) records
      closeClusterClient client

    it "retains the initialized connector for pinned library-owned paths" $ do
      let credentials = ClusterPassword "pinned-secret"
          script addr _
            | addr == node1 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith validClusterSlots
                  ]
            | otherwise =
                return [replyWith $ RespSimpleString "OK"]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      pinned <- clusterConnector client node2
      records <- getRecords
      let pinnedRecord = findAuthRecord records node2 0
      awaitCommandCount pinnedRecord (authCommandArguments credentials) 1
      sent <- recordSentBytes pinnedRecord
      sent `shouldBe` authCommandFor credentials
      close pinned
      closeClusterClient client

    it "returns a typed redacted failure and aborts rejected AUTH once" $ do
      let secret = "rejected-auth-secret"
          credentials = ClusterPassword secret
      (connector, getRecords) <- createAuthMockConnector $ \_ _ ->
        return [replyWith $ RespError $ "WRONGPASS " <> secret]
      result <- try $ createClusterClientWithAuthentication
        testClusterConfig credentials connector
        :: IO (Either SomeException (ClusterClient AuthMockClient))
      case result of
        Left err ->
          case fromException err of
            Just (ClusterAuthenticationFailed endpoint) ->
              do
                endpoint `shouldBe` node1
                show err `shouldNotContain` BS8.unpack secret
            Nothing -> expectationFailure $
              "Expected ClusterAuthenticationFailed, got: " ++ show err
        Right _ ->
          expectationFailure "Rejected AUTH unexpectedly created a client"
      records <- getRecords
      let record = findAuthRecord records node1 0
      readIORef (authRecordCloses record) `shouldReturn` 0
      readIORef (authRecordAborts record) `shouldReturn` 1

    it "returns a typed redacted error when a new keyed connection rejects AUTH" $ do
      let secret = "keyed-auth-secret"
          credentials = ClusterPassword secret
          key = "keyed-auth-key"
          script _ index
            | index == 0 =
                return
                  [ replyWith $ RespSimpleString "OK"
                  , replyWith validClusterSlots
                  ]
            | otherwise =
                return [replyWith $ RespError $ "WRONGPASS " <> secret]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      result <- executeKeyedClusterCommand client key ["GET", key]
      case result of
        Left (ClusterAuthenticationError
              (ClusterAuthenticationFailed endpoint)) -> do
          endpoint `shouldBe` node1
          show result `shouldNotContain` BS8.unpack secret
        other -> expectationFailure $
          "Expected ClusterAuthenticationError, got: " ++ show other
      records <- getRecords
      let record = findAuthRecord records node1 1
      readIORef (authRecordCloses record) `shouldReturn` 0
      readIORef (authRecordAborts record) `shouldReturn` 1
      closeClusterClient client

    it "bounds stalled authentication and aborts the transport once" $ do
      started <- newEmptyMVar
      stalled <- newEmptyMVar
      workerFinished <- newEmptyMVar
      let secret = "timeout-auth-secret"
          credentials = ClusterPassword secret
          timeoutConfig = testClusterConfig
            { clusterPoolConfig = testPoolConfig
                { connectionTimeout = 1 }
            }
          stalledReply =
            (putMVar started () >> takeMVar stalled)
              `finally` putMVar workerFinished ()
      (connector, getRecords) <- createAuthMockConnector $ \_ _ ->
        return [stalledReply]
      result <- try $ createClusterClientWithAuthentication
        timeoutConfig credentials connector
        :: IO (Either SomeException (ClusterClient AuthMockClient))
      case result of
        Left err ->
          case fromException err of
            Just timeoutError ->
              do
                connectionTimeoutPhase timeoutError
                  `shouldBe` Authentication
                show err `shouldNotContain` BS8.unpack secret
            Nothing -> expectationFailure $
              "Expected ConnectionSetupTimeout, got: " ++ show err
        Right _ ->
          expectationFailure "Stalled AUTH unexpectedly created a client"
      timeout 1000000 (takeMVar started) `shouldReturn` Just ()
      timeout 1000000 (takeMVar workerFinished) `shouldReturn` Just ()
      records <- getRecords
      let record = findAuthRecord records node1 0
      readIORef (authRecordCloses record) `shouldReturn` 0
      readIORef (authRecordAborts record) `shouldReturn` 1

    it "rejects runtime cluster auth without touching a connection" $ do
      let credentials = ClusterPassword "construction-secret"
      (connector, getRecords) <- createAuthMockConnector $ \_ _ ->
        return
          [ replyWith $ RespSimpleString "OK"
          , replyWith validClusterSlots
          ]
      client <- createClusterClientWithAuthentication
        testClusterConfig credentials connector
      recordsBefore <- getRecords
      sentBefore <- recordSentBytes $ findAuthRecord recordsBefore node1 0
      result <- try $ runClusterCommandClient client
        (auth "ignored-user" "ignored-secret" :: ClusterCommandClient AuthMockClient RespData)
        :: IO (Either ClusterRuntimeAuthenticationUnsupported RespData)
      result `shouldBe` Left ClusterRuntimeAuthenticationUnsupported
      recordsAfter <- getRecords
      sentAfter <- recordSentBytes $ findAuthRecord recordsAfter node1 0
      sentAfter `shouldBe` sentBefore
      closeClusterClient client

movedRedirectSpec :: Spec
movedRedirectSpec =
  describe "MOVED redirect recovery" $ do
    it "retries the authoritative target and patches the next route" $ do
      let key = "moved-direct-key"
          slot = calculateSlot key
          moved = movedResponse slot node2
          script address index
            | address == node1 && index == 0 =
                return [replyWith moved]
            | address == node1 =
                throwIO $ userError "seed unavailable"
            | address == node2 && index == 0 =
                return
                  [ replyWith $ RespBulkString "first-value"
                  , replyWith $ RespBulkString "second-value"
                  ]
            | otherwise =
                return
                  [replyWith $ singleMasterClusterSlots node2 "node-2"]
      (connector, getRecords) <- createAuthMockConnector script
      topology <- mkTopology node1
      client <- mkAuthMockClusterClient testClusterConfig connector topology

      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "first-value")
      updated <- readTVarIO $ clusterTopology client
      findNodeAddressForSlot updated slot `shouldBe` Just node2
      let patchedNodeId = topologySlots updated V.! fromIntegral slot
      nodeAddress <$> Map.lookup patchedNodeId (topologyNodes updated)
        `shouldBe` Just node2
      Map.size (topologyNodes updated) `shouldBe` 1
      length
        [ ()
        | node <- Map.elems $ topologyNodes updated
        , range <- nodeSlotsServed node
        , slot >= slotStart range
        , slot <= slotEnd range
        ]
        `shouldBe` 1

      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "second-value")
      records <- getRecords
      let staleRecord = findAuthRecord records node1 0
      awaitCommandCount staleRecord ["GET", key] 1
      staleSent <- recordSentBytes staleRecord
      staleSent `shouldBe` commandBytes ["GET", key]
      let targetRecord = findAuthRecord records node2 0
      awaitCommandCount targetRecord ["GET", key] 2
      targetSent <- recordSentBytes targetRecord
      targetSent `shouldBe`
        commandBytes ["GET", key] <> commandBytes ["GET", key]
      BS.isInfixOf (commandBytes ["ASKING"]) targetSent `shouldBe` False
      closeClusterClient client

    it "refreshes from an alternate known master when target and seed refresh fail" $ do
      let key = keyForSlotRange (< 8192)
          slot = calculateSlot key
          moved = movedResponse slot node2
      attempts <- newIORef Map.empty
      (rawConnector, getRecords) <- createAuthMockConnector $ \address index ->
        if address == node1 && index == 0
          then return [replyWith moved]
          else if address == node2 && index == 0
            then return [replyWith $ RespBulkString "redirected-value"]
            else if address == node3
              then return
                [replyWith $ singleMasterClusterSlots node2 "node-2"]
              else throwIO $ userError "refresh candidate unavailable"
      let connector address = do
            atomicModifyIORef' attempts $ \current ->
              (Map.insertWith (+) address (1 :: Int) current, ())
            rawConnector address
      topology <- mkTwoMasterTopology node1 node3
      client <- mkAuthMockClusterClient testClusterConfig connector topology

      executeKeyedClusterCommand client key ["GET", key]
        `shouldReturn` Right (RespBulkString "redirected-value")
      updated <- readTVarIO $ clusterTopology client
      findNodeAddressForSlot updated slot `shouldBe` Just node2
      counts <- readIORef attempts
      Map.findWithDefault 0 node2 counts `shouldBe` 2
      Map.findWithDefault 0 node1 counts `shouldBe` 2
      Map.findWithDefault 0 node3 counts `shouldBe` 1
      records <- getRecords
      let alternateRecord = findAuthRecord records node3 0
      awaitCommandCount alternateRecord ["CLUSTER", "SLOTS"] 1
      alternateSent <- recordSentBytes alternateRecord
      alternateSent `shouldBe` commandBytes ["CLUSTER", "SLOTS"]
      closeClusterClient client

    it "returns a bounded typed failure when target and refresh candidates fail" $ do
      let key = "bounded-moved-key"
          slot = calculateSlot key
          moved = movedResponse slot node2
          retryConfig = testClusterConfig
            { clusterMaxRetries = 3
            , clusterRetryDelay = 1000
            }
      attempts <- newIORef Map.empty
      (rawConnector, _) <- createAuthMockConnector $ \address index ->
        if address == node1 && index == 0
          then return [replyWith moved]
          else throwIO $ userError "all redirected paths unavailable"
      let connector address = do
            atomicModifyIORef' attempts $ \current ->
              (Map.insertWith (+) address (1 :: Int) current, ())
            rawConnector address
      topology <- mkTopology node1
      client <- mkAuthMockClusterClient retryConfig connector topology

      outcome <- timeout 1000000 $
        executeKeyedClusterCommand client key ["GET", key]
      outcome `shouldSatisfy` \case
        Just (Left (MaxRetriesExceeded _)) -> True
        _                                  -> False
      counts <- readIORef attempts
      sum (Map.elems counts) `shouldBe` 7
      closeClusterClient client

    it "bounds repeated MOVED replies without refreshing through ASKING" $ do
      let key = "repeated-moved-key"
          slot = calculateSlot key
          retryConfig = testClusterConfig
            { clusterMaxRetries = 3
            , clusterRetryDelay = 1000
            }
          script address _
            | address == node1 =
                return [replyWith $ movedResponse slot node2]
            | address == node2 =
                return [replyWith $ movedResponse slot node3]
            | otherwise =
                return [replyWith $ movedResponse slot node2]
      (connector, getRecords) <- createAuthMockConnector script
      topology <- mkTopology node1
      client <- mkAuthMockClusterClient retryConfig connector topology

      result <- executeKeyedClusterCommand client key ["GET", key]
      case result of
        Left (MaxRetriesExceeded message) -> do
          message `shouldContain` "Max retries (3) exceeded"
          message `shouldContain` "MovedError"
        other -> expectationFailure $
          "Expected MOVED retry exhaustion, got: " ++ show other
      records <- getRecords
      length records `shouldBe` 3
      mapM_ (\record -> awaitCommandCount record ["GET", key] 1) records
      sent <- mapM recordSentBytes records
      mapM_ (\bytes ->
          BS.isInfixOf (commandBytes ["ASKING"]) bytes `shouldBe` False
        ) sent
      finalTopology <- readTVarIO $ clusterTopology client
      findNodeAddressForSlot finalTopology slot `shouldBe` Just node2
      closeClusterClient client

    it "merges provisional MOVED patches into a stale snapshot" $ do
      let firstKey = "concurrent-moved-one"
          firstSlot = calculateSlot firstKey
          secondKey = nextDifferentSlotKey firstSlot 0
          secondSlot = calculateSlot secondKey
      staleTopology <- mkTopology node1
      let committed = mergeRefreshedTopology staleTopology
            [(firstSlot, node2), (secondSlot, node3)]
      findNodeAddressForSlot committed firstSlot `shouldBe` Just node2
      findNodeAddressForSlot committed secondSlot `shouldBe` Just node3

    it "commits a stale refresh without losing concurrent MOVED patches" $ do
      let firstKey = "concurrent-moved-one"
          firstSlot = calculateSlot firstKey
          secondKey = nextDifferentSlotKey firstSlot 0
          secondSlot = calculateSlot secondKey
      staleTopology <- mkTopology node1
      topologyVar <- newTVarIO staleTopology
      snapshotReady <- newEmptyMVar
      allowCommit <- newEmptyMVar
      commitComplete <- newEmptyMVar
      _ <- forkIO $ do
        putMVar snapshotReady ()
        takeMVar allowCommit
        atomically $ commitRefreshedTopology topologyVar [] staleTopology
        putMVar commitComplete ()

      timeout 5000000 (takeMVar snapshotReady) `shouldReturn` Just ()
      atomically $ do
        patchMovedSlot topologyVar firstSlot node2
        patchMovedSlot topologyVar secondSlot node3
      putMVar allowCommit ()
      timeout 5000000 (takeMVar commitComplete) `shouldReturn` Just ()

      committed <- readTVarIO topologyVar
      findNodeAddressForSlot committed firstSlot `shouldBe` Just node2
      findNodeAddressForSlot committed secondSlot `shouldBe` Just node3

    it "clears a confirmed provisional MOVED patch after refresh" $ do
      let key = "confirmed-moved-key"
          slot = calculateSlot key
      staleTopology <- mkTopology node1
      confirmedTopology <- mkTopology node2
      topologyVar <- newTVarIO staleTopology
      atomically $ do
        patchMovedSlot topologyVar slot node2
        commitRefreshedTopology topologyVar [] confirmedTopology

      committed <- readTVarIO topologyVar
      findNodeAddressForSlot committed slot `shouldBe` Just node2
      provisionalMovedPatches committed `shouldBe` []

mkAuthMockClusterClient
  :: ClusterConfig
  -> (NodeAddress -> IO (AuthMockClient 'Connected))
  -> ClusterTopology
  -> IO (ClusterClient AuthMockClient)
mkAuthMockClusterClient config connector topology = do
  topologyVar <- newTVarIO topology
  pool <- createPool $ clusterPoolConfig config
  muxPool <- createMultiplexPool connector 1
  refreshLock <- newMVar ()
  return $
    ClusterClient topologyVar pool config connector refreshLock muxPool

movedResponse :: Word16 -> NodeAddress -> RespData
movedResponse slot address =
  RespError $ BS8.pack $
    "MOVED " ++ show slot ++ " "
      ++ nodeHost address ++ ":" ++ show (nodePort address)

nextDifferentSlotKey :: Word16 -> Int -> ByteString
nextDifferentSlotKey slot index
  | calculateSlot candidate /= slot = candidate
  | otherwise = nextDifferentSlotKey slot $ index + 1
  where
    candidate = BS8.pack $ "concurrent-moved-key-" ++ show index

askRedirectAdditionalSpec :: Spec
askRedirectAdditionalSpec = describe "additional ASK redirect integration" $ do
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

-- ---------------------------------------------------------------------------
-- Cluster error classification and retry policy
-- ---------------------------------------------------------------------------

data ExpectedPathError
  = ImmediateError ClusterError
  | ExhaustedWith String

clusterErrorReplies :: [(String, RespData, ExpectedPathError)]
clusterErrorReplies =
  [ ( "MOVED"
    , RespError "MOVED 3999 127.0.0.2:6380"
    , ExhaustedWith "MovedError"
    )
  , ( "ASK"
    , RespError "ASK 3999 127.0.0.2:6380"
    , ExhaustedWith "AskError"
    )
  , ( "TRYAGAIN"
    , RespError "TRYAGAIN migration still converging"
    , ExhaustedWith "TryAgainError"
    )
  , ( "CLUSTERDOWN"
    , RespError "CLUSTERDOWN cluster state is not ok"
    , ExhaustedWith "ClusterDownError"
    )
  , ( "CROSSSLOT"
    , RespError "CROSSSLOT keys span slots"
    , ImmediateError $ CrossSlotError "CROSSSLOT keys span slots"
    )
  , ( "ordinary Redis error"
    , RespError "WRONGTYPE full server cause"
    , ImmediateError $ RedisCommandError "WRONGTYPE full server cause"
    )
  ]

assertPathError
  :: ExpectedPathError
  -> Either ClusterError RespData
  -> Expectation
assertPathError (ImmediateError expected) actual =
  actual `shouldBe` Left expected
assertPathError (ExhaustedWith expectedCause) actual =
  case actual of
    Left (MaxRetriesExceeded message) ->
      message `shouldContain` expectedCause
    other -> expectationFailure $
      "Expected retry exhaustion containing "
        ++ show expectedCause ++ ", got: " ++ show other

retryTestConfig :: Int -> Int -> ClusterConfig
retryTestConfig attempts delay =
  testClusterConfig
    { clusterMaxRetries = attempts
    , clusterRetryDelay = delay
    }

runNormalErrorPath
  :: RespData
  -> IO (Either ClusterError RespData)
runNormalErrorPath reply = do
  (connector, _) <- createAuthMockConnector $ \_ index ->
    return $
      if index == 0
        then [replyWith validClusterSlots]
        else [replyWith reply]
  client <- createClusterClient
    (retryTestConfig 1 1)
    connector
  result <- executeKeyedClusterCommandUsingDelay
    (const $ return ())
    client
    "classification-key"
    ["GET", "classification-key"]
  closeClusterClient client
  return result

runRedirectTargetErrorPath
  :: Bool
  -> RespData
  -> IO (Either ClusterError RespData)
runRedirectTargetErrorPath useAsking reply = do
  let initialRedirect
        | useAsking = RespError "ASK 3999 127.0.0.2:6380"
        | otherwise = RespError "MOVED 3999 127.0.0.2:6380"
      script address index
        | address == node1 && index == 0 =
            return [replyWith validClusterSlots]
        | address == node1 =
            return [replyWith initialRedirect]
        | useAsking =
            return
              [ replyWith $ RespSimpleString "OK"
              , replyWith reply
              ]
        | otherwise =
            return [replyWith reply]
  (connector, _) <- createAuthMockConnector script
  client <- createClusterClient
    (retryTestConfig 2 1)
    connector
  result <- executeKeyedClusterCommandUsingDelay
    (const $ return ())
    client
    "classification-key"
    ["GET", "classification-key"]
  closeClusterClient client
  return result

clusterErrorClassificationSpec :: Spec
clusterErrorClassificationSpec =
  describe "cluster error execution and retry policy" $ do
    describe "identical classification across execution paths" $ do
      forM_ clusterErrorReplies $ \(label, reply, expected) -> do
        it ("classifies " ++ label ++ " on the normal slot path") $ do
          runNormalErrorPath reply >>= assertPathError expected

        it ("classifies " ++ label ++ " on a direct MOVED target") $ do
          runRedirectTargetErrorPath False reply >>= assertPathError expected

        it ("classifies " ++ label ++ " on an ASK target") $ do
          runRedirectTargetErrorPath True reply >>= assertPathError expected

    it "retries TRYAGAIN on the same route with exact exponential delays" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else
                  [ replyWith $ RespError "TRYAGAIN first"
                  , replyWith $ RespError "TRYAGAIN second"
                  , replyWith $ RespBulkString "value"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 7) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "tryagain-key"
        ["GET", "tryagain-key"]
      result `shouldBe` Right (RespBulkString "value")
      readIORef delays `shouldReturn` [7, 14]
      records <- getRecords
      let muxRecord = findAuthRecord records node1 1
      awaitCommandCount muxRecord ["GET", "tryagain-key"] 3
      closeClusterClient client

    it "exhausts TRYAGAIN after exactly the configured total attempts" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else
                  [ replyWith $ RespError "TRYAGAIN first"
                  , replyWith $ RespError "TRYAGAIN second"
                  , replyWith $ RespError "TRYAGAIN final cause"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 9) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "tryagain-exhaust-key"
        ["GET", "tryagain-exhaust-key"]
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "TRYAGAIN final cause"
        other -> expectationFailure $
          "Expected TRYAGAIN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [9, 18]
      records <- getRecords
      let muxRecord = findAuthRecord records node1 1
      awaitCommandCount muxRecord ["GET", "tryagain-exhaust-key"] 3
      closeClusterClient client

    it "saturates exponential backoff instead of overflowing Int" $ do
      delays <- newIORef []
      let initialDelay = maxBound `div` 2 + 1
          script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else
                  [ replyWith $ RespError "TRYAGAIN first"
                  , replyWith $ RespError "TRYAGAIN second"
                  , replyWith $ RespBulkString "value"
                  ]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient
        (retryTestConfig 3 initialDelay)
        connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "overflow-key"
        ["GET", "overflow-key"]
      result `shouldBe` Right (RespBulkString "value")
      readIORef delays `shouldReturn` [initialDelay, maxBound]
      closeClusterClient client

    it "refreshes and backs off CLUSTERDOWN within the attempt budget" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith validClusterSlots
                  , replyWith validClusterSlots
                  ]
                else
                  [ replyWith $ RespError "CLUSTERDOWN first"
                  , replyWith $ RespError "CLUSTERDOWN second"
                  , replyWith $ RespBulkString "recovered"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 5) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "clusterdown-key"
        ["GET", "clusterdown-key"]
      result `shouldBe` Right (RespBulkString "recovered")
      readIORef delays `shouldReturn` [5, 10]
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["CLUSTER", "SLOTS"] 3
      seedSent <- recordSentBytes seedRecord
      countOccurrences (commandBytes ["CLUSTER", "SLOTS"]) seedSent
        `shouldBe` 3
      closeClusterClient client

    it "bounds CLUSTERDOWN exhaustion and preserves the final cause" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith validClusterSlots
                  , replyWith validClusterSlots
                  ]
                else
                  [ replyWith $ RespError "CLUSTERDOWN first"
                  , replyWith $ RespError "CLUSTERDOWN second"
                  , replyWith $ RespError "CLUSTERDOWN final cause"
                  ]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 6) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "clusterdown-exhaust-key"
        ["GET", "clusterdown-exhaust-key"]
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [6, 12]
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["CLUSTER", "SLOTS"] 3
      seedSent <- recordSentBytes seedRecord
      countOccurrences (commandBytes ["CLUSTER", "SLOTS"]) seedSent
        `shouldBe` 3
      let muxRecord = findAuthRecord records node1 1
      awaitCommandCount
        muxRecord ["GET", "clusterdown-exhaust-key"] 3
      closeClusterClient client

    it "returns CROSSSLOT immediately without retry or delay" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else [replyWith $ RespError "CROSSSLOT permanent"]
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 5 11) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "crossslot-key"
        ["GET", "crossslot-key"]
      result `shouldBe` Left (CrossSlotError "CROSSSLOT permanent")
      readIORef delays `shouldReturn` []
      records <- getRecords
      let muxRecord = findAuthRecord records node1 1
      awaitCommandCount muxRecord ["GET", "crossslot-key"] 1
      closeClusterClient client

    it "keeps cancellation responsive during retry backoff" $ do
      delayStarted <- newEmptyMVar
      blockDelay <- newEmptyMVar
      finished <- newEmptyMVar
      let script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else [replyWith $ RespError "TRYAGAIN wait"]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      owner <- forkFinally
        (executeKeyedClusterCommandUsingDelay
          (\_ -> putMVar delayStarted () >> takeMVar blockDelay)
          client
          "cancel-key"
          ["GET", "cancel-key"])
        (putMVar finished)
      timeout 1000000 (takeMVar delayStarted) `shouldReturn` Just ()
      killThread owner
      outcome <- timeout 1000000 (takeMVar finished)
      outcome `shouldSatisfy` \case
        Just (Left err) ->
          case fromException err :: Maybe SomeAsyncException of
            Just _  -> True
            Nothing -> False
        _ -> False
      closeClusterClient client

    it "retries keyless TRYAGAIN with exact attempts and delays" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "TRYAGAIN first"
                  , replyWith $ RespError "TRYAGAIN second"
                  , replyWith $ RespSimpleString "PONG"
                  ]
                else []
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 4) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      result `shouldBe` Right (RespSimpleString "PONG")
      readIORef delays `shouldReturn` [4, 8]
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["PING"] 3
      sent <- recordSentBytes seedRecord
      countOccurrences (commandBytes ["PING"]) sent `shouldBe` 3
      closeClusterClient client

    it "refreshes and recovers keyless CLUSTERDOWN within the attempt budget" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN first"
                  , replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN second"
                  , replyWith validClusterSlots
                  , replyWith $ RespSimpleString "PONG"
                  ]
                else []
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 5) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      result `shouldBe` Right (RespSimpleString "PONG")
      readIORef delays `shouldReturn` [5, 10]
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["PING"] 3
      awaitCommandCount seedRecord ["CLUSTER", "SLOTS"] 3
      sent <- recordSentBytes seedRecord
      countOccurrences (commandBytes ["PING"]) sent `shouldBe` 3
      countOccurrences (commandBytes ["CLUSTER", "SLOTS"]) sent `shouldBe` 3
      closeClusterClient client

    it "exhausts keyless CLUSTERDOWN with the final command cause" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN first"
                  , replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN second"
                  , replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN final cause"
                  ]
                else []
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 6) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected keyless CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [6, 12]
      closeClusterClient client

    it "keeps keyed CLUSTERDOWN retries after invalid refresh topology" $ do
      delays <- newIORef []
      let script _ index =
            return $ case index of
              0 ->
                [ replyWith validClusterSlots
                , replyWith $ RespSimpleString "invalid topology"
                , replyWith $ RespSimpleString "still invalid topology"
                ]
              _ ->
                [ replyWith $ RespError "CLUSTERDOWN first"
                , replyWith $ RespError "CLUSTERDOWN second"
                , replyWith $ RespError "CLUSTERDOWN final cause"
                ]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 7) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "invalid-refresh-key"
        ["GET", "invalid-refresh-key"]
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected keyed CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [7, 14]
      closeClusterClient client

    it "keeps keyless CLUSTERDOWN retries after invalid refresh topology" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN first"
                  , replyWith $ RespSimpleString "invalid topology"
                  , replyWith $ RespError "CLUSTERDOWN second"
                  , replyWith $ RespSimpleString "still invalid topology"
                  , replyWith $ RespError "CLUSTERDOWN final cause"
                  ]
                else []
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 8) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected keyless CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [8, 16]
      closeClusterClient client

    it "treats keyed CLUSTERDOWN refresh IO failures as best effort" $ do
      delays <- newIORef []
      let script _ index =
            return $ case index of
              0 ->
                [ replyWith validClusterSlots
                , throwIO $ userError "refresh IO failure one"
                ]
              1 ->
                [ replyWith $ RespError "CLUSTERDOWN first"
                , replyWith $ RespError "CLUSTERDOWN second"
                , replyWith $ RespError "CLUSTERDOWN final cause"
                ]
              _ -> [throwIO $ userError "refresh IO failure two"]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 9) connector
      result <- executeKeyedClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        "io-refresh-key"
        ["GET", "io-refresh-key"]
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected keyed CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [9, 18]
      closeClusterClient client

    it "treats keyless CLUSTERDOWN refresh IO failures as best effort" $ do
      delays <- newIORef []
      let script _ index =
            return $ case index of
              0 ->
                [ replyWith validClusterSlots
                , replyWith $ RespError "CLUSTERDOWN first"
                , throwIO $ userError "refresh IO failure one"
                ]
              1 ->
                [ replyWith $ RespError "CLUSTERDOWN second"
                , throwIO $ userError "refresh IO failure two"
                ]
              _ ->
                [replyWith $ RespError "CLUSTERDOWN final cause"]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 10) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      case result of
        Left (MaxRetriesExceeded message) ->
          message `shouldContain` "CLUSTERDOWN final cause"
        other -> expectationFailure $
          "Expected keyless CLUSTERDOWN exhaustion, got: " ++ show other
      readIORef delays `shouldReturn` [10, 20]
      closeClusterClient client

    it "keeps cancellation responsive during keyless backoff" $ do
      delayStarted <- newEmptyMVar
      blockDelay <- newEmptyMVar
      finished <- newEmptyMVar
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "TRYAGAIN wait"
                  ]
                else []
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      owner <- forkFinally
        (executeKeylessClusterCommandUsingDelay
          (\_ -> putMVar delayStarted () >> takeMVar blockDelay)
          client
          ping)
        (putMVar finished)
      timeout 1000000 (takeMVar delayStarted) `shouldReturn` Just ()
      killThread owner
      outcome <- timeout 1000000 (takeMVar finished)
      outcome `shouldSatisfy` \case
        Just (Left err) ->
          case fromException err :: Maybe SomeAsyncException of
            Just _  -> True
            Nothing -> False
        _ -> False
      closeClusterClient client

    it "releases keyless CLUSTERDOWN refresh ownership on cancellation" $ do
      refreshStarted <- newEmptyMVar
      blockRefresh <- newEmptyMVar
      finished <- newEmptyMVar
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "CLUSTERDOWN wait"
                  , putMVar refreshStarted () >> takeMVar blockRefresh
                  ]
                else []
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      owner <- forkFinally
        (executeKeylessClusterCommand client ping)
        (putMVar finished)
      timeout 1000000 (takeMVar refreshStarted) `shouldReturn` Just ()
      killThread owner
      outcome <- timeout 1000000 (takeMVar finished)
      outcome `shouldSatisfy` \case
        Just (Left err) ->
          case fromException err :: Maybe SomeAsyncException of
            Just _  -> True
            Nothing -> False
        _ -> False
      refreshToken <- tryTakeMVar $ clusterRefreshLock client
      refreshToken `shouldBe` Just ()
      putMVar (clusterRefreshLock client) ()
      closeClusterClient client

    forM_
      [ ( "MOVED"
        , RespError "MOVED 3999 127.0.0.2:6380"
        , MovedError 3999 node2
        )
      , ( "ASK"
        , RespError "ASK 3999 127.0.0.2:6380"
        , AskError 3999 node2
        )
      ] $ \(label, reply, expected) ->
        it ("returns keyless " ++ label ++ " without following the redirect") $ do
          delays <- newIORef []
          let script _ index =
                return $
                  if index == 0
                    then [replyWith validClusterSlots, replyWith reply]
                    else []
          (connector, getRecords) <- createAuthMockConnector script
          client <- createClusterClient (retryTestConfig 3 11) connector
          result <- executeKeylessClusterCommandUsingDelay
            (\delay -> atomicModifyIORef' delays $ \seen ->
              (seen ++ [delay], ()))
            client
            ping
          result `shouldBe` Left expected
          readIORef delays `shouldReturn` []
          records <- getRecords
          let seedRecord = findAuthRecord records node1 0
          awaitCommandCount seedRecord ["PING"] 1
          sent <- recordSentBytes seedRecord
          countOccurrences (commandBytes ["PING"]) sent `shouldBe` 1
          closeClusterClient client

    it "returns keyless CROSSSLOT immediately without retry or delay" $ do
      delays <- newIORef []
      let script _ index =
            return $
              if index == 0
                then
                  [ replyWith validClusterSlots
                  , replyWith $ RespError "CROSSSLOT keyless permanent"
                  ]
                else []
      (connector, getRecords) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 12) connector
      result <- executeKeylessClusterCommandUsingDelay
        (\delay -> atomicModifyIORef' delays $ \seen ->
          (seen ++ [delay], ()))
        client
        ping
      result `shouldBe`
        Left (CrossSlotError "CROSSSLOT keyless permanent")
      readIORef delays `shouldReturn` []
      records <- getRecords
      let seedRecord = findAuthRecord records node1 0
      awaitCommandCount seedRecord ["PING"] 1
      sent <- recordSentBytes seedRecord
      countOccurrences (commandBytes ["PING"]) sent `shouldBe` 1
      closeClusterClient client

    it "returns ordinary server errors as low-level Left values" $ do
      let serverError = "ERR complete server explanation"
          secret = "credential-like-command-argument"
          script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else [replyWith $ RespError serverError]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      result <- executeKeyedClusterCommand client secret ["GET", secret]
      result `shouldBe` Left (RedisCommandError serverError)
      show result `shouldNotContain` BS8.unpack secret
      closeClusterClient client

    it "does not make ordinary errors success-shaped in the typed API" $ do
      let serverError = "WRONGTYPE full typed cause"
          script _ index =
            return $
              if index == 0
                then [replyWith validClusterSlots]
                else [replyWith $ RespError serverError]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      result <- try $ runClusterCommandClient client
        (get "typed-error-key"
          :: ClusterCommandClient AuthMockClient ByteString)
        :: IO (Either SomeException ByteString)
      case result of
        Left err -> show err `shouldContain` BS8.unpack serverError
        Right _  -> expectationFailure "Typed cluster error returned success"
      closeClusterClient client

    it "classifies ordinary errors from the low-level keyless API" $ do
      let serverError = "NOSCRIPT full keyless cause"
          script _ _ =
            return
              [ replyWith validClusterSlots
              , replyWith $ RespError serverError
              ]
      (connector, _) <- createAuthMockConnector script
      client <- createClusterClient (retryTestConfig 3 1) connector
      executeKeylessClusterCommand client
        (ping :: RedisCommandClient AuthMockClient RespData)
        `shouldReturn` Left (RedisCommandError serverError)
      closeClusterClient client

awaitCommandCount
  :: AuthConnectionRecord
  -> [ByteString]
  -> Int
  -> IO ()
awaitCommandCount record command expected = do
  observed <- timeout 5000000 await
  case observed of
    Just () -> return ()
    Nothing ->
      expectationFailure $
        "Timed out waiting for " ++ show expected ++ " sends of " ++ show command
  where
    await = do
      observed <- readTVarIO $ authRecordSendCount record
      sent <- recordSentBytes record
      if countOccurrences (commandBytes command) sent >= expected
        then return ()
        else do
          atomically $ do
            current <- readTVar $ authRecordSendCount record
            check $ current > observed
          await

askRedirectSuccessSpec :: Spec
askRedirectSuccessSpec = describe "successful command without ASK redirection" $ do
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
