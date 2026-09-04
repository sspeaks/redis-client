{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterSetup
  ( authenticateClient
  , createAuthenticatedConnectorWithTimeout
  , createPlaintextConnector
  , createPlaintextConnectorWithTimeout
  , createTLSConnector
  , createTLSConnectorWithTimeout
  , createClusterClientFromState
  , flushAllClusterNodes
  ) where

import           AppConfig                             (RunState (..),
                                                        authenticate,
                                                        enforcePlaintextAuthenticationPolicy)
import           Control.Concurrent.STM                (readTVarIO)
import           Control.Exception                     (onException)
import qualified Control.Monad.State                   as State
import qualified Data.ByteString                       as BS
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import           Database.Redis.Client                 (Client (abort),
                                                        ConnectionPhase (..),
                                                        ConnectionStatus (..),
                                                        PlainTextClient (..),
                                                        TLSClient (..),
                                                        connectPlaintextWithCleanup,
                                                        connectTLSWithCleanup)
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..))
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterConfig (..),
                                                        createClusterClientWithBoundedConnector)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (PoolConfig))
import qualified Database.Redis.Cluster.ConnectionPool as CP
import           Database.Redis.Command                (ClientState (ClientState),
                                                        RedisCommands (flushAll))
import qualified Database.Redis.Command                as RedisCommand
import           Database.Redis.Connector              (ConnectionSupervisor (..),
                                                        Connector,
                                                        withConnectionTimeoutSupervised)
import           Database.Redis.Resp                   (RespData)
import           Text.Printf                           (printf)

-- | Authenticate a client connection if a password is configured
authenticateClient :: (Client client) => RunState -> client 'Connected -> IO (client 'Connected)
authenticateClient state client
  | null (password state) = return client
  | otherwise =
      runAuthentication state client
      `onException` abort client

runAuthentication
  :: (Client client)
  => RunState
  -> client 'Connected
  -> IO (client 'Connected)
runAuthentication state client
  | null (password state) = return client
  | otherwise = do
      _ <- State.evalStateT
             (RedisCommand.runRedisCommandClient (authenticate (username state) (password state)))
             (ClientState client BS.empty)
      return client

-- | Create cluster connector for plaintext connections
createPlaintextConnector :: RunState -> Connector PlainTextClient
createPlaintextConnector = createPlaintextConnectorWithTimeout 300

createPlaintextConnectorWithTimeout
  :: Int
  -> RunState
  -> Connector PlainTextClient
createPlaintextConnectorWithTimeout seconds state =
  createAuthenticatedConnectorWithTimeout seconds state $ \supervisor addr -> do
      enforcePlaintextAuthenticationPolicy state
      connectPlaintextWithCleanup
        (setConnectionPhase supervisor)
        (registerSetupCleanup supervisor)
        (nodeHost addr)
        (Just $ nodePort addr)

-- | Create cluster connector for TLS connections
-- Uses the original seed hostname for TLS certificate validation to avoid
-- hostname mismatch errors when CLUSTER SLOTS returns IP addresses
createTLSConnector :: RunState -> Connector TLSClient
createTLSConnector = createTLSConnectorWithTimeout 300

createTLSConnectorWithTimeout
  :: Int
  -> RunState
  -> Connector TLSClient
createTLSConnectorWithTimeout seconds state =
  createAuthenticatedConnectorWithTimeout seconds state $ \supervisor addr ->
    connectTLSWithCleanup
      (setConnectionPhase supervisor)
      (registerSetupCleanup supervisor)
      (host state)
      (nodeHost addr)
      (Just $ nodePort addr)

-- | Production connector seam shared by plaintext, TLS, and deterministic
-- authentication tests. Transport ownership is registered before AUTH.
createAuthenticatedConnectorWithTimeout
  :: (Client client)
  => Int
  -> RunState
  -> (ConnectionSupervisor client
      -> NodeAddress
      -> IO (client 'Connected))
  -> Connector client
createAuthenticatedConnectorWithTimeout seconds state connectTransport =
  withConnectionTimeoutSupervised seconds DNSResolution $ \supervisor addr -> do
    client <- connectTransport supervisor addr
    cleanup <- registerConnectedTransport supervisor client
    setConnectionPhase supervisor Authentication
    runAuthentication state client `onException` cleanup

-- | Create a cluster client from RunState
createClusterClientFromState :: (Client client) =>
  RunState ->
  Connector client ->
  IO (ClusterClient client)
createClusterClientFromState state connector = do
  let defaultPort = if useTLS state then 6380 else 6379
      seedNode = NodeAddress (host state) (fromMaybe defaultPort (port state))
      poolConfig = PoolConfig
        { CP.maxConnectionsPerNode = 10  -- Max connections per node
        , CP.connectionTimeout = 300     -- 5 minutes timeout
        , CP.maxRetries = 3
        , CP.useTLS = useTLS state
        }
      clusterCfg = ClusterConfig
        { clusterSeedNode = seedNode
        , clusterPoolConfig = poolConfig
        , clusterMaxRetries = 3
        , clusterRetryDelay = 100000  -- 100ms
        , clusterTopologyRefreshInterval = 600  -- 10 minutes
        }
  createClusterClientWithBoundedConnector clusterCfg connector

-- | Flush all master nodes in a cluster
flushAllClusterNodes :: (Client client) =>
  ClusterClient client ->
  Connector client ->
  IO ()
flushAllClusterNodes clusterClient _connector = do
  topology <- readTVarIO (clusterTopology clusterClient)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

  printf "Flushing %d master nodes in cluster...\n" (length masterNodes)

  mapM_ (\node -> do
      let addr = nodeAddress node
      printf "  Flushing node %s:%d\n" (nodeHost addr) (nodePort addr)
      CP.withConnectionBounded
        (clusterConnectionPool clusterClient)
        addr
        (clusterConnector clusterClient) $ \conn -> do
        let clientState = ClientState conn BS.empty
        (_ :: RespData) <- State.evalStateT (RedisCommand.runRedisCommandClient flushAll) clientState
        return ()
    ) masterNodes

  putStrLn "All master nodes flushed successfully"
