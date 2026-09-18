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
                                                        enforcePlaintextAuthenticationPolicy)
import           Control.Concurrent.STM                (readTVarIO)
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
                                                        defaultClusterConfig)
import qualified Database.Redis.Cluster.ConnectionPool as CP
import           Database.Redis.Command                (RedisCommands (flushAll))
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
createClusterClientFromState state =
  createClusterClientFromStateWithMuxCount state 1

clusterConfigFromState :: RunState -> ClusterConfig
clusterConfigFromState state =
  let defaultPort = if useTLS state then 6380 else 6379
      seedNode = NodeAddress (host state) (fromMaybe defaultPort (port state))
  in defaultClusterConfig seedNode

createClusterClientFromStateWithMuxCount :: (Client client) =>
  RunState ->
  Int ->
  Connector client ->
  IO (ClusterClient client)
createClusterClientFromStateWithMuxCount state requestedMuxCount connector = do
  let clusterCfg = (clusterConfigFromState state)
        { clusterMultiplexerCount = requestedMuxCount }
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
        (_ :: RespData) <- State.evalStateT
          (RedisCommand.unRedisCommandClient flushAll) clientState
        return ()
    ) masterNodes

  putStrLn "All master nodes flushed successfully"
