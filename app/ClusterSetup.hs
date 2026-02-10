{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterSetup
  ( authenticateClient
  , createPlaintextConnector
  , createTLSConnector
  , createClusterClientFromState
  , flushAllClusterNodes
  ) where

import           Client                     (Client (connect),
                                             ConnectionStatus (..),
                                             PlainTextClient (..),
                                             TLSClient (..))
import           Cluster                    (ClusterNode (..),
                                             ClusterTopology (..),
                                             NodeAddress (..), NodeRole (..))
import           ClusterCommandClient       (ClusterClient (..),
                                             ClusterConfig (..),
                                             createClusterClient)
import           Connector                  (Connector)
import           ConnectionPool             (PoolConfig (PoolConfig))
import qualified ConnectionPool             as CP
import           Control.Concurrent.STM     (readTVarIO)
import qualified Control.Monad.State        as State
import           AppConfig                  (RunState (..), authenticate)
import qualified Data.ByteString            as BS
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe)
import qualified RedisCommandClient
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommands (flushAll))
import           Text.Printf                (printf)

-- | Authenticate a client connection if a password is configured
authenticateClient :: (Client client) => RunState -> client 'Connected -> IO (client 'Connected)
authenticateClient state client
  | null (password state) = return client
  | otherwise = do
      _ <- State.evalStateT
             (RedisCommandClient.runRedisCommandClient (authenticate (username state) (password state)))
             (ClientState client BS.empty)
      return client

-- | Create cluster connector for plaintext connections
createPlaintextConnector :: RunState -> Connector PlainTextClient
createPlaintextConnector state addr = do
  client <- connect $ NotConnectedPlainTextClient (nodeHost addr) (Just $ nodePort addr)
  authenticateClient state client

-- | Create cluster connector for TLS connections
-- Uses the original seed hostname for TLS certificate validation to avoid
-- hostname mismatch errors when CLUSTER SLOTS returns IP addresses
createTLSConnector :: RunState -> Connector TLSClient
createTLSConnector state addr = do
  client <- connect $ NotConnectedTLSClientWithHostname (host state) (nodeHost addr) (Just $ nodePort addr)
  authenticateClient state client

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
  createClusterClient clusterCfg connector

-- | Flush all master nodes in a cluster
flushAllClusterNodes :: (Client client) =>
  ClusterClient client ->
  Connector client ->
  IO ()
flushAllClusterNodes clusterClient connector = do
  topology <- readTVarIO (clusterTopology clusterClient)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

  printf "Flushing %d master nodes in cluster...\n" (length masterNodes)

  mapM_ (\node -> do
      let addr = nodeAddress node
      printf "  Flushing node %s:%d\n" (nodeHost addr) (nodePort addr)
      CP.withConnection (clusterConnectionPool clusterClient) addr connector $ \conn -> do
        let clientState = ClientState conn BS.empty
        _ <- State.evalStateT (RedisCommandClient.runRedisCommandClient flushAll) clientState
        return ()
    ) masterNodes

  putStrLn "All master nodes flushed successfully"
