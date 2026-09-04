{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ConcurrencyTests (spec) where

import           Control.Concurrent                    (threadDelay)
import           Control.Concurrent.Async              (concurrently,
                                                        mapConcurrently)
import           Control.Exception                     (SomeException, try)
import           Control.Monad                         (forM_)
import           Data.ByteString                       (ByteString)
import           Data.IORef                            (atomicModifyIORef',
                                                        newIORef, readIORef)
import           Database.Redis.Client                 (PlainTextClient)
import           Database.Redis.Cluster.Client         (ClusterClient,
                                                        ClusterError (..),
                                                        closeClusterClient,
                                                        executeKeyedClusterCommand,
                                                        refreshTopology)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..))
import           Database.Redis.Command                (showBS)
import           Database.Redis.Resp                   (RespData (..))
import           System.Timeout                        (timeout)

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "Concurrent Cluster Operations" $ do

  describe "Concurrent SET/GET storm" $ do
    it "50 threads x 100 ops with no cross-thread data corruption" $ do
      client <- createTestClient

      let threadCount = 50 :: Int
          opsPerThread = 100 :: Int

      _ <- newIORef (0 :: Int)

      results <- mapConcurrently (\tid -> do
        let prefix = "storm-t" <> showBS tid <> "-"
        errors <- newIORef (0 :: Int)

        forM_ [1..opsPerThread] $ \i -> do
          let key = prefix <> showBS i
              val = "v-" <> showBS tid <> "-" <> showBS i

          -- SET
          sr <- executeKeyedClusterCommand client key ["SET", key, val]
          case sr of
            Left _  -> atomicModifyIORef' errors (\n -> (n + 1, ()))
            Right _ -> return ()

          -- GET and verify
          gr <- executeKeyedClusterCommand client key ["GET", key]
          case gr of
            Right (RespBulkString v) | v == val -> return ()
            Right (RespBulkString _) ->
              -- Wrong value = cross-thread corruption!
              atomicModifyIORef' errors (\n -> (n + 1, ()))
            _ -> return ()  -- Nil or error, not corruption

        readIORef errors
        ) [1..threadCount]

      -- Sum up corruption errors across all threads
      let totalErrors = sum results
      totalErrors `shouldBe` 0

      flushAllNodes client
      closeClusterClient client

  describe "Concurrent ops during topology refresh" $ do
    it "operations continue while topology is being refreshed" $ do
      client <- createTestClient

      -- Run topology refreshes concurrently with SET/GET operations
      let refreshAction =
            mapM (\_ -> do
              result <- try (refreshTopology client)
                :: IO (Either SomeException ())
              threadDelay 50000  -- 50ms between refreshes
              return result
            ) [1..10 :: Int]

          workerAction =
            mapConcurrently (\tid ->
              mapM (\i -> do
                let key = "refresh-storm-" <> showBS tid <> "-" <> showBS i
                r <- executeKeyedClusterCommand client key ["SET", key, "v"]
                return $ r == Right (RespSimpleString "OK")
              ) [1..50 :: Int]
            ) [1..49 :: Int]

      -- Run refresh + workers concurrently
      (refreshResults, workerResults) <-
        concurrently refreshAction workerAction

      length [() | Right () <- refreshResults] `shouldBe` 10
      length (filter id $ concat workerResults) `shouldBe` 2450

      flushAllNodes client
      closeClusterClient client

  describe "Concurrent ops during node failure" $ do
    it "fails stopped-slot operations while healthy-slot round trips continue" $ do
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 3
      let targetKey = stoppedNodeKey scenario
          healthyKey = healthyNodeKey scenario
          workerCount = maxConnectionsPerNode defaultPoolConfig

      assertRoundTrip client targetKey "target-before"
      assertRoundTrip client healthyKey "healthy-before"

      (stoppedFailure, healthyOutcomes) <- withStoppedNode 3 $
        concurrently
          (runStoppedOperation client targetKey)
          (mapConcurrently
            (const $ runHealthyOperation client healthyKey)
            [1..workerCount :: Int])

      let stoppedFailures = fromEnum stoppedFailure
          healthySuccesses = length $ filter id healthyOutcomes
          unexpected = (1 - stoppedFailures)
            + (workerCount - healthySuccesses)

      stoppedFailures `shouldBe` 1
      healthySuccesses `shouldBe` workerCount
      unexpected `shouldBe` 0
      stoppedFailures `shouldSatisfy` (> 0)
      healthySuccesses `shouldSatisfy` (> 0)

      refreshTopology client
      assertRoundTrip client targetKey "target-after"

      flushAllNodes client
      closeClusterClient client

runStoppedOperation
  :: ClusterClient PlainTextClient
  -> ByteString
  -> IO Bool
runStoppedOperation client targetKey = do
  targetResult <- timeout 10000000 $
    executeKeyedClusterCommand client
      targetKey
      ["SET", targetKey, "target-during"]
  return $ isExpectedOutage targetResult

runHealthyOperation
  :: ClusterClient PlainTextClient
  -> ByteString
  -> IO Bool
runHealthyOperation client healthyKey = do
  result <- timeout 10000000 $ do
    healthySet <- executeKeyedClusterCommand client
      healthyKey
      ["SET", healthyKey, "healthy-during"]
    healthyGet <- executeKeyedClusterCommand client
      healthyKey
      ["GET", healthyKey]
    return (healthySet, healthyGet)
  return $ case result of
    Just (healthySet, healthyGet) ->
      healthySet == Right (RespSimpleString "OK")
        && healthyGet == Right (RespBulkString "healthy-during")
    Nothing ->
      False

isExpectedOutage :: Maybe (Either ClusterError RespData) -> Bool
isExpectedOutage (Just (Left (MaxRetriesExceeded _))) = True
isExpectedOutage _                                    = False

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
