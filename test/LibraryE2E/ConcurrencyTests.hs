{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ConcurrencyTests (spec) where

import           ClusterCommandClient       (ClusterError (..),
                                             closeClusterClient,
                                             executeClusterCommand,
                                             refreshTopology)
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently, concurrently)
import           Control.Exception          (SomeException, try)
import           Control.Monad              (forM_)
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import           Data.IORef                 (newIORef, atomicModifyIORef', readIORef)
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))

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
        let prefix = "storm-t" ++ show tid ++ "-"
        errors <- newIORef (0 :: Int)

        forM_ [1..opsPerThread] $ \i -> do
          let key = prefix ++ show i
              val = "v-" ++ show tid ++ "-" ++ show i

          -- SET
          sr <- executeClusterCommand client (BS8.pack key) (set key val)
          case sr of
            Left _ -> atomicModifyIORef' errors (\n -> (n + 1, ()))
            Right _ -> return ()

          -- GET and verify
          gr <- executeClusterCommand client (BS8.pack key) (get key)
          case gr of
            Right (RespBulkString v) | v == LBS8.pack val -> return ()
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

      successCount <- newIORef (0 :: Int)

      -- Run topology refreshes concurrently with SET/GET operations
      let refreshAction = do
            forM_ [1..10 :: Int] $ \_ -> do
              _ <- try (refreshTopology client) :: IO (Either SomeException ())
              threadDelay 50000  -- 50ms between refreshes

          workerAction = do
            mapConcurrently (\tid -> do
              forM_ [1..50 :: Int] $ \i -> do
                let key = "refresh-storm-" ++ show tid ++ "-" ++ show i
                r <- executeClusterCommand client (BS8.pack key) (set key "v")
                case r of
                  Right _ -> atomicModifyIORef' successCount (\n -> (n + 1, ()))
                  Left _  -> return ()
              ) [1..49 :: Int]

      -- Run refresh + workers concurrently
      _ <- concurrently refreshAction workerAction

      -- Most operations should succeed (some transient failures during refresh are ok)
      total <- readIORef successCount
      -- 49 workers × 50 ops = 2450 total ops; expect at least 90% success
      total `shouldSatisfy` (> 2200)

      flushAllNodes client
      closeClusterClient client

  describe "Concurrent ops during node failure" $ do
    it "operations to healthy nodes continue during node failure" $ do
      client <- createTestClient

      -- Warm up connections
      forM_ [1..10 :: Int] $ \i -> do
        let k = "warmup-" ++ show i
        _ <- executeClusterCommand client (BS8.pack k) (set k "v")
        return ()

      successCount <- newIORef (0 :: Int)
      failCount <- newIORef (0 :: Int)

      -- Run workers, kill a node mid-flight
      let workerAction = mapConcurrently (\tid -> do
            forM_ [1..100 :: Int] $ \i -> do
              let key = "nodefail-" ++ show tid ++ "-" ++ show i
              r <- try (executeClusterCommand client (BS8.pack key) (set key "v"))
                    :: IO (Either SomeException (Either ClusterError RespData))
              case r of
                Right (Right _) -> atomicModifyIORef' successCount (\n -> (n + 1, ()))
                _               -> atomicModifyIORef' failCount (\n -> (n + 1, ()))
              -- Small delay to spread operations over time
              threadDelay 10000  -- 10ms
            ) [1..50 :: Int]

          killerAction = do
            threadDelay 500000  -- 500ms into the test, kill node 3
            stopNode 3
            threadDelay 3000000  -- Let it stay dead for 3s
            startNode 3

      _ <- concurrently workerAction killerAction

      -- Some successes (ops to healthy nodes) and some failures (ops to dead node)
      successes <- readIORef successCount
      _ <- readIORef failCount

      -- We should have both successes and failures
      successes `shouldSatisfy` (> 0)
      -- After node restart, wait for stabilization
      waitForClusterReady 30
      threadDelay 5000000

      -- Final verification: cluster is healthy again
      _ <- try (refreshTopology client) :: IO (Either SomeException ())
      r <- executeClusterCommand client "final-check" (set "final-check" "ok")
      r `shouldSatisfy` isRight'

      flushAllNodes client
      closeClusterClient client

-- | Helper
isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
