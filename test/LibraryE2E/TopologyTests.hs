{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.TopologyTests (spec) where

import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.Async      (mapConcurrently)
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (SomeException, try)
import           Data.ByteString               (ByteString)
import qualified Data.Map.Strict               as Map
import           Data.Time.Clock               (diffUTCTime)
import qualified Data.Vector                   as V
import           Database.Redis.Client         (PlainTextClient)
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeRole (..))
import           Database.Redis.Cluster.Client (ClusterClient (..),
                                                ClusterError (..),
                                                closeClusterClient,
                                                executeKeyedClusterCommand,
                                                refreshTopology)
import           Database.Redis.Resp           (RespData (..))
import           System.Timeout                (timeout)

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
    it "keeps healthy slots available and restores the stopped slot" $ do
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 3
      let targetKey = stoppedNodeKey scenario
          healthyKey = healthyNodeKey scenario

      assertRoundTrip client targetKey "target-before"
      assertRoundTrip client healthyKey "healthy-before"

      withStoppedNode 3 $ do
        refreshTopology client
        assertBoundedOutage client targetKey
        assertRoundTrip client healthyKey "healthy-during"

      refreshTopology client
      assertRoundTrip client targetKey "target-after"

      flushAllNodes client
      closeClusterClient client

assertRoundTrip
  :: ClusterClient PlainTextClient
  -> ByteString
  -> ByteString
  -> Expectation
assertRoundTrip client key value = do
  result <- timeout 10000000 $ do
    setResult <- executeKeyedClusterCommand client key ["SET", key, value]
    getResult <- executeKeyedClusterCommand client key ["GET", key]
    return (setResult, getResult)
  case result of
    Nothing ->
      expectationFailure "Key round trip exceeded the 10-second bound"
    Just (setResult, getResult) -> do
      setResult `shouldBe` Right (RespSimpleString "OK")
      getResult `shouldBe` Right (RespBulkString value)

assertBoundedOutage
  :: ClusterClient PlainTextClient
  -> ByteString
  -> Expectation
assertBoundedOutage client key = do
  result <- timeout 10000000 $
    executeKeyedClusterCommand client key ["GET", key]
  case result of
    Nothing ->
      expectationFailure "Stopped-node command exceeded the 10-second bound"
    Just (Left (MaxRetriesExceeded _)) ->
      return ()
    Just other ->
      expectationFailure $ "Expected MaxRetriesExceeded for stopped-node slot, got "
        ++ show other
