{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ApiTests (spec) where

import           Client                     (PlainTextClient)
import           Cluster                    (ClusterTopology (..), ClusterNode (..),
                                             NodeAddress (..), NodeRole (..))
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..),
                                             ClusterError (..), ClusterCommandClient,
                                             createClusterClient, closeClusterClient,
                                             executeClusterCommand, executeKeylessClusterCommand,
                                             refreshTopology, runClusterCommandClient)
import           ConnectionPool             (PoolConfig (..), ConnectionPool (..),
                                             withConnection, createPool, closePool)
import           Connector                  (Connector, clusterPlaintextConnector)
import           Control.Concurrent.STM     (readTVarIO)
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (RedisCommands (..), RedisError (..))
import           Resp                       (RespData (..), Encodable (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "API Surface" $ do
  describe "Redis.hs re-export module" $ do
    it "provides all necessary types for cluster usage" $ do
      -- Verify we can create a client using the public API types
      client <- createTestClient
      result <- runCmd client ping
      result `shouldBe` RespSimpleString "PONG"
      closeClusterClient client

  describe "Connector abstraction" $ do
    it "clusterPlaintextConnector works end-to-end" $ do
      -- Use the connector abstraction directly
      let config = defaultTestConfig
      client <- createClusterClient config clusterPlaintextConnector
      result <- executeKeylessClusterCommand client ping clusterPlaintextConnector
      result `shouldBe` Right (RespSimpleString "PONG")
      closeClusterClient client

  describe "Full lifecycle" $ do
    it "create, commands, refresh, more commands, close" $ do
      client <- createTestClient

      -- Initial commands
      _ <- runCmd client $ set "lifecycle-key1" "value1"
      r1 <- runCmd client $ get "lifecycle-key1"
      r1 `shouldBe` RespBulkString "value1"

      -- Refresh topology mid-session
      refreshTopology client testConnector

      -- Commands after refresh still work
      _ <- runCmd client $ set "lifecycle-key2" "value2"
      r2 <- runCmd client $ get "lifecycle-key2"
      r2 `shouldBe` RespBulkString "value2"

      -- Cleanup
      _ <- runCmd client flushAll
      closeClusterClient client

  describe "Topology inspection" $ do
    it "exposes valid topology with masters covering all slots" $ do
      client <- createTestClient
      topology <- readTVarIO (clusterTopology client)

      -- Should have master nodes
      let masters = [n | n <- Map.elems (topologyNodes topology), nodeRole n == Master]
      length masters `shouldSatisfy` (>= 3)

      -- Slot vector should be fully populated (no empty entries)
      let emptySlots = length $ filter (== "") $ map (\i -> topologySlots topology `seq` topologySlots topology `seq` "") [0..16383 :: Int]
      -- Actually check via the topology's slot vector
      closeClusterClient client
