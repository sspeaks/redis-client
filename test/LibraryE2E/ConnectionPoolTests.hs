{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ConnectionPoolTests (spec) where

import           Control.Concurrent.Async              (mapConcurrently)
import           Control.Exception                     (SomeException,
                                                        fromException, throwIO,
                                                        try)
import           Control.Monad                         (forM_)
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterConfig (..),
                                                        closeClusterClient,
                                                        executeKeyedClusterCommand)
import           Database.Redis.Cluster.ConnectionPool (ConnectionPoolException (..),
                                                        PoolConfig (..),
                                                        closePool,
                                                        withConnection)
import           Database.Redis.Command                (showBS)
import           Database.Redis.Resp                   (RespData (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "ConnectionPool Thread Safety" $ do

  describe "Concurrent checkout/return" $ do
    it "50 threads doing SET/GET without protocol corruption" $ do
      client <- createTestClient
      let threadIds = [1..50 :: Int]
      results <- mapConcurrently (\tid -> do
        let key = "pool-test-" <> showBS tid
            val = "value-" <> showBS tid
        _ <- executeKeyedClusterCommand client key ["SET", key, val]
        r <- executeKeyedClusterCommand client key ["GET", key]
        return (tid, r)
        ) threadIds

      -- Every thread should get its own correct value
      forM_ results $ \(tid, result) -> do
        let expected = "value-" <> showBS tid
        result `shouldBe` Right (RespBulkString expected)

      flushAllNodes client
      closeClusterClient client

  describe "Pool reuse" $ do
    it "sequential commands reuse connections without errors" $ do
      client <- createTestClientWith (\c -> c {
        clusterPoolConfig = (clusterPoolConfig c) { maxConnectionsPerNode = 2 }
      })

      -- Run 20 sequential commands — should reuse the same pool connections
      forM_ [1..20 :: Int] $ \i -> do
        let key = "reuse-test-" <> showBS i
        result <- executeKeyedClusterCommand client key ["SET", key, "v"]
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
        let key = "overflow-" <> showBS tid
            val = "val-" <> showBS tid
        r <- executeKeyedClusterCommand client key ["SET", key, val]
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
      _ <- executeKeyedClusterCommand client "discard-key" ["SET", "discard-key", "before"]

      -- Force an error inside withConnection by throwing in user action
      let pool = clusterConnectionPool client
      _ <- try (withConnection pool seedNode testConnector $ \_ -> do
        throwIO (userError "intentional test error")
        ) :: IO (Either SomeException ())

      -- Subsequent operations should still work (pool creates fresh connection)
      result <- executeKeyedClusterCommand client "discard-key" ["GET", "discard-key"]
      result `shouldBe` Right (RespBulkString "before")

      flushAllNodes client
      closeClusterClient client

  describe "closePool" $ do
    it "is terminal and rejects later checkouts" $ do
      client <- createTestClient

      -- Warm pool
      _ <- executeKeyedClusterCommand client "close-test" ["SET", "close-test", "v"]

      -- Close the pool
      closePool (clusterConnectionPool client)

      result <- try $
        withConnection
          (clusterConnectionPool client)
          seedNode
          testConnector
          (\_ -> return ())
      result `shouldSatisfy` \case
        Left err -> fromException err == Just ConnectionPoolClosed
        Right () -> False

      closeClusterClient client

-- | Helper to check if Either is Right
isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False
