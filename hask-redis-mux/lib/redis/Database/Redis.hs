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
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- main :: IO ()
-- main = do
--   result <- runRedis defaultStandaloneConfig $ do
--     (_ :: Bool) <- set \"mykey\" \"myvalue\"
--     (val :: ByteString) <- get \"mykey\"
--     return val
--   print result
-- @
--
-- __Typed returns via 'FromResp':__
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Data.Text (Text)
-- import Database.Redis
--
-- typedReturns :: IO (Either RedisClientError (Integer, ByteString, Maybe Text))
-- typedReturns =
--   runRedis defaultStandaloneConfig $ do
--     (_ :: Bool) <- set \"counter\" \"42\"
--     (n :: Integer) <- get \"counter\"
--     (bs :: ByteString) <- get \"counter\"
--     (mt :: Maybe Text) <- get \"missing\"
--     return (n, bs, mt)
-- @
--
-- __Cluster usage with bracket pattern:__
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- clusterExample :: IO (Either RedisClientError ByteString)
-- clusterExample =
--   withClusterClient exampleClusterConfig clusterPlaintextConnector $ \\client ->
--     runClusterCommandClient client $ do
--       (_ :: Bool) <- set \"{example}:key\" \"myvalue\"
--       get \"{example}:key\"
--
-- exampleClusterConfig :: ClusterConfig
-- exampleClusterConfig =
--   (defaultClusterConfig $ NodeAddress \"localhost\" 7000)
--     { clusterPoolConfig = defaultPoolConfig
--       { maxConnectionsPerNode = 2
--       , connectionTimeout = 5
--       }
--     , clusterMultiplexerCount = 2
--     }
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
                                                        ClusterConfigException (..),
                                                        ClusterRuntimeAuthenticationUnsupported (..),
                                                        closeClusterClient,
                                                        createClusterClient,
                                                        createClusterClientWithAuthentication,
                                                        defaultClusterConfig,
                                                        refreshTopology,
                                                        runClusterCommandClient,
                                                        withClusterClient,
                                                        withClusterClientAuthentication)
import           Database.Redis.Cluster.ConnectionPool (ConnectionPool (..),
                                                        ConnectionPoolException (..),
                                                        ConnectionPoolStats (..),
                                                        PoolConfig (..),
                                                        PoolConfigException (..),
                                                        closePool, createPool,
                                                        defaultPoolConfig,
                                                        getConnectionPoolStats,
                                                        withConnection)
import           Database.Redis.Command                (ClientReplyModeUnsupported (..),
                                                        ClientReplyUncertainWrite (..),
                                                        ClientReplyValues (..),
                                                        ClientState (..),
                                                        RedisClientError (..),
                                                        RedisClusterFailure (..),
                                                        RedisCommandClient (..),
                                                        RedisCommands (..),
                                                        RedisLifecycleFailure (..),
                                                        RedisProtocolFailure (..),
                                                        convertResp,
                                                        encodeBulkArg,
                                                        encodeCommand,
                                                        encodeCommandBuilder,
                                                        encodeGetBuilder,
                                                        encodeSetBuilder,
                                                        parseManyWith,
                                                        parseWith, showBS,
                                                        tryRedisClient)
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
                                                        StandaloneConfigException (..),
                                                        closeStandaloneClient,
                                                        createStandaloneClient,
                                                        createStandaloneClientFromConfig,
                                                        defaultStandaloneConfig,
                                                        runRedis,
                                                        runStandaloneClient,
                                                        withStandaloneClient)
