{-# LANGUAGE OverloadedStrings #-}

-- | Standalone multiplexed Redis client.
--
-- Wraps a single 'Multiplexer' for standalone (non-cluster) Redis, providing
-- pipelined throughput without cluster mode. Implements 'RedisCommands' so all
-- existing commands work transparently.
--
-- Use 'withStandaloneClient' for automatic resource management (recommended):
--
-- @
-- import Database.Redis
--
-- main :: IO ()
-- main = do
--   let config = StandaloneConfig
--         { standaloneNodeAddress     = NodeAddress \"localhost\" 6379
--         , standaloneConnector       = clusterPlaintextConnector
--         , standaloneMultiplexerCount = 1
--         }
--   withStandaloneClient config $ \\client ->
--     runStandaloneClient client $ do
--       set \"key\" \"value\"
--       result <- get \"key\"
--       ...
-- @
--
-- @since 0.1.0.0
module Database.Redis.Standalone
  ( -- * Configuration
    StandaloneConfig (..)
  , defaultStandaloneConfig
    -- * Client type
  , StandaloneClient
  , StandaloneCommandClient
    -- * Lifecycle
  , createStandaloneClient
  , createStandaloneClientFromConfig
  , closeStandaloneClient
    -- * Bracket-style lifecycle (recommended)
  , withStandaloneClient
  , runRedis
    -- * Running commands
  , runStandaloneClient
  ) where

import           Control.Exception                   (SomeException, bracket,
                                                      catch)
import           Control.Monad.IO.Class              (MonadIO (..))
import           Control.Monad.Reader                (ReaderT, ask, runReaderT)
import           Data.ByteString                     (ByteString)
import           Database.Redis.Client               (Client (..),
                                                      PlainTextClient)
import           Database.Redis.Cluster              (NodeAddress (..))
import           Database.Redis.Command              (ClientReplyValues (..),
                                                      RedisCommands (..),
                                                      convertResp,
                                                      encodeCommandBuilder,
                                                      geoRadiusFlagToList,
                                                      geoSearchByToList,
                                                      geoSearchFromToList,
                                                      geoSearchOptionToList,
                                                      geoUnitKeyword, showBS)
import           Database.Redis.Connector            (Connector,
                                                      clusterPlaintextConnector)
import           Database.Redis.FromResp             (FromResp (..))
import           Database.Redis.Internal.Multiplexer (Multiplexer, SlotPool,
                                                      createMultiplexer,
                                                      createSlotPool,
                                                      destroyMultiplexer,
                                                      submitCommandPooled)
import           Database.Redis.Resp                 (RespData)


-- | Configuration for a standalone Redis client.
data StandaloneConfig client = StandaloneConfig
  { standaloneNodeAddress      :: !NodeAddress       -- ^ Redis node to connect to.
  , standaloneConnector        :: !(Connector client) -- ^ Connection factory (plaintext or TLS).
  , standaloneMultiplexerCount :: !Int                -- ^ Number of multiplexers to create (default: 1).
  }

-- | Default configuration connecting to @localhost:6379@ over plaintext with 1 multiplexer.
--
-- @
-- runRedis defaultStandaloneConfig $ do
--   set \"key\" \"value\"
--   get \"key\"
-- @
defaultStandaloneConfig :: StandaloneConfig PlainTextClient
defaultStandaloneConfig = StandaloneConfig
  { standaloneNodeAddress      = NodeAddress "localhost" 6379
  , standaloneConnector        = clusterPlaintextConnector
  , standaloneMultiplexerCount = 1
  }

-- | A standalone Redis client backed by a multiplexer and slot pool.
data StandaloneClient = StandaloneClient
  { standaloneMux  :: !Multiplexer
  , standalonePool :: !SlotPool
  }

-- | Create a standalone multiplexed client by connecting to a single Redis node.
-- This is the simple API; for more control, use 'createStandaloneClientFromConfig'.
--
-- Consider using 'withStandaloneClient' instead for automatic cleanup.
createStandaloneClient
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> IO StandaloneClient
createStandaloneClient connector addr = do
  conn <- connector addr
  mux <- createMultiplexer conn (receive conn)
  pool <- createSlotPool 256
  return $ StandaloneClient mux pool

-- | Create a standalone client from a 'StandaloneConfig'.
createStandaloneClientFromConfig
  :: (Client client)
  => StandaloneConfig client
  -> IO StandaloneClient
createStandaloneClientFromConfig config = do
  conn <- standaloneConnector config (standaloneNodeAddress config)
  mux <- createMultiplexer conn (receive conn)
  pool <- createSlotPool 256
  return $ StandaloneClient mux pool

-- | Close the standalone client, destroying the underlying multiplexer.
--
-- Consider using 'withStandaloneClient' instead for automatic cleanup.
closeStandaloneClient :: StandaloneClient -> IO ()
closeStandaloneClient client =
  destroyMultiplexer (standaloneMux client)
    `catch` \(_ :: SomeException) -> return ()

-- | Bracket-style resource management for standalone clients.
--
-- Creates a client, runs the given action, and ensures the client is closed
-- even if an exception occurs. Prefer this over manual 'createStandaloneClientFromConfig'
-- and 'closeStandaloneClient'.
--
-- @
-- withStandaloneClient config $ \\client ->
--   runStandaloneClient client $ do
--     set \"key\" \"value\"
--     get \"key\"
-- @
withStandaloneClient
  :: (Client client)
  => StandaloneConfig client
  -> (StandaloneClient -> IO a)
  -> IO a
withStandaloneClient config =
  bracket (createStandaloneClientFromConfig config) closeStandaloneClient

-- | Convenience function that creates a client, runs commands, and closes
-- the client in one step.
--
-- @
-- result <- runRedis defaultStandaloneConfig $ do
--   set \"key\" \"value\"
--   get \"key\"
-- @
runRedis
  :: (Client client)
  => StandaloneConfig client
  -> StandaloneCommandClient a
  -> IO a
runRedis config action =
  withStandaloneClient config (`runStandaloneClient` action)

-- | Monad for executing Redis commands on a standalone client.
newtype StandaloneCommandClient a = StandaloneCommandClient
  { unStandaloneCommandClient :: ReaderT StandaloneClient IO a }

-- | Run Redis commands against the standalone client.
runStandaloneClient :: StandaloneClient -> StandaloneCommandClient a -> IO a
runStandaloneClient client (StandaloneCommandClient action) =
  runReaderT action client

instance Functor StandaloneCommandClient where
  fmap f (StandaloneCommandClient r) = StandaloneCommandClient (fmap f r)

instance Applicative StandaloneCommandClient where
  pure = StandaloneCommandClient . pure
  StandaloneCommandClient f <*> StandaloneCommandClient r = StandaloneCommandClient (f <*> r)

instance Monad StandaloneCommandClient where
  StandaloneCommandClient r >>= f = StandaloneCommandClient (r >>= \a -> unStandaloneCommandClient (f a))

instance MonadIO StandaloneCommandClient where
  liftIO = StandaloneCommandClient . liftIO

instance MonadFail StandaloneCommandClient where
  fail = StandaloneCommandClient . liftIO . Prelude.fail

-- | Submit a command via the multiplexer backend.
submitMux :: [ByteString] -> StandaloneCommandClient RespData
submitMux args = do
  client <- StandaloneCommandClient ask
  let cmdBuilder = encodeCommandBuilder args
  liftIO $ submitCommandPooled (standalonePool client) (standaloneMux client) cmdBuilder

-- | Submit a command and convert the result via 'FromResp'.
submitMuxAs :: (FromResp a) => [ByteString] -> StandaloneCommandClient a
submitMuxAs args = submitMux args >>= convertResp

instance RedisCommands StandaloneCommandClient where
  auth username password = submitMuxAs ["HELLO", "3", "AUTH", username, password]
  ping = submitMuxAs ["PING"]
  set k v = submitMuxAs ["SET", k, v]
  get k = submitMuxAs ["GET", k]
  mget keys = submitMuxAs ("MGET" : keys)
  setnx k v = submitMuxAs ["SETNX", k, v]
  decr k = submitMuxAs ["DECR", k]
  psetex k ms v = submitMuxAs ["PSETEX", k, showBS ms, v]
  bulkSet kvs = submitMuxAs (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs)
  flushAll = submitMuxAs ["FLUSHALL"]
  dbsize = submitMuxAs ["DBSIZE"]
  del keys = submitMuxAs ("DEL" : keys)
  exists keys = submitMuxAs ("EXISTS" : keys)
  incr k = submitMuxAs ["INCR", k]
  hset k f v = submitMuxAs ["HSET", k, f, v]
  hget k f = submitMuxAs ["HGET", k, f]
  hmget k fs = submitMuxAs ("HMGET" : k : fs)
  hexists k f = submitMuxAs ["HEXISTS", k, f]
  lpush k vs = submitMuxAs ("LPUSH" : k : vs)
  lrange k start stop = submitMuxAs ["LRANGE", k, showBS start, showBS stop]
  expire k secs = submitMuxAs ["EXPIRE", k, showBS secs]
  ttl k = submitMuxAs ["TTL", k]
  rpush k vs = submitMuxAs ("RPUSH" : k : vs)
  lpop k = submitMuxAs ["LPOP", k]
  rpop k = submitMuxAs ["RPOP", k]
  sadd k vs = submitMuxAs ("SADD" : k : vs)
  smembers k = submitMuxAs ["SMEMBERS", k]
  scard k = submitMuxAs ["SCARD", k]
  sismember k v = submitMuxAs ["SISMEMBER", k, v]
  hdel k fs = submitMuxAs ("HDEL" : k : fs)
  hkeys k = submitMuxAs ["HKEYS", k]
  hvals k = submitMuxAs ["HVALS", k]
  llen k = submitMuxAs ["LLEN", k]
  lindex k idx = submitMuxAs ["LINDEX", k, showBS idx]
  clientSetInfo args = submitMuxAs (["CLIENT", "SETINFO"] ++ args)
  clusterSlots = submitMuxAs ["CLUSTER", "SLOTS"]

  clientReply val = do
    case val of
      ON -> do
        resp <- submitMux ["CLIENT", "REPLY", showBS val]
        return (Just resp)
      -- OFF/SKIP: Redis does not send a response, which would desync the
      -- multiplexer. These are inherently incompatible with pipelined
      -- multiplexing, so we silently ignore them.
      _ -> return Nothing

  zadd k members =
    let payload = concatMap (\(score, member) -> [showBS score, member]) members
    in submitMuxAs ("ZADD" : k : payload)

  zrange k start stop withScores =
    let base = ["ZRANGE", k, showBS start, showBS stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in submitMuxAs command

  geoadd k entries =
    let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
    in submitMuxAs ("GEOADD" : k : payload)

  geodist k m1 m2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in submitMuxAs (["GEODIST", k, m1, m2] ++ unitPart)

  geohash k members = submitMuxAs ("GEOHASH" : k : members)
  geopos k members = submitMuxAs ("GEOPOS" : k : members)

  georadius k lon lat radius unit flags =
    let base = ["GEORADIUS", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in submitMuxAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusRo k lon lat radius unit flags =
    let base = ["GEORADIUS_RO", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in submitMuxAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMember k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", k, member, showBS radius, geoUnitKeyword unit]
    in submitMuxAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMemberRo k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", k, member, showBS radius, geoUnitKeyword unit]
    in submitMuxAs (base ++ concatMap geoRadiusFlagToList flags)

  geosearch k fromSpec bySpec options =
    submitMuxAs (["GEOSEARCH", k]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)

  geosearchstore dest src fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, src]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in submitMuxAs command
