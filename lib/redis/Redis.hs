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
    module Resp
    -- * Transport
  , module Client
    -- * Redis Commands
  , module RedisCommandClient
    -- * Cluster
  , module Cluster
  , module ClusterCommandClient
  , module ConnectionPool
    -- * Multiplexing
  , module Multiplexer
  , module MultiplexPool
    -- * Connection Helpers
  , module Connector
    -- * ByteString (re-exported for convenience)
  , ByteString
  ) where

import Data.ByteString (ByteString)
import Resp (RespData (..), Encodable (..), parseRespData, parseStrict)
import Client (Client (..), PlainTextClient (..), TLSClient (..), ConnectionStatus (..))
import RedisCommandClient (RedisCommandClient (..), RedisCommands (..), ClientState (..), RedisError (..), ClientReplyValues (..), showBS, encodeCommand, encodeCommandBuilder, encodeSetBuilder, encodeGetBuilder, encodeBulkArg, parseWith, parseManyWith)
import Cluster (NodeAddress (..), ClusterNode (..), SlotRange (..), ClusterTopology (..), NodeRole (..))
import ClusterCommandClient (ClusterClient (..), ClusterConfig (..), ClusterError (..), ClusterCommandClient, createClusterClient, closeClusterClient, refreshTopology, runClusterCommandClient)
import ConnectionPool (ConnectionPool (..), PoolConfig (..), withConnection, createPool, closePool)
import Multiplexer (Multiplexer, MultiplexerException (..), createMultiplexer, submitCommand, destroyMultiplexer, isMultiplexerAlive)
import MultiplexPool (MultiplexPool, createMultiplexPool, submitToNode, closeMultiplexPool)
import Connector (Connector, connectPlaintext, connectTLS, clusterPlaintextConnector, clusterTLSConnector)
