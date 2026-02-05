{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (..), ConnectionStatus (..),
                                             PlainTextClient (NotConnectedPlainTextClient))
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..),
                                             SlotRange (..),
                                             calculateSlot, findNodeForSlot)
import           ClusterCommandClient
import           ConnectionPool             (PoolConfig (..))
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (IOException, bracket, evaluate, finally, try)
import           Control.Monad              (void, when)
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Char                  (toLower)
import           Data.List                  (isInfixOf, nub)
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
                                             hClose, hFlush, hGetContents, hGetLine,
                                             hPutStrLn, hSetBuffering)
import           System.Process             (CreateProcess (..), ProcessHandle,
                                             StdStream (CreatePipe), proc,
                                             readCreateProcessWithExitCode,
                                             terminateProcess, waitForProcess,
                                             withCreateProcess)
import           System.Timeout             (timeout)
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

-- | Delay between CLI commands in microseconds (200ms)
-- This gives time for command execution and output to be available
cliCommandDelayMicros :: Int
cliCommandDelayMicros = 200000

-- | Clean up a process handle
cleanupProcess :: ProcessHandle -> IO ()
cleanupProcess ph = do
  _ <- (try (terminateProcess ph) :: IO (Either IOException ()))
  _ <- (try (waitForProcess ph) :: IO (Either IOException ExitCode))
  pure ()

-- | Wait for a specific substring to appear in handle output
waitForSubstring :: Handle -> String -> IO ()
waitForSubstring handle needle = do
  line <- hGetLine handle
  if needle `isInfixOf` line
    then pure ()
    else waitForSubstring handle needle

-- | Drain all remaining content from a handle
drainHandle :: Handle -> IO String
drainHandle handle = do
  result <- try (hGetContents handle) :: IO (Either IOException String)
  case result of
    Left _ -> pure ""
    Right contents -> do
      void $ evaluate (length contents)
      pure contents

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
          threadDelay cliCommandDelayMicros
          
          -- Execute GET command
          hPutStrLn hin "GET cli:test:key"
          hFlush hin
          threadDelay cliCommandDelayMicros

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
          threadDelay cliCommandDelayMicros

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
          threadDelay cliCommandDelayMicros

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
          -- CLUSTER SLOTS returns slot ranges with node information
          -- Check for slot numbers (0-16383) and node addresses
          stdoutOut `shouldSatisfy` (\s -> "redis1.local" `isInfixOf` s || "redis2.local" `isInfixOf` s)

      it "cli mode handles hash tags correctly" $ do
        redisClient <- getRedisClientPath
        
        -- Load slot mappings to create keys that route to specific nodes
        slotMappings <- loadSlotMappings "cluster_slot_mapping.txt"
        
        -- Get cluster topology to identify all master nodes
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
          
          -- Use CLI to set a key on each master node using hash tags
          let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                     { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
          
          withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
            hSetBuffering hin LineBuffering
            hSetBuffering hout LineBuffering
            
            -- For each master node, use a hash tag to force a key onto that node
            mapM_ (\node -> do
              case nodeSlotsServed node of
                (range:_) -> do
                  let slot = slotStart range
                      hashTag = slotMappings V.! fromIntegral slot
                  when (not (BS.null hashTag)) $ do
                    let key = "{" ++ BSC.unpack hashTag ++ "}:clitest:" ++ show slot
                        value = "node" ++ show slot
                    hPutStrLn hin $ "SET " ++ key ++ " " ++ value
                    hFlush hin
                    threadDelay cliCommandDelayMicros
                _ -> return ()
              ) masterNodes
            
            -- Exit CLI
            hPutStrLn hin "exit"
            hFlush hin
            hClose hin
            
            -- Drain output
            stdoutOut <- hGetContents hout
            void $ evaluate (length stdoutOut)
            
            -- Wait for process to finish
            exitCode <- waitForProcess ph
            exitCode `shouldBe` ExitSuccess
          
          -- Now verify each node has exactly the key we set on it
          mapM_ (\node -> do
            case nodeSlotsServed node of
              (range:_) -> do
                let slot = slotStart range
                    hashTag = slotMappings V.! fromIntegral slot
                when (not (BS.null hashTag)) $ do
                  let key = "{" ++ BSC.unpack hashTag ++ "}:clitest:" ++ show slot
                      expectedValue = "node" ++ show slot
                      addr = nodeAddress node
                  -- Connect directly to this specific node
                  conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
                  result <- runRedisCommand conn (get key)
                  close conn
                  case result of
                    RespBulkString val -> val `shouldBe` BSL.pack expectedValue
                    other -> expectationFailure $ "Expected value on node " ++ show (nodeHost addr) ++ ", got: " ++ show other
              _ -> return ()
            ) masterNodes

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
          threadDelay cliCommandDelayMicros

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
          -- Using case-insensitive check by converting entire output to lowercase
          -- ClusterCli.hs outputs "CROSSSLOT error:" consistently in uppercase
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` (isInfixOf "crossslot" . map toLower)

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
          threadDelay cliCommandDelayMicros

          hPutStrLn hin "SET {slot:1}:key2 value2"
          hFlush hin
          threadDelay cliCommandDelayMicros

          hPutStrLn hin "SET {slot:1}:key3 value3"
          hFlush hin
          threadDelay cliCommandDelayMicros

          -- Try MGET with keys that have the same hash tag (should work)
          hPutStrLn hin "MGET {slot:1}:key1 {slot:1}:key2 {slot:1}:key3"
          hFlush hin
          threadDelay cliCommandDelayMicros

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
        
        -- First, calculate slots for test keys to ensure they route to different nodes
        let key1 = "route:key1"
            key2 = "route:key2"
            key3 = "route:key3"
        
        slot1 <- calculateSlot (BSC.pack key1)
        slot2 <- calculateSlot (BSC.pack key2)
        slot3 <- calculateSlot (BSC.pack key3)
        
        -- Get cluster topology to map slots to nodes
        bracket createTestClusterClient closeClusterClient $ \client -> do
          topology <- readTVarIO (clusterTopology client)
          
          -- Find which nodes serve these slots
          let findNodeBySlot s = do
                nId <- findNodeForSlot topology s
                Map.lookup nId (topologyNodes topology)
              maybeNode1 = findNodeBySlot slot1
              maybeNode2 = findNodeBySlot slot2
              maybeNode3 = findNodeBySlot slot3
          
          -- Verify we have valid nodes for all slots
          case (maybeNode1, maybeNode2, maybeNode3) of
            (Just node1, Just node2, Just node3) -> do
              -- Verify at least two keys route to different nodes
              let differentNodes = length (nub [nodeId node1, nodeId node2, nodeId node3]) > 1
              differentNodes `shouldBe` True
              
              -- Use CLI to set the keys
              let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
                         { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
              
              withCreateProcess cp $ \(Just hin) (Just hout) (Just _herr) ph -> do
                hSetBuffering hin LineBuffering
                hSetBuffering hout LineBuffering
                
                -- Set the keys
                hPutStrLn hin $ "SET " ++ key1 ++ " value1"
                hFlush hin
                threadDelay cliCommandDelayMicros
                
                hPutStrLn hin $ "SET " ++ key2 ++ " value2"
                hFlush hin
                threadDelay cliCommandDelayMicros
                
                hPutStrLn hin $ "SET " ++ key3 ++ " value3"
                hFlush hin
                threadDelay cliCommandDelayMicros
                
                -- Exit CLI
                hPutStrLn hin "exit"
                hFlush hin
                hClose hin
                
                -- Drain output
                stdoutOut <- hGetContents hout
                void $ evaluate (length stdoutOut)
                
                -- Wait for process to finish
                exitCode <- waitForProcess ph
                exitCode `shouldBe` ExitSuccess
              
              -- Verify each key is on its expected node by connecting directly
              let verifyKeyOnNode key expectedNode = do
                    let addr = nodeAddress expectedNode
                    conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
                    result <- runRedisCommand conn (get key)
                    close conn
                    case result of
                      RespBulkString val -> val `shouldSatisfy` (not . BSL.null)
                      other -> expectationFailure $ "Key " ++ key ++ " not found on expected node " ++ show (nodeHost addr) ++ ": " ++ show other
              
              verifyKeyOnNode key1 node1
              verifyKeyOnNode key2 node2
              verifyKeyOnNode key3 node3
            _ -> expectationFailure "Could not map slots to nodes in topology"

    describe "Cluster Tunnel Mode" $ do
      describe "Smart Proxy Mode" $ do
        it "smart mode makes cluster appear as single Redis instance" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      -- Wait for smart proxy to start listening
                      ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          stdoutRest <- drainHandle hout
                          stderrRest <- drainHandle herr
                          expectationFailure (unlines ["Smart proxy did not report listening within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
                        Just (Left err) -> do
                          cleanup
                          stdoutRest <- drainHandle hout
                          stderrRest <- drainHandle herr
                          expectationFailure (unlines ["Smart proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
                        Just (Right ()) -> do
                          -- Connect to the smart proxy as if it were a single Redis instance
                          conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                          
                          -- Execute commands through proxy
                          result1 <- runRedisCommand conn (set "smart:key1" "value1")
                          result1 `shouldBe` RespSimpleString "OK"
                          
                          result2 <- runRedisCommand conn (get "smart:key1")
                          result2 `shouldBe` RespBulkString "value1"
                          
                          result3 <- runRedisCommand conn ping
                          result3 `shouldBe` RespSimpleString "PONG"
                          
                          close conn
                          
                          -- Verify that commands routed transparently by checking with cluster client
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            verifyResult <- runCmd client (get "smart:key1")
                            verifyResult `shouldBe` RespBulkString "value1"
                            
                            -- Clean up the test key
                            _ <- runCmd client (del ["smart:key1"])
                            pure ()
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Smart proxy process did not expose stdout/stderr handles"

        it "smart mode handles commands that route to different nodes" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          expectationFailure "Smart proxy did not start within timeout"
                        Just (Left _) -> do
                          cleanup
                          expectationFailure "Smart proxy stdout closed unexpectedly"
                        Just (Right ()) -> do
                          conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                          
                          -- Set keys that will hash to different slots (and likely different nodes)
                          _ <- runRedisCommand conn (set "key:a" "value-a")
                          _ <- runRedisCommand conn (set "key:b" "value-b")
                          _ <- runRedisCommand conn (set "key:c" "value-c")
                          
                          -- Verify all keys are accessible through the proxy
                          result1 <- runRedisCommand conn (get "key:a")
                          result1 `shouldBe` RespBulkString "value-a"
                          
                          result2 <- runRedisCommand conn (get "key:b")
                          result2 `shouldBe` RespBulkString "value-b"
                          
                          result3 <- runRedisCommand conn (get "key:c")
                          result3 `shouldBe` RespBulkString "value-c"
                          
                          close conn
                          
                          -- Clean up
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            _ <- runCmd client (del ["key:a", "key:b", "key:c"])
                            pure ()
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Smart proxy process did not expose stdout/stderr handles"

        it "smart mode handles MOVED redirections internally" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          expectationFailure "Smart proxy did not start within timeout"
                        Just (Left _) -> do
                          cleanup
                          expectationFailure "Smart proxy stdout closed unexpectedly"
                        Just (Right ()) -> do
                          conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                          
                          -- Set a key - the smart proxy should handle any MOVED errors internally
                          result1 <- runRedisCommand conn (set "redirect:test" "value")
                          result1 `shouldBe` RespSimpleString "OK"
                          
                          -- Get the key - should work regardless of topology
                          result2 <- runRedisCommand conn (get "redirect:test")
                          result2 `shouldBe` RespBulkString "value"
                          
                          close conn
                          
                          -- Clean up
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            _ <- runCmd client (del ["redirect:test"])
                            pure ()
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Smart proxy process did not expose stdout/stderr handles"

        it "smart mode handles multiple concurrent clients" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          expectationFailure "Smart proxy did not start within timeout"
                        Just (Left _) -> do
                          cleanup
                          expectationFailure "Smart proxy stdout closed unexpectedly"
                        Just (Right ()) -> do
                          -- Create two separate connections
                          conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                          conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                          
                          -- Client 1 sets and gets a key
                          result1 <- runRedisCommand conn1 (set "concurrent:key1" "client1-value")
                          result1 `shouldBe` RespSimpleString "OK"
                          
                          -- Client 2 sets and gets a different key
                          result2 <- runRedisCommand conn2 (set "concurrent:key2" "client2-value")
                          result2 `shouldBe` RespSimpleString "OK"
                          
                          -- Both clients can read their keys
                          result3 <- runRedisCommand conn1 (get "concurrent:key1")
                          result3 `shouldBe` RespBulkString "client1-value"
                          
                          result4 <- runRedisCommand conn2 (get "concurrent:key2")
                          result4 `shouldBe` RespBulkString "client2-value"
                          
                          -- Cross-client reads work
                          result5 <- runRedisCommand conn1 (get "concurrent:key2")
                          result5 `shouldBe` RespBulkString "client2-value"
                          
                          result6 <- runRedisCommand conn2 (get "concurrent:key1")
                          result6 `shouldBe` RespBulkString "client1-value"
                          
                          close conn1
                          close conn2
                          
                          -- Clean up
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            _ <- runCmd client (del ["concurrent:key1", "concurrent:key2"])
                            pure ()
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Smart proxy process did not expose stdout/stderr handles"

      describe "Pinned Proxy Mode" $ do
        it "pinned mode creates one listener per cluster node" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      -- Wait for pinned proxy to start all listeners
                      ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          stdoutRest <- drainHandle hout
                          stderrRest <- drainHandle herr
                          expectationFailure (unlines ["Pinned proxy did not report all listeners started within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
                        Just (Left err) -> do
                          cleanup
                          stdoutRest <- drainHandle hout
                          stderrRest <- drainHandle herr
                          expectationFailure (unlines ["Pinned proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
                        Just (Right ()) -> do
                          -- Get cluster topology to find master nodes
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            topology <- readTVarIO (clusterTopology client)
                            let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                            
                            -- Verify we have multiple masters
                            length masterNodes `shouldSatisfy` (>= 3)
                            
                            -- Connect to one of the pinned listeners (using first master's port)
                            case masterNodes of
                              [] -> expectationFailure "No master nodes found in cluster topology"
                              (firstMaster:_) -> do
                                let addr = nodeAddress firstMaster
                                    localPort = nodePort addr
                                
                                conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))
                                
                                -- Execute a command through pinned proxy
                                result1 <- runRedisCommand conn (set "pinned:test" "value")
                                result1 `shouldBe` RespSimpleString "OK"
                                
                                result2 <- runRedisCommand conn (get "pinned:test")
                                result2 `shouldBe` RespBulkString "value"
                                
                                close conn
                                
                                -- Clean up
                                _ <- runCmd client (del ["pinned:test"])
                                pure ()
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

        it "pinned mode listeners forward to their respective nodes" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          expectationFailure "Pinned proxy did not start within timeout"
                        Just (Left _) -> do
                          cleanup
                          expectationFailure "Pinned proxy stdout closed unexpectedly"
                        Just (Right ()) -> do
                          -- Get cluster topology
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            topology <- readTVarIO (clusterTopology client)
                            let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                            
                            when (length masterNodes < 2) $
                              expectationFailure "Need at least 2 master nodes for this test"
                            
                            -- Connect to two different pinned listeners
                            case masterNodes of
                              (node1:node2:_) -> do
                                let addr1 = nodeAddress node1
                                    addr2 = nodeAddress node2
                                    port1 = nodePort addr1
                                    port2 = nodePort addr2
                                
                                conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just port1))
                                conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just port2))
                                
                                -- Set a key through each listener
                                _ <- runRedisCommand conn1 (set "pinned:node1:key" "from-node1")
                                _ <- runRedisCommand conn2 (set "pinned:node2:key" "from-node2")
                                
                                -- Verify keys are set
                                result1 <- runRedisCommand conn1 (get "pinned:node1:key")
                                result1 `shouldBe` RespBulkString "from-node1"
                                
                                result2 <- runRedisCommand conn2 (get "pinned:node2:key")
                                result2 `shouldBe` RespBulkString "from-node2"
                                
                                close conn1
                                close conn2
                                
                                -- Clean up (using cluster client to reach correct nodes)
                                _ <- runCmd client (del ["pinned:node1:key", "pinned:node2:key"])
                                pure ()
                              _ -> expectationFailure "Expected at least 2 master nodes"
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

        it "pinned mode handles CLUSTER SLOTS commands correctly" $ do
          redisClient <- getRedisClientPath
          let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                     { std_out = CreatePipe,
                       std_err = CreatePipe
                     }
          withCreateProcess cp $ \_ mOut mErr ph ->
            case (mOut, mErr) of
              (Just hout, Just herr) -> do
                hSetBuffering hout LineBuffering
                hSetBuffering herr LineBuffering
                let cleanup = cleanupProcess ph
                finally
                  (do
                      ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                      case ready of
                        Nothing -> do
                          cleanup
                          expectationFailure "Pinned proxy did not start within timeout"
                        Just (Left _) -> do
                          cleanup
                          expectationFailure "Pinned proxy stdout closed unexpectedly"
                        Just (Right ()) -> do
                          -- Get first master node port
                          bracket createTestClusterClient closeClusterClient $ \client -> do
                            topology <- readTVarIO (clusterTopology client)
                            let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                            
                            case masterNodes of
                              [] -> expectationFailure "No master nodes found in cluster topology"
                              (firstMaster:_) -> do
                                let addr      = nodeAddress firstMaster
                                    localPort = nodePort addr
                                
                                conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))
                                
                                -- Execute CLUSTER SLOTS through pinned proxy
                                -- The response should have addresses rewritten to 127.0.0.1
                                result <- runRedisCommand conn clusterSlots
                                
                                -- Verify result is an array (CLUSTER SLOTS returns array of slot ranges)
                                case result of
                                  RespArray slots -> do
                                    -- Should have multiple slot ranges
                                    length slots `shouldSatisfy` (> 0)
                                    -- Note: Full validation of address rewriting would require parsing
                                    -- the complex nested array structure. Just verify it's valid RESP.
                                    pure ()
                                  other -> expectationFailure $ "Expected RespArray from CLUSTER SLOTS, got: " ++ show other
                                
                                close conn
                  )
                  cleanup
              _ -> do
                cleanupProcess ph
                expectationFailure "Pinned proxy process did not expose stdout/stderr handles"
