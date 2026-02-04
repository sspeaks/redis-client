{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient (NotConnectedPlainTextClient))
import Cluster (NodeAddress (..))
import ClusterCommandClient
import ConnectionPool (PoolConfig (..))
import Control.Exception (bracket)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.List (isInfixOf)
import Resp (RespData (..))
import RedisCommandClient (RedisCommands (..))
import System.Directory (doesFileExist, findExecutable)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))
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

main :: IO ()
main = do
  redisClient <- getRedisClientPath
  baseEnv <- getEnvironment
  let runRedisClient args input =
        readCreateProcessWithExitCode ((proc redisClient args) {env = Just baseEnv}) input
  
  hspec $ do
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

      describe "Cluster fill mode tests" $ do
        it "fill --data 1 writes data to cluster" $ do
          -- Call redis-client executable to fill cluster (similar to E2E.hs approach)
          (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "localhost", "--data", "1", "--cluster"] ""
          code `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("Filling cluster" `isInfixOf`)
          
          -- Verify some keys were written
          bracket createTestClusterClient closeClusterClient $ \client -> do
            -- Check that dbsize across cluster is non-zero
            result <- runCmd client dbsize
            case result of
              RespInteger n -> n `shouldSatisfy` (> 0)
              _ -> expectationFailure "Expected dbsize to return integer"
