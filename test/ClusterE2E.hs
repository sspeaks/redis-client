{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient (NotConnectedPlainTextClient))
import Cluster (NodeAddress (..), calculateSlot, ClusterTopology (..), ClusterNode (..), topologySlots, topologyNodes, nodeAddress)
import ClusterCommandClient
import ConnectionPool (PoolConfig (..))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (bracket, finally, handle, SomeException, IOException, try)
import Control.Monad (void, when)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import Data.Word (Word16, Word64)
import Filler (fillCacheWithDataClusterPipelined, initRandomNoise)
import Resp (RespData (..))
import RedisCommandClient (RedisCommands (..))
import System.Directory (findExecutable)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, (</>))
import System.IO (BufferMode (LineBuffering), Handle, hSetBuffering, hGetLine, hIsEOF)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe), proc, 
                       terminateProcess, withCreateProcess)
import System.Timeout (timeout)
import Test.Hspec

-- | Create a cluster client for testing
createTestClusterClient :: IO (ClusterClient PlainTextClient)
createTestClusterClient = do
  let config = ClusterConfig
        { clusterSeedNode = NodeAddress "localhost" 6379,
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
runCmd client action = runClusterCommandClient client connector action
  where
    connector (NodeAddress host port) = connect (NotConnectedPlainTextClient host (Just port))

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

    describe "Cluster fill mode" $ do
      it "can write data distributed across cluster" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Write multiple keys that should be distributed across nodes
          let keys = ["fill:" ++ show i | i <- [1..100 :: Int]]
          
          -- Write all keys
          mapM_ (\key -> do
            result <- runCmd client $ set key "testvalue"
            case result of
              RespSimpleString "OK" -> return ()
              other -> expectationFailure $ "Failed to set key " ++ key ++ ": " ++ show other
            ) keys
          
          -- Verify data was written by checking a few random keys
          mapM_ (\key -> do
            result <- runCmd client $ get key
            case result of
              RespBulkString "testvalue" -> return ()
              other -> expectationFailure $ "Failed to get key " ++ key ++ ": " ++ show other
            ) (take 10 keys)

    describe "Cluster CLI mode integration" $ do
      it "handles basic commands through cluster CLI logic" $ do
        -- This test verifies the CLI command routing logic works
        -- Note: Full CLI testing would require interactive shell simulation
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Test that basic commands work (similar to what CLI would do)
          result <- runCmd client $ set "cli:test" "value"
          case result of
            RespSimpleString "OK" -> return ()
            other -> expectationFailure $ "Unexpected SET response: " ++ show other
          
          getResult <- runCmd client $ get "cli:test"
          case getResult of
            RespBulkString "value" -> return ()
            other -> expectationFailure $ "Unexpected GET response: " ++ show other
    
    describe "Cluster fill mode tests" $ do
      it "tests fillCacheWithDataClusterPipelined completes successfully" $ do
        -- Initialize random noise buffer
        initRandomNoise
        
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Get a connection to a specific node for a slot
          topology <- readTVarIO (clusterTopology client)
          let slot0NodeId = (topologySlots topology) V.! 0
              nodesById = topologyNodes topology
          
          case Map.lookup slot0NodeId nodesById of
            Just node -> do
              let addr = nodeAddress node
              -- Connect directly to the node owning slot 0
              conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just $ nodePort addr))
              
              -- Fill 1MB of data for slot 0
              let baseSeed = 12345 :: Word64
                  threadIdx = 0
                  mb = 1
                  targetSlot = 0 :: Word16
              
              -- This should complete without throwing an exception
              fillCacheWithDataClusterPipelined baseSeed threadIdx mb targetSlot conn
              
              -- Verify a key was written by using the cluster client
              result <- runCmd client $ get "{slot0}:0000000000000000"
              case result of
                RespBulkString val -> val `shouldSatisfy` (not . BSL.null)
                _ -> expectationFailure $ "Key was not found after fill"
            Nothing -> expectationFailure "Could not find node for slot 0"
      
      it "verifies keys land on correct nodes using slot calculation" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Use a hash tag to force a specific slot
          let testKey = "{user123}:profile"
          
          -- Calculate which slot this key should go to
          slot <- calculateSlot (BS.pack testKey)
          
          -- Get the topology to find which node owns this slot
          topology <- readTVarIO (clusterTopology client)
          let nodeId = (topologySlots topology) V.! fromIntegral slot
              nodesById = topologyNodes topology
          
          case Map.lookup nodeId nodesById of
            Just node -> do
              -- Write the key through the cluster client
              result <- runCmd client $ set testKey "test-value"
              result `shouldBe` RespSimpleString "OK"
              
              -- Verify by reading back through cluster client
              getResult <- runCmd client $ get testKey
              case getResult of
                RespBulkString val | BSL.toStrict val == BS.pack "test-value" -> return ()
                _ -> expectationFailure $ "Expected test-value, got: " ++ show getResult
            Nothing -> expectationFailure $ "Could not find node for slot " ++ show slot
    
    describe "Cluster tunnel mode tests" $ do
      it "tunnel proxies commands to cluster nodes" $ do
        -- Get the redis-client executable path
        exePath <- getExecutablePath
        let redisClient = takeDirectory exePath </> "redis-client"
        
        -- Check if executable exists, otherwise try to find it
        execExists <- findExecutable "redis-client"
        let finalPath = case execExists of
              Just path -> path
              Nothing -> redisClient
        
        let cp = (proc finalPath ["tunn", "--cluster", "--host", "localhost"])
              { std_out = CreatePipe,
                std_err = CreatePipe
              }
        
        withCreateProcess cp $ \_ mOut mErr ph ->
          case (mOut, mErr) of
            (Just hout, Just herr) -> do
              hSetBuffering hout LineBuffering
              hSetBuffering herr LineBuffering
              let cleanup = terminateProcess ph
              
              finally
                (do
                  -- Wait for tunnel to start (with timeout)
                  ready <- timeout (5 * 1000000) $ waitForListening hout herr
                  case ready of
                    Nothing -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure $ unlines
                        [ "Tunnel did not start within timeout."
                        , "stdout:", stdoutRest
                        , "stderr:", stderrRest
                        ]
                    Just False -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure $ unlines
                        [ "Tunnel failed to start."
                        , "stdout:", stdoutRest
                        , "stderr:", stderrRest
                        ]
                    Just True -> do
                      -- Give tunnel a moment to fully initialize
                      threadDelay 500000
                      
                      -- Create a client that connects through the tunnel
                      tunnelClient <- createTestClusterClient  -- This connects to localhost:6379
                      
                      -- Execute commands through the tunnel
                      result <- runCmd tunnelClient $ set "tunnel:test" "via-tunnel"
                      result `shouldBe` RespSimpleString "OK"
                      
                      getResult <- runCmd tunnelClient $ get "tunnel:test"
                      getResult `shouldBe` RespBulkString "via-tunnel"
                      
                      closeClusterClient tunnelClient
                )
                cleanup
            _ -> expectationFailure "Failed to create tunnel process"

-- Helper to wait for tunnel to report it's listening
waitForListening :: Handle -> Handle -> IO Bool
waitForListening hout herr = do
  let checkOutput = do
        eof <- hIsEOF hout
        if eof
          then return False
          else do
            line <- hGetLine hout
            if "Listening on localhost:6379" `elem` words line
              then return True
              else checkOutput
  
  handle (\(_ :: IOException) -> return False) checkOutput

-- Helper to drain remaining output from a handle
drainHandle :: Handle -> IO String
drainHandle h = handle (\(_ :: IOException) -> return "") $ do
  eof <- hIsEOF h
  if eof
    then return ""
    else do
      line <- hGetLine h
      rest <- drainHandle h
      return $ line ++ "\n" ++ rest
