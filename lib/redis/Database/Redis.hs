-- | Convenience re-export module for redis-client library consumers.
--
-- Importing this single module gives you everything needed for both
-- standalone and cluster Redis usage.
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   client <- createClusterClient config connector
--   runClusterCommandClient client $ do
--     set \"mykey\" \"myvalue\"
--     result <- get \"mykey\"
--     ...
-- @
module Database.Redis
  ( -- * RESP Protocol
    module Database.Redis.Resp
    -- * Transport
  , module Database.Redis.Client
    -- * Redis Commands
  , module Database.Redis.Command
    -- * FromResp conversion
  , module FromResp
    -- * Cluster
  , module Database.Redis.Cluster
  , module Database.Redis.Cluster.Client
  , module Database.Redis.Cluster.ConnectionPool
    -- * Multiplexing
  , module Database.Redis.Internal.Multiplexer
  , module Database.Redis.Internal.MultiplexPool
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
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterCommandClient,
                                                        ClusterConfig (..),
                                                        ClusterError (..),
                                                        closeClusterClient,
                                                        createClusterClient,
                                                        refreshTopology,
                                                        runClusterCommandClient)
import           Database.Redis.Cluster.ConnectionPool (ConnectionPool (..),
                                                        PoolConfig (..),
                                                        closePool, createPool,
                                                        withConnection)
import           Database.Redis.Command                (ClientReplyValues (..),
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
import           Database.Redis.Connector              (Connector,
                                                        clusterPlaintextConnector,
                                                        clusterTLSConnector,
                                                        connectPlaintext,
                                                        connectTLS)
import           Database.Redis.Internal.Multiplexer   (Multiplexer,
                                                        MultiplexerException (..),
                                                        createMultiplexer,
                                                        destroyMultiplexer,
                                                        isMultiplexerAlive,
                                                        submitCommand)
import           Database.Redis.Internal.MultiplexPool (MultiplexPool,
                                                        closeMultiplexPool,
                                                        createMultiplexPool,
                                                        submitToNode)
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
                                                        runStandaloneClient)
import           FromResp                              (FromResp (..))
