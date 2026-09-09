{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LibraryE2E.Utils
  ( -- * Client creation
    createTestClient
  , createTestClientWith
  , createOutageTestClient
  , defaultTestConfig
  , defaultPoolConfig
  , testConnector
    -- * Command helpers
  , runCmd
  , flushAllNodes
    -- * Docker node management
  , withStoppedNode
  , withStoppedNodes
  , waitForClusterReady
  , nodeOutageScenario
  , NodeOutageScenario (..)
    -- * Constants
  , seedNode
  ) where

import           Control.Concurrent.STM                (readTVarIO)
import           Control.Exception                     (SomeException, bracket,
                                                        throwIO, try)
import           Control.Monad                         (forM_, unless)
import           Control.Monad.IO.Class                (liftIO)
import qualified Control.Monad.State                   as State
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Lazy                  as LBS
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (Connected),
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
import           Database.Redis.Command                (ClientState (..),
                                                        RedisCommandClient (..),
                                                        RedisCommands (..),
                                                        encodeCommand,
                                                        parseWith,
                                                        runRedisCommandClient)
import           Database.Redis.Connector              (Connector,
                                                        clusterPlaintextConnector)
import           Database.Redis.Resp                   (RespData (..))
import           LibraryE2E.NodeLifecycle
import           LibraryE2E.NodeTargeting              (NodeOutageScenario (..),
                                                        dockerNodeTarget,
                                                        resolveNodeOutageScenario)
import           System.Process                        (readProcessWithExitCode)

-- | Seed node for cluster discovery
seedNode :: NodeAddress
seedNode = NodeAddress "redis1.local" 6379

-- | Default pool config for tests
defaultPoolConfig :: PoolConfig
defaultPoolConfig = PoolConfig
  { maxConnectionsPerNode = 4
  , connectionTimeout     = 5000
  , maxRetries            = 3
  , useTLS = False
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

createOutageTestClient :: IO (ClusterClient PlainTextClient)
createOutageTestClient = createTestClientWith $ \config -> config
  { clusterMaxRetries = 2
  , clusterRetryDelay = 10000
  , clusterPoolConfig = (clusterPoolConfig config)
      { connectionTimeout = 1
      }
  }

-- | Run a cluster command using the test connector
runCmd :: ClusterClient PlainTextClient -> ClusterCommandClient PlainTextClient a -> IO a
runCmd client = runClusterCommandClient client

-- | Flush all keys on all master nodes
flushAllNodes :: ClusterClient PlainTextClient -> IO ()
flushAllNodes client = do
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  forM_ masterNodes $ \node -> do
    let addr = nodeAddress node
    result <- try $ do
      conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
      _ <- State.evalStateT (runRedisCommandClient flushAll) (ClientState conn BS.empty) :: IO RespData
      close conn
    case result of
      Left (_ :: SomeException) -> return ()
      Right _                   -> return ()

withStoppedNode :: Int -> IO a -> IO a
withStoppedNode node action = do
  target <- requireNodeTarget node
  withStoppedNodeUsing nodeLifecycleOperations target action

withStoppedNodes :: [Int] -> IO a -> IO a
withStoppedNodes nodes action = do
  targets <- mapM requireNodeTarget nodes
  withStoppedNodesUsing nodeLifecycleOperations targets action

nodeOutageScenario
  :: ClusterClient PlainTextClient
  -> Int
  -> IO NodeOutageScenario
nodeOutageScenario client node = do
  topology <- readTVarIO $ clusterTopology client
  target <- requireNodeTarget node
  either (throwIO . userError) return $
    resolveNodeOutageScenario 100000 target topology

nodeLifecycleOperations :: NodeLifecycleOps
nodeLifecycleOperations = NodeLifecycleOps
  { stopNodeOperation =
      runNodeCommandUsing readProcessWithExitCode StopNode
  , startNodeOperation =
      runNodeCommandUsing readProcessWithExitCode StartNode
  , waitNodeReady = waitForNodeReady 30
  }

requireNodeTarget :: Int -> IO NodeTarget
requireNodeTarget =
  either (throwIO . userError) return . dockerNodeTarget

-- | Wait for the cluster to become ready after a node restart.
-- Polls node 1 for PONG and a complete healthy cluster view.
waitForClusterReady :: Int -> IO ()
waitForClusterReady maxWaitSeconds = do
  target <- requireNodeTarget 1
  waitForNodeReady maxWaitSeconds target

waitForNodeReady :: Int -> NodeTarget -> IO ()
waitForNodeReady maxWaitSeconds =
  waitForReadinessUsing maxWaitSeconds probeNode

probeNode :: NodeTarget -> IO ()
probeNode target =
  bracket
    (connect $ NotConnectedPlainTextClient
      (targetHost target) (Just $ targetPort target))
    close $ \connection -> do
      pingResponse <- runDirect connection ping
      unless (pingResponse == RespSimpleString "PONG") $
        throwIO $ userError $ "Unexpected PING response: "
          ++ show pingResponse
      clusterInfo <- runRaw connection ["CLUSTER", "INFO"]
      case clusterInfo of
        RespBulkString payload -> do
          unless ("cluster_state:ok" `BS.isInfixOf` payload) $
            throwIO $ userError "Cluster state is not ok"
          unless ("cluster_slots_assigned:16384" `BS.isInfixOf` payload) $
            throwIO $ userError "Cluster slot coverage is incomplete"
          unless ("cluster_known_nodes:5" `BS.isInfixOf` payload) $
            throwIO $ userError "Restarted node has not rejoined all peers"
        other ->
          throwIO $ userError $ "Unexpected CLUSTER INFO response: "
            ++ show other

runDirect
  :: PlainTextClient 'Connected
  -> RedisCommandClient PlainTextClient a
  -> IO a
runDirect connection command =
  State.evalStateT
    (runRedisCommandClient command)
    (ClientState connection BS.empty)

runRaw
  :: PlainTextClient 'Connected
  -> [BS.ByteString]
  -> IO RespData
runRaw connection arguments = runDirect connection $ RedisCommandClient $ do
  ClientState connected _ <- State.get
  liftIO $ send connected $ LBS.fromStrict $ encodeCommand arguments
  parseWith $ liftIO $ receive connected
