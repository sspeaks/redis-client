{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterSetup
  ( createPlaintextConnector
  , createTLSConnector
  , createClusterClientFromState
  , flushAllClusterNodes
  ) where

import           AppConfig                             (RunState (..),
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
                                                        createClusterClientWithAuthentication)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (PoolConfig))
import qualified Database.Redis.Cluster.ConnectionPool as CP
import           Database.Redis.Command                (ClientState (ClientState),
                                                        RedisCommands (flushAll))
import qualified Database.Redis.Command                as RedisCommand
import           Database.Redis.Connector              (Connector,
                                                        clusterPlaintextConnector,
                                                        clusterTLSConnector)
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
  case clusterAuthentication state of
    Nothing ->
      createClusterClient clusterCfg connector
    Just authentication ->
      createClusterClientWithAuthentication clusterCfg authentication connector

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
        (_ :: RespData) <- State.evalStateT (RedisCommand.runRedisCommandClient flushAll) clientState
        return ()
    ) masterNodes

  putStrLn "All master nodes flushed successfully"
