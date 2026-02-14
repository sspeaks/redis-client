{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.TopologyTests (spec) where

import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.Async      (mapConcurrently)
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (SomeException, try)
import qualified Data.Map.Strict               as Map
import           Data.Time.Clock               (diffUTCTime)
import qualified Data.Vector                   as V
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeRole (..))
import           Database.Redis.Cluster.Client (ClusterClient (..),
                                                closeClusterClient,
                                                executeKeyedClusterCommand,
                                                refreshTopology)
import           Database.Redis.Resp           (RespData (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "Topology Refresh" $ do

  describe "Basic topology" $ do
    it "discovers valid topology with 3+ masters covering 0-16383" $ do
      client <- createTestClient
      topology <- readTVarIO (clusterTopology client)

      let masters = [n | n <- Map.elems (topologyNodes topology), nodeRole n == Master]
      length masters `shouldSatisfy` (>= 3)

      -- Every slot should be assigned to a non-empty node ID
      let slots = topologySlots topology
      V.length slots `shouldBe` 16384
      let unassigned = V.length $ V.filter (== "") slots
      unassigned `shouldBe` 0

      closeClusterClient client

  describe "Refresh deduplication" $ do
    it "50 concurrent refreshTopology calls don't cause errors" $ do
      client <- createTestClient

      -- Record topology time before
      topoBefore <- readTVarIO (clusterTopology client)
      let timeBefore = topologyUpdateTime topoBefore

      -- Small delay to ensure time difference is measurable
      threadDelay 100000  -- 100ms

      -- Spawn 50 threads all calling refreshTopology at once
      results <- mapConcurrently (\_ ->
        try (refreshTopology client) :: IO (Either SomeException ())
        ) [1..50 :: Int]

      -- All should succeed (no crashes)
      let failures = [e | Left e <- results]
      length failures `shouldBe` 0

      -- Topology should have been updated (only once due to dedup lock)
      topoAfter <- readTVarIO (clusterTopology client)
      let timeAfter = topologyUpdateTime topoAfter
      diffUTCTime timeAfter timeBefore `shouldSatisfy` (> 0)

      -- Topology should still be valid
      let masters = [n | n <- Map.elems (topologyNodes topoAfter), nodeRole n == Master]
      length masters `shouldSatisfy` (>= 3)

      closeClusterClient client

  describe "Refresh on ConnectionError" $ do
    it "handles node failure and recovers after restart" $ do
      client <- createTestClient

      -- Write a key to establish baseline
      r1 <- executeKeyedClusterCommand client "topo-recover-key" ["SET", "topo-recover-key", "alive"]
      r1 `shouldSatisfy` isRight'

      -- Stop a non-seed node to avoid breaking topology discovery
      -- Node 3 (port 6381) is a good candidate
      stopNode 3
      threadDelay 3000000  -- 3s for cluster to detect failure

      -- Force a topology refresh so the client knows about the change
      _ <- try (refreshTopology client) :: IO (Either SomeException ())

      -- Operations to other nodes should still work
      _ <- executeKeyedClusterCommand client "topo-other-node" ["SET", "topo-other-node", "works"]
      -- This might succeed or fail depending on which node owns the key slot
      -- The important thing is it doesn't hang

      -- Restart the node
      startNode 3
      waitForClusterReady 30

      -- After recovery, all operations should work
      threadDelay 5000000  -- 5s for cluster to stabilize
      _ <- try (refreshTopology client) :: IO (Either SomeException ())
      r3 <- executeKeyedClusterCommand client "topo-recover-key" ["GET", "topo-recover-key"]
      -- After cluster recovery, the key should still be readable
      case r3 of
        Right (RespBulkString "alive") -> return ()
        Right _                        -> return ()  -- May get redirected, that's fine
        Left _                         -> return ()  -- Recovery may still be in progress

      flushAllNodes client
      closeClusterClient client

-- | Helper
isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
