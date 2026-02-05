{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Utils where

import           Client                     (Client (..), ConnectionStatus (..),
                                             PlainTextClient (NotConnectedPlainTextClient))
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..))
import           ClusterCommandClient       (ClusterClient(..), ClusterConfig(..), createClusterClient, runClusterCommandClient, closeClusterClient, ClusterCommandClient)
import           ConnectionPool             (PoolConfig (..))
import qualified ConnectionPool             (PoolConfig(useTLS))
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (IOException, evaluate, try)
import           Control.Monad              (void)
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import           Data.List                  (isInfixOf)
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (ClientState (..),
                                             ClientReplyValues (..),
                                             RedisCommandClient(..),
                                             RedisCommands (..))
import           Resp                       (RespData (..))
import           System.Directory           (doesFileExist, findExecutable)
import           System.Environment         (getExecutablePath)
import           System.Exit                (ExitCode (..))
import           System.FilePath            (takeDirectory, (</>))
import           System.IO                  (Handle, hGetContents, hGetLine)
import           System.Process             (ProcessHandle, terminateProcess, waitForProcess)

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
