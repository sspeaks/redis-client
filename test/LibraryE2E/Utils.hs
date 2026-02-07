{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.Utils
  ( -- * Client creation
    createTestClient
  , createTestClientWith
  , defaultTestConfig
  , defaultPoolConfig
  , testConnector
    -- * Command helpers
  , runCmd
  , flushAllNodes
    -- * Docker node management
  , stopNode
  , startNode
  , waitForClusterReady
    -- * Constants
  , seedNode
  ) where

import           Client                     (Client (..), ConnectionStatus (..),
                                             PlainTextClient (NotConnectedPlainTextClient))
import           Cluster                    (ClusterTopology (..), ClusterNode (..),
                                             NodeAddress (..), NodeRole (..))
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..),
                                             ClusterCommandClient,
                                             createClusterClient, closeClusterClient,
                                             runClusterCommandClient)
import           ConnectionPool             (PoolConfig (..))
import qualified ConnectionPool             (PoolConfig (useTLS))
import           Connector                  (Connector, clusterPlaintextConnector)
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (SomeException, try, catch)
import           Control.Monad              (void, forM_)
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (ClientState (..),
                                             RedisCommandClient (..),
                                             RedisCommands (..))
import           Resp                       (RespData (..))
import           System.Exit                (ExitCode (..))
import           System.Process             (readProcessWithExitCode)

-- | Seed node for cluster discovery
seedNode :: NodeAddress
seedNode = NodeAddress "redis1.local" 6379

-- | Default pool config for tests
defaultPoolConfig :: PoolConfig
defaultPoolConfig = PoolConfig
  { maxConnectionsPerNode = 4
  , connectionTimeout     = 5000
  , maxRetries            = 3
  , ConnectionPool.useTLS = False
  }

-- | Default cluster config for tests
defaultTestConfig :: ClusterConfig
defaultTestConfig = ClusterConfig
  { clusterSeedNode                = seedNode
  , clusterPoolConfig              = defaultPoolConfig
  , clusterMaxRetries              = 3
  , clusterRetryDelay              = 100000  -- 100ms
  , clusterTopologyRefreshInterval = 600     -- 10 minutes
  }

-- | Plaintext connector for tests
testConnector :: Connector PlainTextClient
testConnector = clusterPlaintextConnector

-- | Create a test client with default config
createTestClient :: IO (ClusterClient PlainTextClient)
createTestClient = createClusterClient defaultTestConfig testConnector

-- | Create a test client with custom config modifier
createTestClientWith :: (ClusterConfig -> ClusterConfig) -> IO (ClusterClient PlainTextClient)
createTestClientWith f = createClusterClient (f defaultTestConfig) testConnector

-- | Run a cluster command using the test connector
runCmd :: ClusterClient PlainTextClient -> ClusterCommandClient PlainTextClient a -> IO a
runCmd client = runClusterCommandClient client testConnector

-- | Flush all keys on all master nodes
flushAllNodes :: ClusterClient PlainTextClient -> IO ()
flushAllNodes client = do
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  forM_ masterNodes $ \node -> do
    let addr = nodeAddress node
    result <- try $ do
      conn <- Client.connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
      _ <- State.evalStateT (runRedisCommandClient flushAll) (ClientState conn BS.empty)
      Client.close conn
    case result of
      Left (_ :: SomeException) -> return ()
      Right _                    -> return ()

-- | Docker container names for each node
nodeContainerName :: Int -> String
nodeContainerName n = "redis-cluster-node" ++ show n

-- | Stop a Redis cluster node by number (1-5)
stopNode :: Int -> IO ()
stopNode n = do
  (_, _, _) <- readProcessWithExitCode "docker" ["stop", nodeContainerName n] ""
  return ()

-- | Start a Redis cluster node by number (1-5)
startNode :: Int -> IO ()
startNode n = do
  (_, _, _) <- readProcessWithExitCode "docker" ["start", nodeContainerName n] ""
  return ()

-- | Wait for the cluster to become ready after a node restart.
-- Polls node 1 (or fallback) for cluster_state:ok.
waitForClusterReady :: Int -> IO ()
waitForClusterReady maxWaitSeconds = go maxWaitSeconds
  where
    go 0 = error "Cluster did not become ready in time"
    go remaining = do
      result <- try $ do
        conn <- Client.connect (NotConnectedPlainTextClient (nodeHost seedNode) (Just (nodePort seedNode)))
        resp <- State.evalStateT (runRedisCommandClient ping) (ClientState conn BS.empty)
        Client.close conn
        return resp
        :: IO (Either SomeException RespData)
      case result of
        Right (RespSimpleString "PONG") -> do
          -- Cluster bus needs a moment to stabilize after node restart
          threadDelay 1000000  -- 1s extra stabilization
        _ -> do
          threadDelay 1000000  -- 1s
          go (remaining - 1)
