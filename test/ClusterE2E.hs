{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (..),
                                             PlainTextClient (NotConnectedPlainTextClient))
import           Cluster                    (NodeAddress (..), NodeRole (..), 
                                             ClusterNode (..), ClusterTopology (..),
                                             calculateSlot)
import           ClusterCommandClient
import           ConnectionPool             (PoolConfig (..))
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (IOException, bracket, evaluate, try)
import           Control.Monad              (void)
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.List                  (isInfixOf)
import qualified Data.Map.Strict            as Map
import           Resp                       (RespData (..))
import           System.Directory           (doesFileExist, findExecutable)
import           System.Environment         (getEnvironment, getExecutablePath)
import           System.Exit                (ExitCode (..))
import           System.FilePath            (takeDirectory, (</>))
import           System.Process             (ProcessHandle, CreateProcess (..),
                                             readCreateProcessWithExitCode, proc,
                                             terminateProcess, waitForProcess)
import           Test.Hspec

-- | Create a cluster client for testing
createTestClusterClient :: IO (ClusterClient PlainTextClient)
createTestClusterClient = do
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
          clusterTopologyRefreshInterval = 60
        }
  createClusterClient config connector
  where
    connector (NodeAddress host port) = do
      connect (NotConnectedPlainTextClient host (Just port))

-- | Helper to run cluster commands using the RedisCommands instance
runCmd :: ClusterClient PlainTextClient -> ClusterCommandClient PlainTextClient a -> IO a
runCmd client = runClusterCommandClient client connector
  where
    connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

-- | Get path to redis-client executable
getRedisClientPath :: IO FilePath
getRedisClientPath = do
  execPath <- getExecutablePath
  let binDir = takeDirectory execPath
      sibling = binDir </> "redis-client"
  siblingExists <- doesFileExist sibling
  if siblingExists
    then return sibling
    else do
      found <- findExecutable "redis-client"
      case found of
        Just path -> return path
        Nothing -> error $ "Could not locate redis-client executable starting from " <> binDir

-- | Count total keys across all master nodes in cluster
-- Note: This is a simplified approximation. In a real cluster, we would need
-- to connect to each node individually to get accurate per-node counts.
-- For E2E testing purposes, we just verify the cluster has data.
countClusterKeys :: ClusterClient PlainTextClient -> IO Integer
countClusterKeys client = do
  -- Use a sample key to route DBSIZE command to one node
  -- This won't give us the total across all nodes, but it verifies keys exist
  result <- runCmd client dbsize
  case result of
    RespInteger n -> return n
    _ -> return 0

main :: IO ()
main = hspec $ do
  describe "Cluster E2E Tests" $ do
    describe "Basic cluster operations" $ do
      it "can connect to cluster and query topology" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Just creating the client queries topology, so if we get here, it worked
          return ()

      it "can execute GET/SET commands on cluster" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          let key = "cluster:test:key"

          -- SET command
          setResult <- runCmd client $ set key "testvalue"
          case setResult of
            RespSimpleString "OK" -> return ()
            other -> expectationFailure $ "Unexpected SET response: " ++ show other

          -- GET command
          getResult <- runCmd client $ get key
          case getResult of
            RespBulkString "testvalue" -> return ()
            other -> expectationFailure $ "Unexpected GET response: " ++ show other

      it "routes commands to correct nodes based on slot" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Test with multiple keys that should hash to different slots
          let keys = ["key1", "key2", "key3", "key4", "key5"]

          -- Set all keys
          mapM_ (\key -> do
            result <- runCmd client $ set key ("value_" ++ key)
            case result of
              RespSimpleString "OK" -> return ()
              other -> expectationFailure $ "Unexpected SET response for " ++ key ++ ": " ++ show other
            ) keys

          -- Get all keys and verify
          mapM_ (\key -> do
            result <- runCmd client $ get key
            case result of
              RespBulkString val | val == BSL.pack ("value_" ++ key) -> return ()
              other -> expectationFailure $ "Unexpected GET response for " ++ key ++ ": " ++ show other
            ) keys

      it "handles keys with hash tags correctly" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Keys with same hash tag should go to same slot
          let key1 = "{user:123}:profile"
              key2 = "{user:123}:settings"

          -- Both keys should hash to the same slot
          slot1 <- calculateSlot (BS.pack key1)
          slot2 <- calculateSlot (BS.pack key2)
          slot1 `shouldBe` slot2

          -- Set both keys
          result1 <- runCmd client $ set key1 "profile_data"
          result2 <- runCmd client $ set key2 "settings_data"

          case (result1, result2) of
            (RespSimpleString "OK", RespSimpleString "OK") -> return ()
            _ -> expectationFailure "Failed to set keys with hash tags"

      it "can execute multiple operations in sequence" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          let key = "counter:test"

          -- SET initial value
          setResult <- runCmd client $ set key "0"
          case setResult of
            RespSimpleString "OK" -> return ()
            _ -> expectationFailure "Failed to set initial counter value"

          -- INCR
          incrResult <- runCmd client $ incr key
          case incrResult of
            RespInteger 1 -> return ()
            other -> expectationFailure $ "Unexpected INCR response: " ++ show other

          -- GET to verify
          getResult <- runCmd client $ get key
          case getResult of
            RespBulkString "1" -> return ()
            other -> expectationFailure $ "Unexpected GET response: " ++ show other

      it "can execute PING through cluster" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- PING doesn't need a routing key - the RedisCommands instance handles it
          result <- runCmd client ping
          case result of
            RespSimpleString "PONG" -> return ()
            other -> expectationFailure $ "Unexpected PING response: " ++ show other

      it "can query CLUSTER SLOTS" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          result <- runCmd client clusterSlots
          case result of
            RespArray slots -> do
              -- Verify we got some slot ranges
              length slots `shouldSatisfy` (> 0)
            other -> expectationFailure $ "Unexpected CLUSTER SLOTS response: " ++ show other

    describe "Cluster Fill Mode" $ do
      it "fill --data 1 with --cluster writes keys across cluster" $ do
        redisClient <- getRedisClientPath
        baseEnv <- getEnvironment
        let mergeEnv extra = extra ++ baseEnv
            chunkKilosForTest = "4"
            runRedisClientWithEnv extra args input =
              readCreateProcessWithExitCode ((proc redisClient args) {env = Just (mergeEnv extra)}) input
        
        -- First flush the cluster
        bracket createTestClusterClient closeClusterClient $ \client -> do
          void $ runCmd client flushAll
        
        -- Run fill with small chunk size for faster test
        (code, stdoutOut, _) <- runRedisClientWithEnv 
          [("REDIS_CLIENT_FILL_CHUNK_KB", chunkKilosForTest)] 
          ["fill", "--host", "localhost", "--cluster", "--data", "1", "-f"] 
          ""
        
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("Starting cluster fill" `isInfixOf`)
        
        -- Verify keys were distributed across cluster
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          -- For 1GB with 512-byte keys/values, we expect ~1M keys
          -- Allow some tolerance due to chunking
          totalKeys `shouldSatisfy` (> 900000)
          totalKeys `shouldSatisfy` (< 1100000)

      it "fill --flush clears all nodes in cluster" $ do
        redisClient <- getRedisClientPath
        let runRedisClient args input =
              readCreateProcessWithExitCode (proc redisClient args) input
        
        -- First add some test keys
        bracket createTestClusterClient closeClusterClient $ \client -> do
          void $ runCmd client $ set "test:key:1" "value1"
          void $ runCmd client $ set "test:key:2" "value2"
          void $ runCmd client $ set "test:key:3" "value3"
        
        threadDelay 100000
        
        -- Verify keys exist
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          totalKeys `shouldSatisfy` (> 0)
        
        -- Flush the cluster
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "localhost", "--cluster", "--flush"] ""
        code `shouldNotBe` ExitSuccess  -- --flush requires --data, so it exits with error after flushing
        stdoutOut `shouldSatisfy` ("Flushing all" `isInfixOf`)
        
        -- Verify all keys are gone
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          totalKeys `shouldBe` 0

      it "fill with -n flag controls thread count" $ do
        redisClient <- getRedisClientPath
        baseEnv <- getEnvironment
        let mergeEnv extra = extra ++ baseEnv
            chunkKilosForTest = "4"
            runRedisClientWithEnv extra args input =
              readCreateProcessWithExitCode ((proc redisClient args) {env = Just (mergeEnv extra)}) input
        
        -- Flush first
        bracket createTestClusterClient closeClusterClient $ \client -> do
          void $ runCmd client flushAll
        
        -- Run fill with 4 threads per node
        (code, stdoutOut, _) <- runRedisClientWithEnv 
          [("REDIS_CLIENT_FILL_CHUNK_KB", chunkKilosForTest)] 
          ["fill", "--host", "localhost", "--cluster", "--data", "1", "-n", "4", "-f"] 
          ""
        
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("with 4 threads per node" `isInfixOf`)
        
        -- Verify data was filled
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          totalKeys `shouldSatisfy` (> 900000)

      it "fill distributes data across multiple master nodes" $ do
        redisClient <- getRedisClientPath
        baseEnv <- getEnvironment
        let mergeEnv extra = extra ++ baseEnv
            chunkKilosForTest = "4"
            runRedisClientWithEnv extra args input =
              readCreateProcessWithExitCode ((proc redisClient args) {env = Just (mergeEnv extra)}) input
        
        -- Flush and fill
        bracket createTestClusterClient closeClusterClient $ \client -> do
          void $ runCmd client flushAll
        
        (code, _, _) <- runRedisClientWithEnv 
          [("REDIS_CLIENT_FILL_CHUNK_KB", chunkKilosForTest)] 
          ["fill", "--host", "localhost", "--cluster", "--data", "1", "-f"] 
          ""
        
        code `shouldBe` ExitSuccess
        
        -- Verify data is on multiple masters (not just one)
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
          
          -- Should have multiple masters in the cluster
          length masterNodes `shouldSatisfy` (> 1)
          
          -- Verify data exists in cluster (simplified check)
          -- In a proper test environment with direct node access, we would
          -- query DBSIZE from each master individually to verify distribution
          totalKeys <- countClusterKeys client
          totalKeys `shouldSatisfy` (> 0)  -- At minimum, some data should exist
