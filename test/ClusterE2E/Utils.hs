{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Utils
  ( -- * Cluster test helpers
    createTestClusterClient
  , runCmd
  , runRedisCommand
  , countClusterKeys
  , cliCommandDelayMicros
    -- * Tunnel test helpers
  , withSmartProxy
  , withPinnedProxy
    -- * CLI test helpers
  , withCliSession
    -- * Re-exported E2E helpers
  , getRedisClientPath
  , cleanupProcess
  , waitForSubstring
  , drainHandle
  ) where

import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..),
                                                        PlainTextClient (NotConnectedPlainTextClient))
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..))
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterCommandClient,
                                                        ClusterConfig (..),
                                                        createClusterClient,
                                                        runClusterCommandClient)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..))

import           Control.Concurrent                    (threadDelay)
import           Control.Concurrent.STM                (readTVarIO)
import           Control.Exception                     (IOException, evaluate,
                                                        finally, try)
import           Control.Monad                         (void)
import qualified Control.Monad.State                   as State
import qualified Data.ByteString                       as BS
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Command                (ClientState (..),
                                                        RedisCommandClient (..),
                                                        RedisCommands (..))
import           Database.Redis.Resp                   (RespData (..))
import           E2EHelpers                            (cleanupProcess,
                                                        drainHandle,
                                                        getRedisClientPath,
                                                        waitForSubstring)
import           System.Exit                           (ExitCode (..))
import           System.IO                             (BufferMode (..), hClose,
                                                        hFlush, hGetContents,
                                                        hPutStrLn,
                                                        hSetBuffering)
import           System.Process                        (CreateProcess (..),
                                                        StdStream (..), proc,
                                                        waitForProcess,
                                                        withCreateProcess)
import           System.Timeout                        (timeout)
import           Test.Hspec                            (expectationFailure)

-- | Create a cluster client for testing
createTestClusterClient :: IO (ClusterClient PlainTextClient)
createTestClusterClient = do
  let config = ClusterConfig
        { clusterSeedNode = NodeAddress "redis1.local" 6379,
          clusterPoolConfig = PoolConfig
            { maxConnectionsPerNode = 1,
              connectionTimeout = 5000,
              maxRetries = 3,
              useTLS = False
            },
          clusterMaxRetries = 3,
          clusterRetryDelay = 100000,
          clusterTopologyRefreshInterval = 600  -- 10 minutes
        }
  createClusterClient config connector
  where
    connector (NodeAddress host port) = do
      connect (NotConnectedPlainTextClient host (Just port))

-- | Helper to run cluster commands using the RedisCommands instance
runCmd :: ClusterClient PlainTextClient -> ClusterCommandClient PlainTextClient a -> IO a
runCmd client = runClusterCommandClient client

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
      _             -> return 0
    ) masterNodes

  return $ sum sizes

-- | Delay between CLI commands in microseconds (200ms)
cliCommandDelayMicros :: Int
cliCommandDelayMicros = 200000

-- | Run a test action with a smart tunnel proxy. Starts the proxy process,
-- waits for it to be ready, and passes control to the callback.
withSmartProxy :: (IO ()) -> IO ()
withSmartProxy action = do
  redisClient <- getRedisClientPath
  let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
             { std_out = CreatePipe, std_err = CreatePipe }
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
                stdoutRest <- drainHandle hout
                stderrRest <- drainHandle herr
                expectationFailure (unlines ["Smart proxy did not report listening within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
              Just (Left err) -> do
                cleanup
                stdoutRest <- drainHandle hout
                stderrRest <- drainHandle herr
                expectationFailure (unlines ["Smart proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
              Just (Right ()) -> action
          )
          cleanup
      _ -> do
        cleanupProcess ph
        expectationFailure "Smart proxy process did not expose stdout/stderr handles"

-- | Run a test action with a pinned tunnel proxy. Starts the proxy process,
-- waits for all listeners to be ready, and passes control to the callback.
withPinnedProxy :: (IO ()) -> IO ()
withPinnedProxy action = do
  redisClient <- getRedisClientPath
  let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
             { std_out = CreatePipe, std_err = CreatePipe }
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
                stdoutRest <- drainHandle hout
                stderrRest <- drainHandle herr
                expectationFailure (unlines ["Pinned proxy did not report all listeners started within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
              Just (Left err) -> do
                cleanup
                stdoutRest <- drainHandle hout
                stderrRest <- drainHandle herr
                expectationFailure (unlines ["Pinned proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
              Just (Right ()) -> action
          )
          cleanup
      _ -> do
        cleanupProcess ph
        expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

-- | Run a test with a cluster CLI session. Sends the given commands,
-- then exits and returns (exitCode, stdout).
withCliSession :: [String] -> IO (ExitCode, String)
withCliSession commands = do
  redisClient <- getRedisClientPath
  let cp = (proc redisClient ["cli", "--host", "redis1.local", "--cluster"])
             { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  withCreateProcess cp $ \mIn mOut _mErr ph ->
    case (mIn, mOut) of
      (Just hin, Just hout) -> do
        hSetBuffering hin LineBuffering
        hSetBuffering hout LineBuffering
        mapM_ (\cmd -> do
          hPutStrLn hin cmd
          hFlush hin
          threadDelay cliCommandDelayMicros
          ) commands
        hPutStrLn hin "exit"
        hFlush hin
        hClose hin
        stdoutOut <- hGetContents hout
        void $ evaluate (length stdoutOut)
        exitCode <- waitForProcess ph
        return (exitCode, stdoutOut)
      _ -> do
        cleanupProcess ph
        error "CLI process did not expose stdin/stdout handles"
