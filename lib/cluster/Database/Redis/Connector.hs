{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE RankNTypes #-}

-- | Connector factories for creating Redis connections.
--
-- The 'Connector' type alias represents a function that creates a connected
-- client for a given 'NodeAddress'. Connector values are passed to
-- 'ClusterCommandClient.createClusterClient' and related functions.
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   -- Standalone plaintext
--   conn <- connectPlaintext "localhost" 6379
--   ...
--
--   -- Cluster with TLS
--   let connector = clusterTLSConnector "redis.example.com"
--   client <- createClusterClient config connector
--   ...
-- @
module Database.Redis.Connector
  ( -- * Connector type
    Connector
    -- * Standalone connections
  , connectPlaintext
  , connectTLS
    -- * Cluster connector factories
  , clusterPlaintextConnector
  , clusterTLSConnector
  ) where

import           Database.Redis.Client  (Client (connect),
                                         ConnectionStatus (..),
                                         PlainTextClient (NotConnectedPlainTextClient),
                                         TLSClient (NotConnectedTLSClient, NotConnectedTLSClientWithHostname))
import           Database.Redis.Cluster (NodeAddress (..))

-- | A function that creates a connected client for a given node address.
-- Used throughout the cluster layer to establish connections on demand.
type Connector client = NodeAddress -> IO (client 'Connected)

-- | Connect a plaintext client to a specific host and port.
--
-- @
-- conn <- connectPlaintext "localhost" 6379
-- @
connectPlaintext :: String -> Int -> IO (PlainTextClient 'Connected)
connectPlaintext host port =
  connect $ NotConnectedPlainTextClient host (Just port)

-- | Connect a TLS client to a specific host and port.
--
-- @
-- conn <- connectTLS "redis.example.com" 6380
-- @
connectTLS :: String -> Int -> IO (TLSClient 'Connected)
connectTLS host port =
  connect $ NotConnectedTLSClient host (Just port)

-- | Create a cluster connector for plaintext connections.
-- Each cluster node will be connected to using its advertised address.
--
-- @
-- let connector = clusterPlaintextConnector
-- client <- createClusterClient config connector
-- @
clusterPlaintextConnector :: Connector PlainTextClient
clusterPlaintextConnector addr =
  connect $ NotConnectedPlainTextClient (nodeHost addr) (Just $ nodePort addr)

-- | Create a cluster connector for TLS connections.
-- The @certHostname@ is used for TLS certificate validation, while each
-- node's advertised address is used for the network connection. This is
-- needed because @CLUSTER SLOTS@ often returns IP addresses that don't
-- match the TLS certificate's hostname.
--
-- @
-- let connector = clusterTLSConnector "redis.example.com"
-- client <- createClusterClient config connector
-- @
clusterTLSConnector :: String -> Connector TLSClient
clusterTLSConnector certHostname addr =
  connect $ NotConnectedTLSClientWithHostname certHostname (nodeHost addr) (Just $ nodePort addr)
