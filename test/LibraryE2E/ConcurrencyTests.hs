{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}

module LibraryE2E.ConcurrencyTests (spec) where

import           Control.Concurrent                    (threadDelay)
import           Control.Concurrent.Async              (concurrently,
                                                        mapConcurrently)
import           Control.Exception                     (SomeException, try)
import           Control.Monad                         (forM)
import           Data.ByteString                       (ByteString)
import           Data.IORef                            (IORef, newIORef,
                                                        readIORef)
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Client                 (PlainTextClient)
import           Database.Redis.Cluster.Client         (ClusterClient,
                                                        ClusterError,
                                                        closeClusterClient,
                                                        executeKeyedClusterCommand,
                                                        pattern MaxRetriesExceeded,
                                                        refreshTopology)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..))
import           Database.Redis.Command                (showBS)
import           Database.Redis.Resp                   (RespData (..))
import           System.Timeout                        (timeout)

import           LibraryE2E.StormAssertions            (commandFailure,
                                                        recordProgress,
                                                        trySynchronous)
import           LibraryE2E.Utils

import           Test.Hspec

runStormWorker
  :: ClusterClient PlainTextClient
  -> IORef (Map.Map Int String)
  -> Int
  -> Int
  -> IO [String]
runStormWorker client progress opsPerThread tid = do
  let prefix = "storm-t" <> showBS tid <> "-"

  failures <- forM [1..opsPerThread] $ \i -> do
    let key = prefix <> showBS i
        value = "v-" <> showBS tid <> "-" <> showBS i

    recordProgress progress tid "SET" key
    setResult <- trySynchronous $
      executeKeyedClusterCommand client key ["SET", key, value]
    recordProgress progress tid "GET" key
    getResult <- trySynchronous $
      executeKeyedClusterCommand client key ["GET", key]
    pure $
      commandFailure tid "SET" key (Right (RespSimpleString "OK")) setResult
        ++ commandFailure tid "GET" key (Right (RespBulkString value)) getResult
  pure (concat failures)

spec :: Spec
spec = describe "Concurrent Cluster Operations" $ do

  describe "Concurrent SET/GET storm" $ do
    it "50 threads x 100 ops with no cross-thread data corruption" $ do
      client <- createTestClient

      let threadCount = 50 :: Int
          opsPerThread = 100 :: Int
          stormTimeoutMicros = 60 * 1000000

      progress <- newIORef Map.empty
      result <- timeout stormTimeoutMicros $
        mapConcurrently
          (runStormWorker client progress opsPerThread)
          [1..threadCount]
      case result of
        Nothing -> do
          workerProgress <- readIORef progress
          expectationFailure $ unlines
            [ "Concurrent cluster SET/GET storm timed out after 60 seconds."
            , "Last operation for each worker:"
            , unlines (Map.elems workerProgress)
            ]
        Just failures ->
          concat failures `shouldBe` []

      flushAllNodes client
      closeClusterClient client

  describe "Concurrent ops during topology refresh" $ do
    it "operations continue while topology is being refreshed" $ do
      client <- createTestClient

      -- Run topology refreshes concurrently with SET/GET operations
      let refreshAction =
            mapM (\_ -> do
              result <- refreshTopology client
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
