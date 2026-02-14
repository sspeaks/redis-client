{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module ClusterE2E.Tunnel (spec) where

import           ClusterE2E.Utils
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (bracket)
import           Control.Monad                 (forM_, when)
import qualified Data.ByteString.Char8         as BS8
import           Data.List                     (isInfixOf)
import qualified Data.Map.Strict               as Map
import           Database.Redis.Client         (PlainTextClient (NotConnectedPlainTextClient),
                                                close, connect)
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeAddress (..), NodeRole (..))
import           Database.Redis.Cluster.Client (closeClusterClient,
                                                clusterTopology)
import           Database.Redis.Command        (RedisCommands (..))
import           Database.Redis.Resp           (RespData (..))
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
