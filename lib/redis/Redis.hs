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
module Redis
  ( -- * RESP Protocol
    module Database.Redis.Resp
    -- * Transport
  , module Database.Redis.Client
    -- * Redis Commands
  , module RedisCommandClient
    -- * FromResp conversion
  , module FromResp
    -- * Cluster
  , module Cluster
  , module ClusterCommandClient
  , module ConnectionPool
    -- * Multiplexing
  , module Multiplexer
  , module MultiplexPool
    -- * Standalone Multiplexed Client
  , module StandaloneClient
    -- * Connection Helpers
  , module Connector
    -- * ByteString (re-exported for convenience)
  , ByteString
  ) where

import           Cluster               (ClusterNode (..), ClusterTopology (..),
                                        NodeAddress (..), NodeRole (..),
                                        SlotRange (..))
import           ClusterCommandClient  (ClusterClient (..),
                                        ClusterCommandClient,
                                        ClusterConfig (..), ClusterError (..),
                                        closeClusterClient, createClusterClient,
                                        refreshTopology,
                                        runClusterCommandClient)
import           ConnectionPool        (ConnectionPool (..), PoolConfig (..),
                                        closePool, createPool, withConnection)
import           Connector             (Connector, clusterPlaintextConnector,
                                        clusterTLSConnector, connectPlaintext,
                                        connectTLS)
import           Data.ByteString       (ByteString)
import           Database.Redis.Client (Client (..), ConnectionStatus (..),
                                        PlainTextClient (..), TLSClient (..))
import           Database.Redis.Resp   (Encodable (..), RespData (..),
                                        parseRespData, parseStrict)
import           FromResp              (FromResp (..))
import           Multiplexer           (Multiplexer, MultiplexerException (..),
                                        createMultiplexer, destroyMultiplexer,
                                        isMultiplexerAlive, submitCommand)
import           MultiplexPool         (MultiplexPool, closeMultiplexPool,
                                        createMultiplexPool, submitToNode)
import           RedisCommandClient    (ClientReplyValues (..),
                                        ClientState (..),
                                        RedisCommandClient (..),
                                        RedisCommands (..), RedisError (..),
                                        convertResp, encodeBulkArg,
                                        encodeCommand, encodeCommandBuilder,
                                        encodeGetBuilder, encodeSetBuilder,
                                        parseManyWith, parseWith, showBS)
import           StandaloneClient      (StandaloneClient,
                                        StandaloneCommandClient,
                                        StandaloneConfig (..),
                                        closeStandaloneClient,
                                        createStandaloneClient,
                                        createStandaloneClientFromConfig,
                                        runStandaloneClient)
