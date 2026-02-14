{-# LANGUAGE OverloadedStrings #-}

-- | Standalone multiplexed Redis client.
--
-- Wraps a single 'Multiplexer' for standalone (non-cluster) Redis, providing
-- pipelined throughput without cluster mode. Implements 'RedisCommands' so all
-- existing commands work transparently.
--
-- Use 'StandaloneConfig' to control multiplexing behaviour:
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   let config = StandaloneConfig
--         { standaloneNodeAddress     = NodeAddress \"localhost\" 6379
--         , standaloneConnector       = clusterPlaintextConnector
--         , standaloneMultiplexerCount = 1
--         }
--   client <- createStandaloneClientFromConfig config
--   runStandaloneClient client $ do
--     set \"key\" \"value\"
--     result <- get \"key\"
--     ...
--   closeStandaloneClient client
-- @
module StandaloneClient
  ( -- * Configuration
    StandaloneConfig (..)
    -- * Client type
  , StandaloneClient
  , StandaloneCommandClient
    -- * Lifecycle
  , createStandaloneClient
  , createStandaloneClientFromConfig
  , closeStandaloneClient
    -- * Running commands
  , runStandaloneClient
  ) where

import           Client                 (Client (..))
import           Cluster                (NodeAddress (..))
import           Connector              (Connector)
import           Control.Exception      (SomeException, catch)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader   (ReaderT, ask, runReaderT)
import           Data.ByteString        (ByteString)
import           Multiplexer            (Multiplexer, SlotPool,
                                         createMultiplexer, createSlotPool,
                                         destroyMultiplexer,
                                         submitCommandPooled)
import           RedisCommandClient     (ClientReplyValues (..),
                                         RedisCommands (..),
                                         encodeCommandBuilder,
                                         geoRadiusFlagToList, geoSearchByToList,
                                         geoSearchFromToList,
                                         geoSearchOptionToList, geoUnitKeyword,
                                         showBS)
import           Resp                   (RespData)


-- | Configuration for a standalone Redis client.
data StandaloneConfig client = StandaloneConfig
  { standaloneNodeAddress      :: !NodeAddress       -- ^ Redis node to connect to.
  , standaloneConnector        :: !(Connector client) -- ^ Connection factory (plaintext or TLS).
  , standaloneMultiplexerCount :: !Int                -- ^ Number of multiplexers to create (default: 1).
  }

-- | A standalone Redis client backed by a multiplexer and slot pool.
data StandaloneClient = StandaloneClient
  { standaloneMux  :: !Multiplexer
  , standalonePool :: !SlotPool
  }

-- | Create a standalone multiplexed client by connecting to a single Redis node.
-- This is the simple API; for more control, use 'createStandaloneClientFromConfig'.
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
closeStandaloneClient :: StandaloneClient -> IO ()
closeStandaloneClient client =
  destroyMultiplexer (standaloneMux client)
    `catch` \(_ :: SomeException) -> return ()

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

instance RedisCommands StandaloneCommandClient where
  auth username password = submitMux ["HELLO", "3", "AUTH", username, password]
  ping = submitMux ["PING"]
  set k v = submitMux ["SET", k, v]
  get k = submitMux ["GET", k]
  mget keys = submitMux ("MGET" : keys)
  setnx k v = submitMux ["SETNX", k, v]
  decr k = submitMux ["DECR", k]
  psetex k ms v = submitMux ["PSETEX", k, showBS ms, v]
  bulkSet kvs = submitMux (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs)
  flushAll = submitMux ["FLUSHALL"]
  dbsize = submitMux ["DBSIZE"]
  del keys = submitMux ("DEL" : keys)
  exists keys = submitMux ("EXISTS" : keys)
  incr k = submitMux ["INCR", k]
  hset k f v = submitMux ["HSET", k, f, v]
  hget k f = submitMux ["HGET", k, f]
  hmget k fs = submitMux ("HMGET" : k : fs)
  hexists k f = submitMux ["HEXISTS", k, f]
  lpush k vs = submitMux ("LPUSH" : k : vs)
  lrange k start stop = submitMux ["LRANGE", k, showBS start, showBS stop]
  expire k secs = submitMux ["EXPIRE", k, showBS secs]
  ttl k = submitMux ["TTL", k]
  rpush k vs = submitMux ("RPUSH" : k : vs)
  lpop k = submitMux ["LPOP", k]
  rpop k = submitMux ["RPOP", k]
  sadd k vs = submitMux ("SADD" : k : vs)
  smembers k = submitMux ["SMEMBERS", k]
  scard k = submitMux ["SCARD", k]
  sismember k v = submitMux ["SISMEMBER", k, v]
  hdel k fs = submitMux ("HDEL" : k : fs)
  hkeys k = submitMux ["HKEYS", k]
  hvals k = submitMux ["HVALS", k]
  llen k = submitMux ["LLEN", k]
  lindex k idx = submitMux ["LINDEX", k, showBS idx]
  clientSetInfo args = submitMux (["CLIENT", "SETINFO"] ++ args)
  clusterSlots = submitMux ["CLUSTER", "SLOTS"]

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
    in submitMux ("ZADD" : k : payload)

  zrange k start stop withScores =
    let base = ["ZRANGE", k, showBS start, showBS stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in submitMux command

  geoadd k entries =
    let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
    in submitMux ("GEOADD" : k : payload)

  geodist k m1 m2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in submitMux (["GEODIST", k, m1, m2] ++ unitPart)

  geohash k members = submitMux ("GEOHASH" : k : members)
  geopos k members = submitMux ("GEOPOS" : k : members)

  georadius k lon lat radius unit flags =
    let base = ["GEORADIUS", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in submitMux (base ++ concatMap geoRadiusFlagToList flags)

  georadiusRo k lon lat radius unit flags =
    let base = ["GEORADIUS_RO", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in submitMux (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMember k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", k, member, showBS radius, geoUnitKeyword unit]
    in submitMux (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMemberRo k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", k, member, showBS radius, geoUnitKeyword unit]
    in submitMux (base ++ concatMap geoRadiusFlagToList flags)

  geosearch k fromSpec bySpec options =
    submitMux (["GEOSEARCH", k]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)

  geosearchstore dest src fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, src]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in submitMux command
