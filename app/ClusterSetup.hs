{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterSetup
  ( createPlaintextConnector
  , createTLSConnector
  , clusterConfigFromState
  , createClusterClientFromState
  , createClusterClientFromStateWithMuxCount
  , flushAllClusterNodes
  ) where

import           AppConfig                             (RunState (..),
                                                        authenticate,
                                                        enforcePlaintextAuthenticationPolicy)
import           Control.Concurrent.STM                (readTVarIO)
import qualified Control.Monad.State                   as State
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Char8                 as BS8
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import           Database.Redis.Client                 (Client, PlainTextClient,
                                                        TLSClient)
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..))
import           Database.Redis.Cluster.Client         (ClusterAuthentication (..),
                                                        ClusterClient (..),
                                                        ClusterConfig (..),
                                                        createClusterClient,
                                                        createClusterClientWithAuthentication,
                                                        createClusterClientWithFactories)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (PoolConfig))
import qualified Database.Redis.Cluster.ConnectionPool as CP
import           Database.Redis.Command                (ClientState (ClientState),
                                                        RedisCommands (flushAll))
import qualified Database.Redis.Command                as RedisCommand
import           Database.Redis.Connector              (Connector,
                                                        clusterPlaintextConnector,
                                                        clusterTLSConnector)
import           Database.Redis.Internal.MultiplexPool (createMultiplexPool)
import           Database.Redis.Resp                   (RespData)
import           Text.Printf                           (printf)

-- | Create cluster connector for plaintext connections
createPlaintextConnector :: RunState -> Connector PlainTextClient
createPlaintextConnector state addr = do
  enforcePlaintextAuthenticationPolicy state
  clusterPlaintextConnector addr

-- | Create cluster connector for TLS connections
-- Uses the original seed hostname for TLS certificate validation to avoid
-- hostname mismatch errors when CLUSTER SLOTS returns IP addresses
createTLSConnector :: RunState -> Connector TLSClient
createTLSConnector state = clusterTLSConnector (host state)

-- | Create a cluster client from RunState
createClusterClientFromState :: (Client client) =>
  RunState ->
  Connector client ->
  IO (ClusterClient client)
createClusterClientFromState state =
  createClusterClientFromStateWithMuxCount state 1

clusterConfigFromState :: RunState -> ClusterConfig
clusterConfigFromState state =
  let defaultPort = if useTLS state then 6380 else 6379
      seedNode = NodeAddress (host state) (fromMaybe defaultPort (port state))
      poolConfig = PoolConfig
        { CP.maxConnectionsPerNode = 10
        , CP.connectionTimeout = 300
        , CP.maxRetries = 3
        , CP.useTLS = useTLS state
        }
  in ClusterConfig
      { clusterSeedNode = seedNode
      , clusterPoolConfig = poolConfig
      , clusterMaxRetries = 3
      , clusterRetryDelay = 100000
      , clusterTopologyRefreshInterval = 600
      }

createClusterClientFromStateWithMuxCount :: (Client client) =>
  RunState ->
  Int ->
  Connector client ->
  IO (ClusterClient client)
createClusterClientFromStateWithMuxCount state requestedMuxCount connector = do
  let clusterCfg = clusterConfigFromState state
      muxCount = max 1 requestedMuxCount
  case clusterAuthentication state of
    Nothing ->
      if muxCount == 1
        then createClusterClient clusterCfg connector
        else createClusterClientWithMuxCount clusterCfg connector muxCount
    Just authentication ->
      if muxCount == 1
        then createClusterClientWithAuthentication clusterCfg authentication connector
        else createAuthenticatedClusterClientWithMuxCount
          clusterCfg authentication connector muxCount

createClusterClientWithMuxCount
  :: (Client client)
  => ClusterConfig
  -> Connector client
  -> Int
  -> IO (ClusterClient client)
createClusterClientWithMuxCount clusterCfg connector muxCount =
  createClusterClientWithFactories
    CP.createPool
    (\boundedConnector _ -> createMultiplexPool boundedConnector muxCount)
    clusterCfg
    connector

createAuthenticatedClusterClientWithMuxCount
  :: (Client client)
  => ClusterConfig
  -> ClusterAuthentication
  -> Connector client
  -> Int
  -> IO (ClusterClient client)
createAuthenticatedClusterClientWithMuxCount clusterCfg authentication connector muxCount =
  createClusterClientWithFactories
    CP.createPool
    (\boundedConnector _ -> createMultiplexPool boundedConnector muxCount)
    clusterCfg
    authenticatedConnector
  where
    authenticatedConnector addr = do
      conn <- connector addr
      let clientState = ClientState conn BS.empty
      _ <- State.evalStateT (RedisCommand.unRedisCommandClient authenticationAction) clientState
      return conn
    authenticationAction =
      case authentication of
        ClusterPassword passwordValue ->
          authenticate "default" (BS8.unpack passwordValue)
        ClusterACL usernameValue passwordValue ->
          authenticate (BS8.unpack usernameValue) (BS8.unpack passwordValue)

clusterAuthentication :: RunState -> Maybe ClusterAuthentication
clusterAuthentication state
  | null (password state) = Nothing
  | username state == "default" =
      Just $ ClusterPassword $ BS8.pack (password state)
  | otherwise =
      Just $ ClusterACL
        (BS8.pack $ username state)
        (BS8.pack $ password state)

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
        (_ :: RespData) <- State.evalStateT
          (RedisCommand.unRedisCommandClient flushAll) clientState
        return ()
    ) masterNodes

  putStrLn "All master nodes flushed successfully"
