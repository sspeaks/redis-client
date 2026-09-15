-- | Stable convenience facade for common standalone and cluster workflows.
--
-- Import this single module for both standalone and cluster Redis usage.
-- The lifecycle and configuration entry points exported here are the
-- recommended starting point for application code. Advanced connection,
-- pooling, and raw-command APIs remain available from their named modules.
--
-- The legacy top-level package library still exposes the internal multiplexing
-- modules for source compatibility, but this facade does not re-export them.
--
-- __Standalone usage with bracket pattern (recommended):__
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- import Database.Redis
--
-- main :: IO ()
-- main = do
--   result <- runRedis defaultStandaloneConfig $ do
--     set \"mykey\" \"myvalue\"
--     (val :: ByteString) <- get \"mykey\"
--     return val
--   print result
-- @
--
-- __Typed returns via 'FromResp':__
--
-- @
-- runRedis defaultStandaloneConfig $ do
--   set \"counter\" \"42\"
--   (n :: Integer) <- get \"counter\"  -- automatically parsed
--   (bs :: ByteString) <- get \"counter\"  -- raw bytes
--   (mt :: Maybe Text) <- get \"missing\"  -- Nothing for missing keys
-- @
--
-- __Cluster usage with bracket pattern:__
--
-- @
-- withClusterClient clusterConfig connector $ \\client ->
--   runClusterCommandClient client $ do
--     set \"mykey\" \"myvalue\"
--     get \"mykey\"
-- @
--
-- @since 0.1.0.0
module Database.Redis
  ( -- * RESP Protocol
    module Database.Redis.Resp
    -- * Transport
  , module Database.Redis.Client
    -- * Redis Commands
  , module Database.Redis.Command
    -- * FromResp conversion
  , module Database.Redis.FromResp
    -- * Cluster
  , module Database.Redis.Cluster
  , module Database.Redis.Cluster.Client
  , module Database.Redis.Cluster.ConnectionPool
    -- * Standalone Multiplexed Client
  , module Database.Redis.Standalone
    -- * Connection Helpers
  , module Database.Redis.Connector
    -- * ByteString (re-exported for convenience)
  , ByteString
  ) where

import           Data.ByteString                       (ByteString)
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..),
                                                        PlainTextClient (..),
                                                        TLSClient (..))
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..),
                                                        SlotRange (..))
import           Database.Redis.Cluster.Client         (ClusterAuthentication (..),
                                                        ClusterAuthenticationException (..),
                                                        ClusterClient (..),
                                                        ClusterCommandClient,
                                                        ClusterConfig (..),
                                                        ClusterError (..),
                                                        ClusterRuntimeAuthenticationUnsupported (..),
                                                        closeClusterClient,
                                                        createClusterClient,
                                                        createClusterClientWithAuthentication,
                                                        refreshTopology,
                                                        runClusterCommandClient,
                                                        withClusterClient,
                                                        withClusterClientAuthentication)
import           Database.Redis.Cluster.ConnectionPool (ConnectionPool (..),
                                                        ConnectionPoolException (..),
                                                        ConnectionPoolStats (..),
                                                        PoolConfig (..),
                                                        closePool, createPool,
                                                        getConnectionPoolStats,
                                                        withConnection)
import           Database.Redis.Command                (ClientReplyModeUnsupported (..),
                                                        ClientReplyUncertainWrite (..),
                                                        ClientReplyValues (..),
                                                        ClientState (..),
                                                        RedisCommandClient (..),
                                                        RedisCommands (..),
                                                        RedisError (..),
                                                        convertResp,
                                                        encodeBulkArg,
                                                        encodeCommand,
                                                        encodeCommandBuilder,
                                                        encodeGetBuilder,
                                                        encodeSetBuilder,
                                                        parseManyWith,
                                                        parseWith, showBS)
import           Database.Redis.Connector              (ConnectionPhase (..),
                                                        ConnectionSetupException (..),
                                                        ConnectionSupervisor (..),
                                                        Connector,
                                                        clusterPlaintextConnector,
                                                        clusterPlaintextConnectorWithTimeout,
                                                        clusterTLSConnector,
                                                        clusterTLSConnectorWithTimeout,
                                                        connectPlaintext,
                                                        connectPlaintextWithTimeout,
                                                        connectTLS,
                                                        connectTLSWithTimeout,
                                                        withConnectionTimeout,
                                                        withConnectionTimeoutSupervised)
import           Database.Redis.FromResp               (FromResp (..))
import           Database.Redis.Resp                   (Encodable (..),
                                                        RespData (..),
                                                        parseRespData,
                                                        parseStrict)
import           Database.Redis.Standalone             (StandaloneClient,
                                                        StandaloneCommandClient,
                                                        StandaloneConfig (..),
                                                        closeStandaloneClient,
                                                        createStandaloneClient,
                                                        createStandaloneClientFromConfig,
                                                        defaultStandaloneConfig,
                                                        runRedis,
                                                        runStandaloneClient,
                                                        withStandaloneClient)
