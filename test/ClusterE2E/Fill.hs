{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Fill (spec) where

import           Client                        (PlainTextClient (NotConnectedPlainTextClient),
                                                close, connect)
import           ClusterE2E.Utils
import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.STM        (readTVarIO)
import           Control.Exception             (bracket)
import qualified Data.ByteString.Char8         as BS8
import           Data.List                     (isInfixOf)
import qualified Data.Map.Strict               as Map
import           Database.Redis.Cluster        (ClusterNode (..),
                                                ClusterTopology (..),
                                                NodeAddress (..), NodeRole (..),
                                                SlotRange (..))
import           Database.Redis.Cluster.Client (closeClusterClient,
                                                clusterTopology)
import           Database.Redis.Command        (RedisCommands (..), showBS)
import           Database.Redis.Resp           (RespData (..))
import           SlotMappingHelpers            (getKeyForNode)
import           System.Exit                   (ExitCode (..))
import           System.Process                (proc,
                                                readCreateProcessWithExitCode)
import           Test.Hspec

spec :: Spec
spec = describe "Cluster Fill Mode" $ do
  it "fill --data 1 with --cluster writes keys across cluster" $ do
    redisClient <- getRedisClientPath

    -- Run fill with -f to flush before filling
    (code, stdoutOut, _) <- readCreateProcessWithExitCode
      (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "-f"])
      ""

    code `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("Filling 1GB across cluster" `isInfixOf`)

    -- Verify keys were distributed across cluster
    bracket createTestClusterClient closeClusterClient $ \client -> do
      totalKeys <- countClusterKeys client
      -- With the fixed calculation using bytesPerCommand and remainder logic,
      -- we now fill much more accurately. For 1GB with 512+512 byte entries:
      -- Expected: 1GB / 1024 bytes = 1,048,576 keys
      -- With remainder logic, we should be within 0.1% (at most chunkKilos commands extra)
      totalKeys `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)  -- 1048576 ± 0.1%

  it "fill with --pipeline batch size writes keys across cluster" $ do
    redisClient <- getRedisClientPath
    -- Run fill with -f to flush before filling, custom pipeline size of 4096
    (code, stdoutOut, _) <- readCreateProcessWithExitCode
      (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "--pipeline", "4096", "-f"])
      ""

    code `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("Filling 1GB across cluster" `isInfixOf`)

    -- Verify keys were distributed across cluster
    bracket createTestClusterClient closeClusterClient $ \client -> do
      totalKeys <- countClusterKeys client
      -- Check key count is reasonable for 1GB
      totalKeys `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)

  it "fill with tiny --pipeline batch size (10) works in cluster" $ do
    redisClient <- getRedisClientPath
    (code, stdoutOut, _) <- readCreateProcessWithExitCode
      (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "--pipeline", "10", "-f"])
      ""
    code `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("Filling 1GB across cluster" `isInfixOf`)
    bracket createTestClusterClient closeClusterClient $ \client -> do
      totalKeys <- countClusterKeys client
      totalKeys `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)

  it "fill with huge --pipeline batch size (20000) works in cluster" $ do
    redisClient <- getRedisClientPath
    (code, stdoutOut, _) <- readCreateProcessWithExitCode
      (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "--pipeline", "20000", "-f"])
      ""
    code `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("Filling 1GB across cluster" `isInfixOf`)
    bracket createTestClusterClient closeClusterClient $ \client -> do
      totalKeys <- countClusterKeys client
      totalKeys `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)

  it "fill rejects invalid --pipeline batch size (0) in cluster" $ do
    redisClient <- getRedisClientPath
    (code, _, _) <- readCreateProcessWithExitCode
      (proc redisClient ["fill", "--host", "redis1.local", "--cluster", "--data", "1", "--pipeline", "0", "-f"])
      ""
    code `shouldNotBe` ExitSuccess

  it "fill --flush clears all nodes in cluster" $ do
    redisClient <- getRedisClientPath
    let runRedisClient args = readCreateProcessWithExitCode (proc redisClient args)

    -- First flush the cluster to start with a clean state (previous tests may have left data)
    _ <- runRedisClient ["fill", "--host", "redis1.local", "--cluster", "-f"] ""
    threadDelay 100000

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
                key = getKeyForNode node ("testkey:" ++ show slot)

            result <- runCmd client $ set key ("value" <> showBS slot)
            case result of
              RespSimpleString "OK" -> return ()
              other -> expectationFailure $ "Failed to set key " ++ BS8.unpack key ++ ": " ++ show other

            -- Verify the key was set on the correct node by connecting directly
            let addr = nodeAddress node
            conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
            getResult <- runRedisCommand conn (get key)
            close conn
            case getResult of
              RespBulkString val -> val `shouldBe` ("value" <> showBS slot)
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
    code `shouldBe` ExitSuccess  -- Now exits with success for flush-only
    stdoutOut `shouldSatisfy` ("Flush complete" `isInfixOf`)

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
    stdoutOut `shouldSatisfy` ("with 4 threads/node" `isInfixOf`)

    -- Verify data was filled (approximately 1GB)
    bracket createTestClusterClient closeClusterClient $ \client -> do
      totalKeys <- countClusterKeys client
      -- With remainder logic, expect accurate fill within 0.1%
      totalKeys `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)  -- 1048576 ± 0.1%

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
          _             -> return 0
        ) masterNodes

      -- Each master should have some keys (verifying distribution)
      mapM_ (\keys -> keys `shouldSatisfy` (> 0)) keysPerNode

      -- Total should be approximately 1048576 keys (1GB of data)
      -- With remainder logic, expect accurate fill within 0.1%
      sum keysPerNode `shouldSatisfy` (\n -> n >= 1047528 && n <= 1049624)  -- 1048576 ± 0.1%
