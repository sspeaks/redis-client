{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Cli (spec) where

import           Client                     (PlainTextClient (NotConnectedPlainTextClient), connect, close)
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..), SlotRange(..),
                                             calculateSlot, findNodeForSlot)
import           ClusterCommandClient       (closeClusterClient, clusterTopology)
import           ClusterE2E.Utils
import           ClusterSlotMapping         (getKeyForNode)
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (bracket, evaluate)
import           Control.Monad              (void)
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Char                  (toLower)
import           Data.List                  (isInfixOf, nub)
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))
import           System.Exit                (ExitCode (..))
import           System.IO                  (hClose, hFlush, hGetContents, hPutStrLn, hSetBuffering, BufferMode(..))
import           System.Process             (proc, withCreateProcess, waitForProcess, CreateProcess(..), StdStream(..))
import           Test.Hspec

spec :: Spec
spec = describe "Cluster CLI Mode" $ do
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
                  keyBS = getKeyForNode node ("clitest:" ++ show slot)
                  key = BSC.unpack keyBS
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
                keyBS = getKeyForNode node ("clitest:" ++ show slot)
                key = BSC.unpack keyBS
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
