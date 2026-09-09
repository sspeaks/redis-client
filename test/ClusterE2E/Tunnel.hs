{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module ClusterE2E.Tunnel (spec) where

import           ClusterE2E.Utils
import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (bracket, finally)
import           Control.Monad                 (forM_, when)
import qualified Control.Monad.State           as State
import qualified Data.Attoparsec.ByteString    as StrictParse
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Builder       as Builder
import qualified Data.ByteString.Char8         as BS8
import qualified Data.ByteString.Lazy          as LBS
import           Data.List                     (find, isInfixOf)
import qualified Data.Map.Strict               as Map
import           Database.Redis.Client         (Client (..),
                                                ConnectionStatus (Connected),
                                                PlainTextClient (NotConnectedPlainTextClient),
                                                close, connect)
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeAddress (..), NodeRole (..),
                                                calculateSlot,
                                                findNodeAddressForSlot)
import           Database.Redis.Cluster.Client (ClusterClient,
                                                closeClusterClient,
                                                clusterTopology,
                                                refreshTopology)
import           Database.Redis.Command        (ClientState (..),
                                                RedisCommandClient (..),
                                                RedisCommands (..), parseWith)
import           Database.Redis.Resp           (Encodable (encode),
                                                RespData (..))
import qualified Database.Redis.Resp           as Resp
import           Network.Socket                (AddrInfo (..),
                                                ShutdownCmd (ShutdownSend),
                                                Socket, SocketType (Stream),
                                                defaultProtocol, getAddrInfo,
                                                socket)
import qualified Network.Socket                as S
import           Network.Socket.ByteString     (recv, sendAll)
import           SlotMappingHelpers            (getKeyForNode)
import           System.Timeout                (timeout)
import           Test.Hspec

spec :: Spec
spec = describe "Cluster Tunnel Mode" $ do
  describe "Smart Proxy Mode" $ do
    it "smart mode makes cluster appear as single Redis instance" $
      withSmartProxy $ do
        conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))

        result1 <- runRedisCommand conn (set "smart:key1" "value1")
        result1 `shouldBe` RespSimpleString "OK"

        result2 <- runRedisCommand conn (get "smart:key1")
        result2 `shouldBe` RespBulkString "value1"

        result3 <- runRedisCommand conn ping
        result3 `shouldBe` RespSimpleString "PONG"

        close conn

        -- Verify that commands routed transparently by checking with cluster client
        bracket createTestClusterClient closeClusterClient $ \client -> do
          verifyResult <- runCmd client (get "smart:key1")
          verifyResult `shouldBe` RespBulkString "value1"
          _ <- runCmd_ client (del ["smart:key1"])
          pure ()

    it "smart mode handles commands that route to different nodes" $
      withSmartProxy $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)

          when (length masterNodes < 2) $
            expectationFailure "Need at least 2 master nodes for this test"

          let (node1:node2:_) = masterNodes
              key1 = getKeyForNode node1 "key1"
              key2 = getKeyForNode node2 "key2"

          conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))

          _ <- runRedisCommand_ conn (set key1 "value-node1")
          _ <- runRedisCommand_ conn (set key2 "value-node2")

          result1 <- runRedisCommand conn (get key1)
          result1 `shouldBe` RespBulkString "value-node1"

          result2 <- runRedisCommand conn (get key2)
          result2 `shouldBe` RespBulkString "value-node2"

          close conn

          _ <- runCmd_ client (del [key1])
          _ <- runCmd_ client (del [key2])
          pure ()

    it "smart mode works with various keys" $
      withSmartProxy $ do
        conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))

        result1 <- runRedisCommand conn (set "various:test" "value")
        result1 `shouldBe` RespSimpleString "OK"

        result2 <- runRedisCommand conn (get "various:test")
        result2 `shouldBe` RespBulkString "value"

        close conn

        bracket createTestClusterClient closeClusterClient $ \client -> do
          _ <- runCmd_ client (del ["various:test"])
          pure ()

    it "smart mode accepts fragmented, pipelined binary requests in order" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          owner <- firstMaster client
          let key = getKeyForNode owner "fragmented-pipeline"
              value = BS.cons 0 $ BS.cons 255 $ BS.replicate 5000 42
              setFrame = rawFrame ["SET", key, value]
              getFrame = rawFrame ["GET", key]
              wire = Builder.toLazyByteString (encode setFrame <> encode getFrame)
              (firstChunk, secondChunk) = LBS.splitAt 13 wire
          (`finally` deleteFromNode owner [key]) $
            bracket (connectProxy) close $ \conn -> do
              send conn firstChunk
              threadDelay 20000
              send conn secondChunk
              responses <- runRedisCommand conn $ RedisCommandClient $ do
                firstResponse <- parseWith $ receive conn
                secondResponse <- parseWith $ receive conn
                pure (firstResponse, secondResponse)
              responses `shouldBe` (RespSimpleString "OK", RespBulkString value)

    it "smart mode closes malformed streams before their trailing SET executes" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          owner <- firstMaster client
          let key = getKeyForNode owner "malformed-trailing-set"
              malformedThenSet =
                "?malformed\r\n"
                  <> encodeFrame (rawFrame ["SET", key, "must-not-apply"])
          (`finally` deleteFromNode owner [key]) $
            bracket connectProxySocket S.close $ \sock -> do
              sendAll sock (encodeFrame $ rawFrame ["PING"])
              (firstResponse, buffered) <- receiveProxyResponse sock BS.empty
              firstResponse `shouldBe` RespSimpleString "PONG"
              sendAll sock malformedThenSet
              (secondResponse, trailing) <- receiveProxyResponse sock buffered
              secondResponse `shouldSatisfy` isFramingError
              trailing `shouldBe` BS.empty
              expectProxyEof sock
              value <- runCmd_ client (get key)
              value `shouldBe` RespNullBulkString

    it "smart mode closes after a partial request write shutdown without executing it" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          owner <- firstMaster client
          let key = getKeyForNode owner "partial-eof-set"
              partial = BS.take 12 $ encodeFrame (rawFrame ["SET", key, "must-not-apply"])
          (`finally` deleteFromNode owner [key]) $
            bracket connectProxySocket S.close $ \sock -> do
              sendAll sock partial
              S.shutdown sock ShutdownSend
              expectProxyEof sock
              value <- runCmd_ client (get key)
              value `shouldBe` RespNullBulkString

    it "smart mode accepts a 1048576-byte encoded request and rejects limit plus one" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \_client -> do
          let accepted = echoFrameOfEncodedLength 1048576
              rejected = echoFrameOfEncodedLength 1048577
          BS.length accepted `shouldBe` 1048576
          BS.length rejected `shouldBe` 1048577
          bracket connectProxySocket S.close $ \acceptedSocket -> do
            sendAll acceptedSocket accepted
            (response, buffered) <- receiveProxyResponse acceptedSocket BS.empty
            response `shouldBe` RespBulkString (echoPayload accepted)
            buffered `shouldBe` BS.empty
          bracket connectProxySocket S.close $ \rejectedSocket -> do
            sendAll rejectedSocket rejected
            (response, buffered) <- receiveProxyResponse rejectedSocket BS.empty
            response `shouldSatisfy` isFramingError
            buffered `shouldBe` BS.empty
            expectProxyEof rejectedSocket

    it "smart mode handles multiple separate connections" $
      withSmartProxy $ do
        conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
        conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))

        result1 <- runRedisCommand conn1 (set "multi:key1" "client1-value")
        result1 `shouldBe` RespSimpleString "OK"

        result2 <- runRedisCommand conn2 (set "multi:key2" "client2-value")
        result2 `shouldBe` RespSimpleString "OK"

        result3 <- runRedisCommand conn1 (get "multi:key1")
        result3 `shouldBe` RespBulkString "client1-value"

        result4 <- runRedisCommand conn2 (get "multi:key2")
        result4 `shouldBe` RespBulkString "client2-value"

        -- Cross-client reads work
        result5 <- runRedisCommand conn1 (get "multi:key2")
        result5 `shouldBe` RespBulkString "client2-value"

        result6 <- runRedisCommand conn2 (get "multi:key1")
        result6 `shouldBe` RespBulkString "client1-value"

        close conn1
        close conn2

        bracket createTestClusterClient closeClusterClient $ \client -> do
          _ <- runCmd_ client (del ["multi:key1"])
          _ <- runCmd_ client (del ["multi:key2"])
          pure ()

    it "smart mode routes raw grammar shapes to the topology-selected owner and preserves bytes" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          master <- firstMaster client
          let binaryKey = getKeyForNode master "raw-binary"
              evalKey = getKeyForNode master "raw-eval"
              streamKey = getKeyForNode master "raw-stream"
              groupStreamKey = getKeyForNode master "raw-group-stream"
              sourceOne = getKeyForNode master "raw-zset-one"
              sourceTwo = getKeyForNode master "raw-zset-two"
              destination = getKeyForNode master "raw-zset-destination"
              multiOne = getKeyForNode master "raw-multi-one"
              multiTwo = getKeyForNode master "raw-multi-two"
              binaryValue = BS.pack [0, 255, 10, 13, 42]
              allKeys = [binaryKey, evalKey, streamKey, groupStreamKey, sourceOne, sourceTwo,
                         destination, multiOne, multiTwo]
          owner <- topologyOwnerForKey client evalKey
          nodeAddress owner `shouldBe` nodeAddress master
          forM_ allKeys $ \key -> do
            selectedOwner <- topologyOwnerForKey client key
            nodeAddress selectedOwner `shouldBe` nodeAddress owner
          (`finally` deleteFromNode owner allKeys) $ do
            bracket (connectProxy) close $ \conn -> do
              runRawProxyCommand conn ["PING", binaryValue]
                `shouldReturn` RespBulkString binaryValue
              runRawProxyCommand conn ["ECHO", BS.empty]
                `shouldReturn` RespBulkString BS.empty

              runRawProxyCommand conn ["SET", binaryKey, binaryValue]
                `shouldReturn` RespSimpleString "OK"
              runRawOnNode owner ["GET", binaryKey]
                `shouldReturn` RespBulkString binaryValue

              evalResponse <- runRawProxyCommand conn
                [ "EVAL"
                , "redis.call('SET', KEYS[1], ARGV[1]); return redis.call('GET', KEYS[1])"
                , "1"
                , evalKey
                , binaryValue
                ]
              evalResponse `shouldBe` RespBulkString binaryValue
              runRawOnNode owner ["GET", evalKey]
                `shouldReturn` RespBulkString binaryValue

              sha <- loadScript owner "return {KEYS[1],ARGV[1]}"
              runRawProxyCommand conn ["EVALSHA", sha, "1", evalKey, binaryValue]
                `shouldReturn` RespArray [RespBulkString evalKey, RespBulkString binaryValue]

              _ <- runRawProxyCommand conn ["XADD", streamKey, "*", "field", binaryValue]
              xreadResponse <- runRawProxyCommand conn ["XREAD", "COUNT", "1", "STREAMS", streamKey, "0-0"]
              xreadResponse `shouldSatisfy` isNonEmptyArray
              runRawOnNode owner ["XLEN", streamKey] `shouldReturn` RespInteger 1

              runRawProxyCommand conn ["XGROUP", "CREATE", groupStreamKey, "group", "0", "MKSTREAM"]
                `shouldReturn` RespSimpleString "OK"
              _ <- runRawProxyCommand conn ["XADD", groupStreamKey, "*", "field", "value"]
              xreadGroupResponse <- runRawProxyCommand conn
                ["XREADGROUP", "GROUP", "group", "consumer", "COUNT", "1", "STREAMS", groupStreamKey, ">"]
              xreadGroupResponse `shouldSatisfy` isNonEmptyArray
              runRawOnNode owner ["XLEN", groupStreamKey] `shouldReturn` RespInteger 1

              runRawProxyCommand conn ["ZADD", sourceOne, "1", "one"]
                `shouldReturn` RespInteger 1
              runRawProxyCommand conn ["ZADD", sourceTwo, "2", "one"]
                `shouldReturn` RespInteger 1
              runRawProxyCommand conn ["ZUNIONSTORE", destination, "2", sourceOne, sourceTwo]
                `shouldReturn` RespInteger 1
              runRawOnNode owner ["ZSCORE", destination, "one"]
                `shouldReturn` RespBulkString "3"

              runRawProxyCommand conn ["MSET", multiOne, "first", multiTwo, "second"]
                `shouldReturn` RespSimpleString "OK"
              runRawOnNode owner ["MGET", multiOne, multiTwo]
                `shouldReturn` RespArray [RespBulkString "first", RespBulkString "second"]

    it "smart mode returns exact local errors and leaves malformed and cross-slot candidates unchanged" $
      withSmartProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          (firstNode, secondNode) <- twoMasters client
          let firstKey = getKeyForNode firstNode "locally-rejected-first"
              secondKey = getKeyForNode secondNode "locally-rejected-second"
          firstOwner <- topologyOwnerForKey client firstKey
          secondOwner <- topologyOwnerForKey client secondKey
          calculateSlot firstKey `shouldNotBe` calculateSlot secondKey
          (`finally` deleteFromNode firstOwner [firstKey]) $
            (`finally` deleteFromNode secondOwner [secondKey]) $ do
              runRawOnNode firstOwner ["SET", firstKey, "first-before"]
                `shouldReturn` RespSimpleString "OK"
              runRawOnNode secondOwner ["SET", secondKey, "second-before"]
                `shouldReturn` RespSimpleString "OK"
              bracket (connectProxy) close $ \conn -> do
                unknownResponse <-
                  runRawProxyCommand conn ["NOT_A_REDIS_COMMAND", firstKey]
                assertExactLocalError unknownResponse "unknown command"
                malformedEvalResponse <- runRawProxyCommand conn
                  [ "EVAL"
                  , "redis.call('SET', KEYS[1], ARGV[1])"
                  , "not-a-number"
                  , firstKey
                  , "would-overwrite"
                  ]
                assertExactLocalError malformedEvalResponse "EVAL has an invalid key count"
                nonBulkResponse <-
                  runRawProxyFrame conn (RespArray [RespBulkString "SET", RespInteger 1])
                assertExactLocalError nonBulkResponse "Expected array command with bulk string arguments"
                malformedMsetResponse <-
                  runRawProxyCommand conn ["MSET", firstKey, "would-overwrite", secondKey]
                assertExactLocalError malformedMsetResponse "MSET has malformed arguments"
                crossSlotResponse <- runRawProxyCommand conn
                  ["MSET", firstKey, "cross-first", secondKey, "cross-second"]
                assertExactLocalError crossSlotResponse "CROSSSLOT Keys in request don't hash to the same slot"
              runRawOnNode firstOwner ["GET", firstKey]
                `shouldReturn` RespBulkString "first-before"
              runRawOnNode secondOwner ["GET", secondKey]
                `shouldReturn` RespBulkString "second-before"

    it "smart mode retries the same raw LPUSH frame after a live MOVED without duplicate mutation" $
      bracket createTestClusterClient closeClusterClient $ \beforeClient -> do
        topology <- readTVarIO (clusterTopology beforeClient)
        previousOwner <- firstMaster beforeClient
        replica <- replicaForMaster topology previousOwner
        let key = getKeyForNode previousOwner "failover-single-write"
            rawMutation = rawFrame ["LPUSH", key, "only-once"]
            cleanup = deleteFromTopologyOwner key
        (`finally` cleanup) $
          withSmartProxy $
          bracket (connectProxy) close $ \conn -> do
            runRawOnNode previousOwner ["DEL", key] `shouldReturn` RespInteger 0
            runRawOnNode replica ["CLUSTER", "FAILOVER", "FORCE"]
              `shouldReturn` RespSimpleString "OK"
            waitForMoved previousOwner key
            bracket createTestClusterClient closeClusterClient $ \afterClient -> do
              currentOwner <- waitForTopologyOwner afterClient key (nodeAddress previousOwner)
              mutationResponse <- runRawProxyFrame conn rawMutation
              mutationResponse `shouldBe` RespInteger 1
              lengthResponse <- runRawOnNode currentOwner ["LLEN", key]
              lengthResponse `shouldBe` RespInteger 1
              listResponse <- runRawOnNode currentOwner ["LRANGE", key, "0", "-1"]
              listResponse `shouldBe` RespArray [RespBulkString "only-once"]

  describe "Pinned Proxy Mode" $ do
    it "pinned mode creates one listener per cluster node and each works correctly" $
      withPinnedProxy $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)

          length masterNodes `shouldSatisfy` (>= 3)

          forM_ masterNodes $ \masterNode -> do
            let addr = nodeAddress masterNode
                localPort = nodePort addr
                testKey = getKeyForNode masterNode "test"

            conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))

            result1 <- runRedisCommand conn (set testKey "value")
            result1 `shouldBe` RespSimpleString "OK"

            result2 <- runRedisCommand conn (get testKey)
            result2 `shouldBe` RespBulkString "value"

            close conn

            _ <- runCmd_ client (del [testKey])
            pure ()

    it "pinned mode drains a large reply and pipelined replies while the client is idle" $
      withPinnedProxy $
        bracket createTestClusterClient closeClusterClient $ \client -> do
          master <- firstMaster client
          let addr = nodeAddress master
              key = getKeyForNode master "pinned-large-pipeline"
              value = BS.replicate 8192 42
              getFrame = rawFrame ["GET", key]
              pingFrame = rawFrame ["PING"]
          (`finally` deleteFromNode master [key]) $
            bracket (connect (NotConnectedPlainTextClient "localhost" (Just (nodePort addr)))) close $ \conn -> do
              runRedisCommand conn (set key value) `shouldReturn` RespSimpleString "OK"
              send conn (Builder.toLazyByteString (encode getFrame <> encode pingFrame))
              responses <- runRedisCommand conn $ RedisCommandClient $ do
                firstResponse <- parseWith $ receive conn
                secondResponse <- parseWith $ receive conn
                pure (firstResponse, secondResponse)
              responses `shouldBe` (RespBulkString value, RespSimpleString "PONG")

    it "pinned mode listeners forward to their respective nodes" $
      withPinnedProxy $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)

          when (length masterNodes < 2) $
            expectationFailure "Need at least 2 master nodes for this test"

          case masterNodes of
            (node1:node2:_) -> do
              let addr1 = nodeAddress node1
                  addr2 = nodeAddress node2
                  port1 = nodePort addr1
                  port2 = nodePort addr2
                  testKey1 = getKeyForNode node1 "node1"
                  testKey2 = getKeyForNode node2 "node2"

              conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just port1))
              conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just port2))

              _ <- runRedisCommand_ conn1 (set testKey1 "from-node1")
              _ <- runRedisCommand_ conn2 (set testKey2 "from-node2")

              result1 <- runRedisCommand conn1 (get testKey1)
              result1 `shouldBe` RespBulkString "from-node1"

              result2 <- runRedisCommand conn2 (get testKey2)
              result2 `shouldBe` RespBulkString "from-node2"

              close conn1
              close conn2

              _ <- runCmd_ client (del [testKey1])
              _ <- runCmd_ client (del [testKey2])
              pure ()
            _ -> expectationFailure "Expected at least 2 master nodes"

    it "pinned mode returns MOVED errors for keys not owned by the node" $
      withPinnedProxy $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)

          when (length masterNodes < 2) $
            expectationFailure "Need at least 2 master nodes for this test"

          case masterNodes of
            (node1:node2:_) -> do
              let addr1 = nodeAddress node1
                  port1 = nodePort addr1
                  wrongKey = getKeyForNode node2 "wrong"

              conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just port1))

              result <- runRedisCommand conn1 (get wrongKey)
              case result of
                RespError err -> BS8.isInfixOf "MOVED" err `shouldBe` True
                _ -> expectationFailure $ "Expected MOVED error, got: " ++ show result

              close conn1
            _ -> expectationFailure "Expected at least 2 master nodes"

    it "pinned mode rewrites CLUSTER SLOTS addresses to 127.0.0.1" $
      withPinnedProxy $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)

          case masterNodes of
            [] -> expectationFailure "No master nodes found in cluster topology"
            (firstMasterNode:_) -> do
              let addr      = nodeAddress firstMasterNode
                  localPort = nodePort addr

              conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))

              result <- runRedisCommand conn clusterSlots

              case result of
                RespArray slots -> do
                  length slots `shouldSatisfy` (> 0)
                  let resultStr = show result
                  resultStr `shouldSatisfy` \s -> "127.0.0.1" `isInfixOf` s
                  resultStr `shouldSatisfy` \s -> not ("redis1.local" `isInfixOf` s)
                other -> expectationFailure $ "Expected RespArray from CLUSTER SLOTS, got: " ++ show other

              close conn

connectProxy :: IO (PlainTextClient 'Connected)
connectProxy = connect (NotConnectedPlainTextClient "localhost" (Just 6379))

connectProxySocket :: IO Socket
connectProxySocket = do
  addresses <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6379")
  case addresses of
    address : _ -> do
      sock <- socket (addrFamily address) Stream defaultProtocol
      S.connect sock (addrAddress address)
      pure sock
    [] -> expectationFailure "Could not resolve the smart proxy socket" >> error "unreachable"

receiveProxyResponse :: Socket -> BS.ByteString -> IO (RespData, BS.ByteString)
receiveProxyResponse sock buffered =
  case StrictParse.parse Resp.parseRespData buffered of
    StrictParse.Done remainder response -> pure (response, remainder)
    StrictParse.Fail _ _ err -> expectationFailure ("Invalid proxy response: " <> err) >> error "unreachable"
    StrictParse.Partial _ -> do
      received <- timeout (2 * 1000000) (recv sock 4096)
      case received of
        Nothing -> expectationFailure "Timed out waiting for smart proxy response" >> error "unreachable"
        Just bytes
          | BS.null bytes -> expectationFailure "Smart proxy closed before a complete response" >> error "unreachable"
          | otherwise -> receiveProxyResponse sock (buffered <> bytes)

expectProxyEof :: Socket -> Expectation
expectProxyEof sock = do
  result <- timeout (2 * 1000000) (recv sock 4096)
  result `shouldBe` Just BS.empty

isFramingError :: RespData -> Bool
isFramingError (RespError message) =
  "ERR Failed to parse command:" `BS.isPrefixOf` message
isFramingError _ = False

echoFrameOfEncodedLength :: Int -> BS.ByteString
echoFrameOfEncodedLength encodedLength =
  encodeFrame $ rawFrame ["ECHO", BS.replicate (encodedLength - 26) 42]

echoPayload :: BS.ByteString -> BS.ByteString
echoPayload encodedFrame =
  BS.replicate (BS.length encodedFrame - 26) 42

runRawProxyCommand :: PlainTextClient 'Connected -> [BS.ByteString] -> IO RespData
runRawProxyCommand conn = runRawProxyFrame conn . rawFrame

runRawProxyFrame :: PlainTextClient 'Connected -> RespData -> IO RespData
runRawProxyFrame conn frame = runRedisCommand conn $ rawCommand frame

runRawOnNode :: ClusterNode -> [BS.ByteString] -> IO RespData
runRawOnNode node command =
  bracket
    (connect $ NotConnectedPlainTextClient (nodeHost address) (Just $ nodePort address))
    close
    (\conn -> runRawProxyCommand conn command)
  where
    address = nodeAddress node

loadScript :: ClusterNode -> BS.ByteString -> IO BS.ByteString
loadScript node script = do
  result <- runRawOnNode node ["SCRIPT", "LOAD", script]
  case result of
    RespBulkString sha -> pure sha
    other              -> expectationFailure ("SCRIPT LOAD failed: " ++ show other) >> error "unreachable"

rawFrame :: [BS.ByteString] -> RespData
rawFrame = RespArray . map RespBulkString

encodeFrame :: RespData -> BS.ByteString
encodeFrame = LBS.toStrict . Builder.toLazyByteString . encode

rawCommand :: RespData -> RedisCommandClient PlainTextClient RespData
rawCommand frame = RedisCommandClient $ do
  state <- State.get
  send (getClient state) (Builder.toLazyByteString $ encode frame)
  parseWith (receive $ getClient state)

firstMaster :: ClusterClient PlainTextClient -> IO ClusterNode
firstMaster client = do
  topology <- readTVarIO (clusterTopology client)
  case filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology) of
    node:_ -> pure node
    []     -> expectationFailure "No master nodes found in cluster topology" >> error "unreachable"

twoMasters :: ClusterClient PlainTextClient -> IO (ClusterNode, ClusterNode)
twoMasters client = do
  topology <- readTVarIO (clusterTopology client)
  case filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology) of
    firstNode:secondNode:_ -> pure (firstNode, secondNode)
    _ -> expectationFailure "Fixture must provide at least two master nodes" >> error "unreachable"

deleteFromNode :: ClusterNode -> [BS.ByteString] -> IO ()
deleteFromNode node keys = do
  _ <- runRawOnNode node ("DEL" : keys)
  pure ()

deleteFromTopologyOwner :: BS.ByteString -> IO ()
deleteFromTopologyOwner key =
  bracket createTestClusterClient closeClusterClient $ \client -> do
    owner <- topologyOwnerForKey client key
    deleteFromNode owner [key]

topologyOwnerForKey :: ClusterClient PlainTextClient -> BS.ByteString -> IO ClusterNode
topologyOwnerForKey client key = do
  topology <- readTVarIO (clusterTopology client)
  let slot = calculateSlot key
  case findNodeAddressForSlot topology slot of
    Nothing ->
      expectationFailure ("No topology owner for slot " ++ show slot)
        >> error "unreachable"
    Just address ->
      case find (\node -> nodeAddress node == address && nodeRole node == Master)
        (Map.elems $ topologyNodes topology) of
        Just owner -> pure owner
        Nothing ->
          expectationFailure
            ("Topology address " ++ show address ++ " has no matching master")
            >> error "unreachable"

replicaForMaster :: ClusterTopology -> ClusterNode -> IO ClusterNode
replicaForMaster topology master =
  case nodeReplicas master of
    replicaId:_ ->
      case Map.lookup replicaId (topologyNodes topology) of
        Just replica -> pure replica
        Nothing ->
          expectationFailure "Master replica is absent from the topology"
            >> error "unreachable"
    [] ->
      expectationFailure "Fixture must provide a replica for every master"
        >> error "unreachable"

waitForMoved :: ClusterNode -> BS.ByteString -> IO ()
waitForMoved previousOwner key = go (50 :: Int)
  where
    go 0 =
      expectationFailure "Previous owner never returned a live MOVED response"
        >> error "unreachable"
    go attempts = do
      response <- runRawOnNode previousOwner ["GET", key]
      case response of
        RespError message
          | "MOVED " `BS8.isPrefixOf` message -> pure ()
        _ -> do
          threadDelay 200000
          go (attempts - 1)

waitForTopologyOwner ::
  ClusterClient PlainTextClient ->
  BS.ByteString ->
  NodeAddress ->
  IO ClusterNode
waitForTopologyOwner client key previousAddress = go (50 :: Int)
  where
    go 0 =
      expectationFailure "Refreshed topology retained the previous slot owner"
        >> error "unreachable"
    go attempts = do
      refreshTopology client
      owner <- topologyOwnerForKey client key
      if nodeAddress owner /= previousAddress
        then pure owner
        else do
          threadDelay 200000
          go (attempts - 1)

assertExactLocalError :: RespData -> BS.ByteString -> Expectation
assertExactLocalError response expected =
  response `shouldBe` RespError ("ERR " <> expected)

isNonEmptyArray :: RespData -> Bool
isNonEmptyArray (RespArray values) = not $ null values
isNonEmptyArray _                  = False
