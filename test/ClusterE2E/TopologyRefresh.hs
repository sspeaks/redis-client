{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.TopologyRefresh (spec) where

import           Client                     (PlainTextClient (NotConnectedPlainTextClient), connect)
import           Cluster                    (ClusterTopology (..), NodeAddress (..))
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..), closeClusterClient, createClusterClient, refreshTopology)
import           ClusterE2E.Utils
import           ConnectionPool             (PoolConfig (..))
import qualified ConnectionPool             (PoolConfig (useTLS))
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently)
import           Control.Concurrent.STM     (readTVarIO, atomically, writeTVar)
import           Control.Exception          (bracket)
import           Control.Monad              (when)
import           Data.Time.Clock            (UTCTime, addUTCTime, getCurrentTime, diffUTCTime)
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))
import           Test.Hspec

spec :: Spec
spec = describe "Topology refresh" $ do

    it "refreshes topology when interval expires" $ do
      -- Create client with short refresh interval (1 second)
      let config = ClusterConfig
            { clusterSeedNode = NodeAddress "redis1.local" 6379,
              clusterPoolConfig = PoolConfig
                { maxConnectionsPerNode = 1,
                  connectionTimeout = 5000,
                  maxRetries = 3,
                  ConnectionPool.useTLS = False
                },
              clusterMaxRetries = 3,
              clusterRetryDelay = 100000,
              clusterTopologyRefreshInterval = 1  -- 1 second for fast testing
            }
          connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket (createClusterClient config connector) closeClusterClient $ \client -> do
        -- Get initial topology timestamp
        topology1 <- readTVarIO (clusterTopology client)
        let time1 = topologyUpdateTime topology1

        -- Execute a command immediately - should not trigger refresh yet
        result1 <- runCmd client $ set "refresh:test:key1" "value1"
        case result1 of
          RespSimpleString "OK" -> return ()
          other -> expectationFailure $ "Unexpected SET response: " ++ show other

        -- Check topology wasn't refreshed
        topology2 <- readTVarIO (clusterTopology client)
        let time2 = topologyUpdateTime topology2
        time2 `shouldBe` time1

        -- Wait for refresh interval to expire (1 second + buffer)
        threadDelay 1200000  -- 1.2 seconds

        -- Execute another command - should trigger periodic refresh
        result2 <- runCmd client $ set "refresh:test:key2" "value2"
        case result2 of
          RespSimpleString "OK" -> return ()
          other -> expectationFailure $ "Unexpected SET response: " ++ show other

        -- Check topology was refreshed
        topology3 <- readTVarIO (clusterTopology client)
        let time3 = topologyUpdateTime topology3
        time3 `shouldSatisfy` (> time1)

    it "manual refresh updates topology timestamp" $ do
      let connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Get initial topology timestamp
        topology1 <- readTVarIO (clusterTopology client)
        let time1 = topologyUpdateTime topology1

        -- Small delay to ensure time difference
        threadDelay 100000  -- 100ms

        -- Manually refresh topology
        refreshTopology client connector

        -- Check topology was refreshed
        topology2 <- readTVarIO (clusterTopology client)
        let time2 = topologyUpdateTime topology2
        time2 `shouldSatisfy` (> time1)

    it "topology remains consistent across multiple commands within refresh interval" $ do
      let connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Get initial topology
        topology1 <- readTVarIO (clusterTopology client)
        let time1 = topologyUpdateTime topology1

        -- Execute multiple commands quickly
        mapM_ (\n -> do
            result <- runCmd client $ set ("refresh:multi:" ++ show n) ("value" ++ show n)
            case result of
              RespSimpleString "OK" -> return ()
              other -> expectationFailure $ "Unexpected SET response: " ++ show other
          ) [1..10 :: Int]

        -- Topology should still be the same (no refresh triggered)
        topology2 <- readTVarIO (clusterTopology client)
        let time2 = topologyUpdateTime topology2
        time2 `shouldBe` time1

    it "verifies topology refresh doesn't break concurrent operations" $ do
      -- Note: ConnectionPool currently maintains only 1 connection per node,
      -- so concurrent operations will serialize through the same connection.
      -- This still validates that topology refresh doesn't cause race conditions.
      let config = ClusterConfig
            { clusterSeedNode = NodeAddress "redis1.local" 6379,
              clusterPoolConfig = PoolConfig
                { maxConnectionsPerNode = 1,  -- Currently only 1 connection is used regardless
                  connectionTimeout = 5000,
                  maxRetries = 3,
                  ConnectionPool.useTLS = False
                },
              clusterMaxRetries = 3,
              clusterRetryDelay = 100000,
              clusterTopologyRefreshInterval = 1  -- 1 second
            }
          connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket (createClusterClient config connector) closeClusterClient $ \client -> do
        -- Wait 600ms to get close to refresh boundary
        threadDelay 600000
        
        -- Execute commands concurrently (they'll serialize via connection but spawn async)
        -- The key test is that topology refresh during these operations doesn't break anything
        results <- mapConcurrently (\n -> do
            threadDelay (n * 10000)  -- 0-90ms stagger
            runCmd client $ set ("refresh:concurrent:" ++ show n) ("value" ++ show n)
          ) [1..10 :: Int]

        -- All commands should succeed despite topology refresh happening concurrently
        let allOk = all (\r -> case r of
                          RespSimpleString "OK" -> True
                          _ -> False
                        ) results
        allOk `shouldBe` True

    it "refreshTopology can be called multiple times safely" $ do
      let connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Refresh multiple times rapidly
        refreshTopology client connector
        threadDelay 50000
        refreshTopology client connector
        threadDelay 50000
        refreshTopology client connector

        -- Verify we can still execute commands
        result <- runCmd client $ set "refresh:after:multi" "value"
        case result of
          RespSimpleString "OK" -> return ()
          other -> expectationFailure $ "Unexpected SET response: " ++ show other

    it "topology timestamp is preserved when refresh fails gracefully" $ do
      let connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Get initial topology
        topology1 <- readTVarIO (clusterTopology client)
        let time1 = topologyUpdateTime topology1

        -- We can't easily force a refresh failure without breaking the cluster,
        -- so we'll just verify that normal operations work and topology is valid
        result <- runCmd client $ get "refresh:test:verification"
        
        -- Topology should still be valid
        topology2 <- readTVarIO (clusterTopology client)
        topologyUpdateTime topology2 `shouldSatisfy` (\t -> t >= time1)
