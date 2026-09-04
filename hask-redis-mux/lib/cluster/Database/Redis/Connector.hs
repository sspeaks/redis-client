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
--
-- @since 0.1.0.0
module Database.Redis.Connector
  ( -- * Connector type
    Connector
  , ConnectionPhase (..)
  , ConnectionSetupException (..)
  , withConnectionTimeout
    -- * Standalone connections
  , connectPlaintext
  , connectTLS
    -- * Cluster connector factories
  , clusterPlaintextConnector
  , clusterTLSConnector
  ) where

import           Control.Exception      (Exception, throwIO)
import           Data.Typeable          (Typeable)
import           Database.Redis.Client  (Client (connect),
                                         ConnectionStatus (..),
                                         PlainTextClient (NotConnectedPlainTextClient),
                                         TLSClient (NotConnectedTLSClient, NotConnectedTLSClientWithHostname))
import           Database.Redis.Cluster (NodeAddress (..))
import           System.Timeout         (timeout)

-- | A function that creates a connected client for a given node address.
-- Used throughout the cluster layer to establish connections on demand.
type Connector client = NodeAddress -> IO (client 'Connected)

-- | The connection setup covered by a configured deadline.
data ConnectionPhase
  = PlaintextConnectionSetup
  | TLSConnectionSetup
  deriving (Eq, Show, Typeable)

-- | A connection setup attempt exceeded its configured wall-clock deadline.
-- The endpoint and transport phase are retained without including connector
-- arguments or credentials.
data ConnectionSetupException = ConnectionSetupTimeout
  { connectionTimeoutPhase    :: !ConnectionPhase
  , connectionTimeoutEndpoint :: !NodeAddress
  , connectionTimeoutSeconds  :: !Int
  }
  deriving (Eq, Show, Typeable)

instance Exception ConnectionSetupException

-- | Bound one complete connector action by a wall-clock deadline in seconds.
-- For the built-in plaintext connector this covers DNS, socket setup, and TCP
-- connect. For TLS it additionally covers certificate-store/context setup and
-- the TLS handshake.
withConnectionTimeout
  :: Int
  -> ConnectionPhase
  -> Connector client
  -> Connector client
withConnectionTimeout seconds phase connector addr
  | seconds <= 0 =
      throwIO $ ConnectionSetupTimeout phase addr seconds
  | otherwise = do
      result <- timeout (secondsToMicroseconds seconds) $ connector addr
      case result of
        Nothing   -> throwIO $ ConnectionSetupTimeout phase addr seconds
        Just conn -> return conn

secondsToMicroseconds :: Int -> Int
secondsToMicroseconds seconds =
  fromInteger $ min (toInteger (maxBound :: Int)) (toInteger seconds * 1000000)

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
