{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (..), ConnectionStatus (..),
                                             PlainTextClient (NotConnectedPlainTextClient))
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..),
                                             SlotRange (..),
                                             calculateSlot)
import           ClusterCommandClient
import           ConnectionPool             (PoolConfig (..))
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (IOException, bracket, evaluate, try)
import           Control.Monad              (void, when)
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.List                  (isInfixOf)
import qualified Data.Map.Strict            as Map
import           Data.Vector                (Vector)
import qualified Data.Vector                as V
import           Data.Word                  (Word16)
import           RedisCommandClient         (ClientState (..),
                                             ClientReplyValues (..),
                                             RedisCommands (..))
import           Resp                       (RespData (..))
import           System.Directory           (doesFileExist, findExecutable)
import           System.Environment         (getEnvironment, getExecutablePath)
import           System.Exit                (ExitCode (..))
import           System.FilePath            (takeDirectory, (</>))
import           System.IO                  (BufferMode (LineBuffering), Handle,
                                             hClose, hFlush, hGetContents,
                                             hPutStrLn, hSetBuffering)
import           System.Process             (ProcessHandle, CreateProcess (..),
                                             StdStream (CreatePipe),
                                             readCreateProcessWithExitCode, proc,
                                             terminateProcess, waitForProcess,
                                             withCreateProcess)
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

-- | Helper to run a RedisCommand against a plain connection
runRedisCommand :: PlainTextClient 'Connected -> RedisCommandClient PlainTextClient a -> IO a
runRedisCommand conn cmd =
  State.evalStateT (case cmd of RedisCommandClient m -> m) (ClientState conn BS.empty)

-- | Count total keys across all master nodes in cluster by querying each master directly
countClusterKeys :: ClusterClient PlainTextClient -> IO Integer
countClusterKeys client = do
  -- Get topology and find all master nodes
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

  -- Query DBSIZE from each master directly and sum the results
  sizes <- mapM (\node -> do
    let addr = nodeAddress node
    conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
    result <- runRedisCommand conn dbsize
    close conn
    case result of
      RespInteger n -> return n
      _ -> return 0
    ) masterNodes

  return $ sum sizes

-- | Load slot mappings from file for creating keys that route to specific slots
loadSlotMappings :: FilePath -> IO (Vector BS.ByteString)
loadSlotMappings filepath = do
  content <- readFile filepath
  let entries = map parseLine $ lines content
      validEntries = [(slot, tag) | Just (slot, tag) <- entries]
      entryMap = Map.fromList validEntries
  -- Create a vector of 16384 slots, empty ByteString for missing entries
  return $ V.generate 16384 (\i -> Map.findWithDefault BS.empty (fromIntegral i) entryMap)
  where
    parseLine :: String -> Maybe (Word16, BS.ByteString)
    parseLine line =
      case words line of
        [slotStr, tag] -> case reads slotStr of
          [(slot, "")] -> Just (slot, BSC.pack tag)
          _            -> Nothing
        _ -> Nothing

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
          slot1 <- calculateSlot (BSC.pack key1)
          slot2 <- calculateSlot (BSC.pack key2)
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

        -- Run fill with -f to flush before filling
        (code, stdoutOut, _) <- readCreateProcessWithExitCode
          (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "-f"])
          ""

        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("Starting cluster fill" `isInfixOf`)

        -- Verify keys were distributed across cluster
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          -- ClusterFiller uses 512-byte keys and 512-byte values (hardcoded in ClusterFiller.hs)
          -- For 1GB: 1GB / (512 + 512 bytes) = 1,048,576 keys exactly
          totalKeys `shouldBe` 1048576

      it "fill --flush clears all nodes in cluster" $ do
        redisClient <- getRedisClientPath
        let runRedisClient args = readCreateProcessWithExitCode (proc redisClient args)

        -- First flush the cluster to start with a clean state (previous tests may have left data)
        _ <- runRedisClient ["fill", "--host", "redis1.local", "--cluster", "-f"] ""
        threadDelay 100000

        -- Load slot mappings to create keys that route to specific nodes
        slotMappings <- loadSlotMappings "cluster_slot_mapping.txt"

        -- Get cluster topology to identify master nodes
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

          -- Create keys that route to different masters using hash tags from slot mapping
          -- For each master, create a key using its first slot's hash tag
          mapM_ (\node -> do
            case nodeSlotsServed node of
              (range:_) -> do
                let slot = slotStart range
                    hashTag = slotMappings V.! fromIntegral slot
                -- Validate hash tag is non-empty
                when (BS.null hashTag) $
                  expectationFailure $ "Empty hash tag for slot " ++ show slot
                let key = "{" ++ BSC.unpack hashTag ++ "}:testkey:" ++ show slot
                result <- runCmd client $ set key ("value" ++ show slot)
                case result of
                  RespSimpleString "OK" -> return ()
                  other -> expectationFailure $ "Failed to set key " ++ key ++ ": " ++ show other

                -- Verify the key was set on the correct node by connecting directly
                let addr = nodeAddress node
                conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
                getResult <- runRedisCommand conn (get key)
                close conn
                case getResult of
                  RespBulkString val -> val `shouldBe` BSL.pack ("value" ++ show slot)
                  other -> expectationFailure $ "Key not found on expected node: " ++ show other
              [] -> return ()  -- Skip nodes with no slots
            ) masterNodes

        threadDelay 100000

        -- Verify keys exist across all nodes
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterCount = length [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
          totalKeys <- countClusterKeys client
          -- We created one key per master node, so should have exactly that many
          totalKeys `shouldBe` fromIntegral masterCount

        -- Flush the cluster using only the -f flag (no --data)
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis1.local", "--cluster", "-f"] ""
        code `shouldNotBe` ExitSuccess  -- Exits with failure when only flushing
        stdoutOut `shouldSatisfy` ("Flushing" `isInfixOf`)

        threadDelay 100000

        -- Verify all keys are gone from all nodes after flush
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          totalKeys `shouldBe` 0

      it "fill with -n flag controls thread count" $ do
        redisClient <- getRedisClientPath

        -- Run fill with 4 threads per node
        (code, stdoutOut, _) <- readCreateProcessWithExitCode
          (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "-n", "4", "-f"])
          ""

        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("with 4 threads per node" `isInfixOf`)

        -- Verify data was filled with exact count
        bracket createTestClusterClient closeClusterClient $ \client -> do
          totalKeys <- countClusterKeys client
          totalKeys `shouldBe` 1048576

      it "fill distributes data across multiple master nodes" $ do
        redisClient <- getRedisClientPath

        -- Fill the cluster
        (code, _, _) <- readCreateProcessWithExitCode
          (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "-f"])
          ""

        code `shouldBe` ExitSuccess

        -- Verify data is distributed across multiple masters
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

          -- Should have multiple masters in the cluster
          length masterNodes `shouldSatisfy` (> 1)

          -- Query DBSIZE from each master directly to verify distribution
          keysPerNode <- mapM (\node -> do
            let addr = nodeAddress node
            conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
            result <- runRedisCommand conn dbsize
            close conn
            case result of
              RespInteger n -> return n
              _ -> return 0
            ) masterNodes

          -- Each master should have some keys (verifying distribution)
          mapM_ (\keys -> keys `shouldSatisfy` (> 0)) keysPerNode

          -- Total should be exactly 1048576 keys
          sum keysPerNode `shouldBe` 1048576

    describe "Cluster CLI Mode" $ do
      it "cli mode can execute GET/SET commands" $ do
        redisClient <- getRedisClientPath

        -- Create process for CLI mode with cluster enabled
        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Execute SET command
          hPutStrLn hin "SET cli:test:key value123"
          hFlush hin
          threadDelay 200000
          
          -- Execute GET command
          hPutStrLn hin "GET cli:test:key"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("value123" `isInfixOf`)

      it "cli mode can execute keyless commands (PING)" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Execute PING command
          hPutStrLn hin "PING"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("PONG" `isInfixOf`)

      it "cli mode can execute CLUSTER SLOTS command" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Execute CLUSTER SLOTS command
          hPutStrLn hin "CLUSTER SLOTS"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify
          exitCode `shouldBe` ExitSuccess
          -- CLUSTER SLOTS returns array of slot ranges
          stdoutOut `shouldSatisfy` ("RespArray" `isInfixOf`)

      it "cli mode handles hash tags correctly" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Set two keys with same hash tag (should go to same slot)
          hPutStrLn hin "SET {user:100}:name alice"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "SET {user:100}:email alice@example.com"
          hFlush hin
          threadDelay 200000

          -- Get both keys
          hPutStrLn hin "GET {user:100}:name"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "GET {user:100}:email"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("alice" `isInfixOf`)
          stdoutOut `shouldSatisfy` ("alice@example.com" `isInfixOf`)

      it "cli mode handles CROSSSLOT errors for multi-key commands" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Try MGET with keys that hash to different slots (should trigger CROSSSLOT error)
          hPutStrLn hin "MGET key1 key2 key3"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify - should contain CROSSSLOT error message
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` (\s -> "CROSSSLOT" `isInfixOf` s || "crossslot" `isInfixOf` s)

      it "cli mode can execute multi-key commands on same slot using hash tags" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Set keys with same hash tag
          hPutStrLn hin "SET {slot:1}:key1 value1"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "SET {slot:1}:key2 value2"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "SET {slot:1}:key3 value3"
          hFlush hin
          threadDelay 200000

          -- Try MGET with keys that have the same hash tag (should work)
          hPutStrLn hin "MGET {slot:1}:key1 {slot:1}:key2 {slot:1}:key3"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("value1" `isInfixOf`)
          stdoutOut `shouldSatisfy` ("value2" `isInfixOf`)
          stdoutOut `shouldSatisfy` ("value3" `isInfixOf`)

      it "cli mode routes commands to correct nodes" $ do
        redisClient <- getRedisClientPath

        let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                   { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }

        withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
          hSetBuffering hin LineBuffering
          hSetBuffering hout LineBuffering

          -- Set multiple keys that should hash to different slots
          hPutStrLn hin "SET route:key1 value1"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "SET route:key2 value2"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "SET route:key3 value3"
          hFlush hin
          threadDelay 200000

          -- Get the keys back
          hPutStrLn hin "GET route:key1"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "GET route:key2"
          hFlush hin
          threadDelay 200000

          hPutStrLn hin "GET route:key3"
          hFlush hin
          threadDelay 200000

          -- Exit CLI
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin

          -- Read output
          stdoutOut <- hGetContents hout
          void $ evaluate (length stdoutOut)

          -- Wait for process to finish
          exitCode <- waitForProcess ph

          -- Verify all values are present
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("value1" `isInfixOf`)
          stdoutOut `shouldSatisfy` ("value2" `isInfixOf`)
          stdoutOut `shouldSatisfy` ("value3" `isInfixOf`)
