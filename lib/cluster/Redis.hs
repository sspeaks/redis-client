-- | Convenience re-export module for redis-client library consumers.
--
-- Importing this single module gives you everything needed for both
-- standalone and cluster Redis usage:
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   client <- createClusterClient config connector
--   result <- executeClusterCommand client "mykey" (set "mykey" "value") connector
--   ...
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
    -- * Connection Helpers
  , module Connector
  ) where

import Resp (RespData (..), Encodable (..), parseRespData, parseStrict)
import Client (Client (..), PlainTextClient (..), TLSClient (..), ConnectionStatus (..))
import RedisCommandClient (RedisCommandClient (..), RedisCommands (..), ClientState (..), RedisError (..), ClientReplyValues (..), parseWith, parseManyWith)
import Cluster (NodeAddress (..), ClusterNode (..), SlotRange (..), ClusterTopology (..), NodeRole (..))
import ClusterCommandClient (ClusterClient (..), ClusterConfig (..), ClusterError (..), ClusterCommandClient, createClusterClient, closeClusterClient, executeClusterCommand, executeKeylessClusterCommand, refreshTopology, runClusterCommandClient)
import ConnectionPool (ConnectionPool (..), PoolConfig (..), withConnection, createPool, closePool)
import Connector (Connector, connectPlaintext, connectTLS, clusterPlaintextConnector, clusterTLSConnector)
