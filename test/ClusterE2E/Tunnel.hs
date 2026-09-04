{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module ClusterE2E.Tunnel (spec) where

import           ClusterE2E.Utils
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (bracket)
import           Control.Monad                 (forM_, when)
import qualified Control.Monad.State.Strict    as State
import qualified Data.ByteString.Builder       as Builder
import qualified Data.ByteString.Char8         as BS8
import           Data.List                     (isInfixOf)
import qualified Data.Map.Strict               as Map
import           Database.Redis.Client         (Client (..),
                                                ConnectionStatus (..),
                                                PlainTextClient (NotConnectedPlainTextClient),
                                                close, connect)
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeAddress (..), NodeRole (..))
import           Database.Redis.Cluster.Client (closeClusterClient,
                                                clusterTopology)
import           Database.Redis.Command        (ClientState (..),
                                                RedisCommands (..), parseWith)
import           Database.Redis.Resp           (Encodable (encode),
                                                RespData (..))
import           SlotMappingHelpers            (getKeyForNode)
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

    it "smart mode routes Redis key specifications and rejects invalid requests before dispatch" $
      withSmartProxy $ do
        conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
        let tag = "{tunnel-routing}"
            binaryKey = tag <> ":binary"
            renamedKey = tag <> ":renamed"
            copiedKey = tag <> ":copied"
            zsetOne = tag <> ":zset-one"
            zsetTwo = tag <> ":zset-two"
            stream = tag <> ":stream"

        rawCommand (RespArray [RespBulkString "SET", RespBulkString binaryKey,
          RespBulkString "\NUL\255"]) conn `shouldReturn` RespSimpleString "OK"
        rawCommand (RespArray [RespBulkString "EVAL",
          RespBulkString "return redis.call('GET', KEYS[1])", RespBulkString "1",
          RespBulkString binaryKey]) conn `shouldReturn` RespBulkString "\NUL\255"
        rawCommand (RespArray [RespBulkString "MEMORY", RespBulkString "USAGE",
          RespBulkString binaryKey]) conn `shouldSatisfyResponse` isInteger
        rawCommand (RespArray [RespBulkString "RENAME", RespBulkString binaryKey,
          RespBulkString renamedKey]) conn `shouldReturn` RespSimpleString "OK"
        rawCommand (RespArray [RespBulkString "COPY", RespBulkString renamedKey,
          RespBulkString copiedKey]) conn `shouldReturn` RespInteger 1

        rawCommand (RespArray [RespBulkString "ZADD", RespBulkString zsetOne,
          RespBulkString "1", RespBulkString "one"]) conn `shouldReturn` RespInteger 1
        rawCommand (RespArray [RespBulkString "ZADD", RespBulkString zsetTwo,
          RespBulkString "2", RespBulkString "two"]) conn `shouldReturn` RespInteger 1
        rawCommand (RespArray [RespBulkString "ZUNION", RespBulkString "2",
          RespBulkString zsetOne, RespBulkString zsetTwo]) conn `shouldReturn`
          RespArray [RespBulkString "one", RespBulkString "two"]

        rawCommand (RespArray [RespBulkString "XADD", RespBulkString stream,
          RespBulkString "*", RespBulkString "field", RespBulkString "value"]) conn
          `shouldSatisfyResponse` isBulk
        rawCommand (RespArray [RespBulkString "XREAD", RespBulkString "STREAMS",
          RespBulkString stream, RespBulkString "0"]) conn `shouldSatisfyResponse` isArray
        rawCommand (RespArray [RespBulkString "XINFO", RespBulkString "STREAM",
          RespBulkString stream]) conn `shouldSatisfyResponse` isArray
        rawCommand (RespArray [RespBulkString "MSET", RespBulkString (tag <> ":one"),
          RespBulkString "one", RespBulkString (tag <> ":two"), RespBulkString "two"]) conn
          `shouldReturn` RespSimpleString "OK"
        rawCommand (RespArray [RespBulkString "PFADD", RespBulkString (tag <> ":hll"),
          RespBulkString "one"]) conn `shouldReturn` RespInteger 1
        rawCommand (RespArray [RespBulkString "PFCOUNT", RespBulkString (tag <> ":hll"),
          RespBulkString (tag <> ":hll")]) conn `shouldSatisfyResponse` isInteger
        rawCommand (RespArray [RespBulkString "TOUCH", RespBulkString (tag <> ":one"),
          RespBulkString (tag <> ":two")]) conn `shouldReturn` RespInteger 2
        rawCommand (RespArray [RespBulkString "OBJECT", RespBulkString "ENCODING",
          RespBulkString (tag <> ":one")]) conn `shouldSatisfyResponse` isBulk
        rawCommand (RespArray [RespBulkString "WATCH", RespBulkString (tag <> ":one"),
          RespBulkString (tag <> ":two")]) conn `shouldReturn` RespSimpleString "OK"
        rawCommand (RespArray [RespBulkString "UNWATCH"]) conn `shouldReturn` RespSimpleString "OK"
        rawCommand (RespArray [RespBulkString "ECHO", RespBulkString "argument"]) conn
          `shouldReturn` RespBulkString "argument"

        rawCommand (RespArray [RespBulkString "MODULE.FUTURE", RespBulkString "key"]) conn
          `shouldSatisfyResponse` isErrContaining "unsupported command for cluster routing"
        rawCommand (RespArray [RespBulkString "ZUNION", RespBulkString "2",
          RespBulkString zsetOne]) conn
          `shouldSatisfyResponse` isErrContaining "fewer keys than its key count"
        rawCommand (RespArray [RespBulkString "MGET", RespBulkString "one",
          RespBulkString "two"]) conn
          `shouldSatisfyResponse` isErrContaining "CROSSSLOT Keys in request don't hash to the same slot"
        rawCommand (RespArray [RespBulkString "PFCOUNT", RespBulkString "{first}:hll",
          RespBulkString "{second}:hll"]) conn
          `shouldSatisfyResponse` isErrContaining "CROSSSLOT Keys in request don't hash to the same slot"
        close conn

        bracket createTestClusterClient closeClusterClient $ \client -> do
          _ <- runCmd_ client (del [renamedKey, copiedKey, zsetOne, zsetTwo, stream,
            tag <> ":one", tag <> ":two", tag <> ":hll"])
          pure ()

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
            (firstMaster:_) -> do
              let addr      = nodeAddress firstMaster
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

rawCommand :: RespData -> PlainTextClient 'Connected -> IO RespData
rawCommand command conn =
  State.evalStateT (do
    ClientState client _ <- State.get
    send client (Builder.toLazyByteString $ encode command)
    parseWith (receive client)
  ) (ClientState conn BS8.empty)

shouldSatisfyResponse :: IO RespData -> (RespData -> Bool) -> IO ()
shouldSatisfyResponse response predicate = response >>= (`shouldSatisfy` predicate)

isInteger :: RespData -> Bool
isInteger (RespInteger _) = True
isInteger _               = False

isBulk :: RespData -> Bool
isBulk (RespBulkString _) = True
isBulk _                  = False

isArray :: RespData -> Bool
isArray (RespArray _) = True
isArray _             = False

isErrContaining :: BS8.ByteString -> RespData -> Bool
isErrContaining message (RespError err) = message `BS8.isInfixOf` err
isErrContaining _ _                     = False
