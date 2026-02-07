{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ConnectionPoolTests (spec) where

import           Client                     (Client (..), PlainTextClient,
                                             ConnectionStatus (..))
import           Cluster                    (NodeAddress (..))
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..),
                                             ClusterError (..),
                                             closeClusterClient,
                                             executeClusterCommand)
import           ConnectionPool             (PoolConfig (..), ConnectionPool (..),
                                             withConnection, createPool, closePool)
import qualified ConnectionPool             (PoolConfig (useTLS))
import           Connector                  (Connector, clusterPlaintextConnector)
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently)
import           Control.Exception          (SomeException, try, throwIO, evaluate)
import           Control.Monad              (forM_, void)
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import           Data.IORef                 (newIORef, atomicModifyIORef', readIORef)
import           RedisCommandClient         (ClientState (..),
                                             RedisCommandClient (..),
                                             RedisCommands (..),
                                             runRedisCommandClient)
import           Resp                       (RespData (..), Encodable (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "ConnectionPool Thread Safety" $ do

  describe "Concurrent checkout/return" $ do
    it "50 threads doing SET/GET without protocol corruption" $ do
      client <- createTestClient
      let threadIds = [1..50 :: Int]
      results <- mapConcurrently (\tid -> do
        let key = "pool-test-" ++ show tid
            val = "value-" ++ show tid
        _ <- executeClusterCommand client (BS8.pack key) (set key val) testConnector
        r <- executeClusterCommand client (BS8.pack key) (get key) testConnector
        return (tid, r)
        ) threadIds

      -- Every thread should get its own correct value
      forM_ results $ \(tid, result) -> do
        let expected = "value-" ++ show tid
        result `shouldBe` Right (RespBulkString (LBS8.pack expected))

      flushAllNodes client
      closeClusterClient client

  describe "Pool reuse" $ do
    it "sequential commands reuse connections without errors" $ do
      client <- createTestClientWith (\c -> c {
        clusterPoolConfig = (clusterPoolConfig c) { maxConnectionsPerNode = 2 }
      })

      -- Run 20 sequential commands — should reuse the same pool connections
      forM_ [1..20 :: Int] $ \i -> do
        let key = "reuse-test-" ++ show i
        result <- executeClusterCommand client (BS8.pack key) (set key "v") testConnector
        result `shouldSatisfy` isRight

      flushAllNodes client
      closeClusterClient client

  describe "Overflow behavior" $ do
    it "10 concurrent operations with maxConnectionsPerNode=1 all succeed" $ do
      client <- createTestClientWith (\c -> c {
        clusterPoolConfig = (clusterPoolConfig c) { maxConnectionsPerNode = 1 }
      })

      let threadIds = [1..10 :: Int]
      results <- mapConcurrently (\tid -> do
        let key = "overflow-" ++ show tid
            val = "val-" ++ show tid
        r <- executeClusterCommand client (BS8.pack key) (set key val) testConnector
        return (tid, r)
        ) threadIds

      -- All should succeed despite pool overflow
      forM_ results $ \(_, result) -> do
        result `shouldSatisfy` isRight

      flushAllNodes client
      closeClusterClient client

  describe "Discard on error" $ do
    it "connection is discarded after action throws, subsequent ops work" $ do
      client <- createTestClient

      -- First, do a normal operation to warm the pool
      _ <- executeClusterCommand client "discard-key" (set "discard-key" "before") testConnector

      -- Force an error inside withConnection by throwing in user action
      let pool = clusterConnectionPool client
      _ <- try (withConnection pool seedNode testConnector $ \conn -> do
        throwIO (userError "intentional test error")
        ) :: IO (Either SomeException ())

      -- Subsequent operations should still work (pool creates fresh connection)
      result <- executeClusterCommand client "discard-key" (get "discard-key") testConnector
      result `shouldBe` Right (RespBulkString "before")

      flushAllNodes client
      closeClusterClient client

  describe "closePool" $ do
    it "closes connections and pool remains usable for new connections" $ do
      client <- createTestClient

      -- Warm pool
      _ <- executeClusterCommand client "close-test" (set "close-test" "v") testConnector

      -- Close the pool
      closePool (clusterConnectionPool client)

      -- After close, new operations should still work (pool creates new connections)
      result <- executeClusterCommand client "close-test2" (set "close-test2" "v2") testConnector
      result `shouldSatisfy` isRight

      closeClusterClient client

-- | Helper to check if Either is Right
isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False
