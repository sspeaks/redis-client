{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Standalone multiplexed Redis client.
--
-- Wraps a single 'Multiplexer' for standalone (non-cluster) Redis, providing
-- pipelined throughput without cluster mode. Implements 'RedisCommands' so all
-- existing commands work transparently.
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   client <- createStandaloneClient clusterPlaintextConnector (NodeAddress \"localhost\" 6379)
--   runStandaloneClient client $ do
--     set \"key\" \"value\"
--     result <- get \"key\"
--     ...
--   closeStandaloneClient client
-- @
module StandaloneClient
  ( -- * Client type
    StandaloneClient
  , StandaloneCommandClient
    -- * Lifecycle
  , createStandaloneClient
  , closeStandaloneClient
    -- * Running commands
  , runStandaloneClient
  ) where

import           Client                      (Client (..))
import           Cluster                     (NodeAddress (..))
import           Connector                   (Connector)
import           Control.Exception           (SomeException, catch)
import           Control.Monad.IO.Class      (MonadIO (..))
import qualified Control.Monad.State         as State
import           Data.ByteString             (ByteString)
import           Multiplexer                 (Multiplexer, SlotPool,
                                              createMultiplexer, createSlotPool,
                                              destroyMultiplexer,
                                              submitCommandPooled)
import           RedisCommandClient          (RedisCommands (..),
                                              encodeCommandBuilder, showBS,
                                              geoUnitKeyword, geoRadiusFlagToList,
                                              geoSearchFromToList, geoSearchByToList,
                                              geoSearchOptionToList,
                                              ClientReplyValues (..))
import           Resp                        (RespData)

-- | A standalone multiplexed Redis client. Holds a single Multiplexer
-- connected to one Redis node, plus a SlotPool for ResponseSlot reuse.
data StandaloneClient = StandaloneClient
  { standaloneMultiplexer :: !Multiplexer
  , standaloneSlotPool    :: !SlotPool
  }

-- | Create a standalone multiplexed client by connecting to a single Redis node.
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

-- | Close the standalone client, destroying the underlying multiplexer.
closeStandaloneClient :: StandaloneClient -> IO ()
closeStandaloneClient client =
  destroyMultiplexer (standaloneMultiplexer client)
    `catch` \(_ :: SomeException) -> return ()

-- | Monad for executing Redis commands on a standalone multiplexed client.
data StandaloneCommandClient a where
  StandaloneCommandClient ::
    State.StateT StandaloneClient IO a
    -> StandaloneCommandClient a

-- | Run Redis commands against the standalone multiplexed client.
runStandaloneClient :: StandaloneClient -> StandaloneCommandClient a -> IO a
runStandaloneClient client (StandaloneCommandClient action) =
  State.evalStateT action client

instance Functor StandaloneCommandClient where
  fmap f (StandaloneCommandClient s) = StandaloneCommandClient (fmap f s)

instance Applicative StandaloneCommandClient where
  pure = StandaloneCommandClient . pure
  StandaloneCommandClient f <*> StandaloneCommandClient s = StandaloneCommandClient (f <*> s)

instance Monad StandaloneCommandClient where
  StandaloneCommandClient s >>= f = StandaloneCommandClient (s >>= \a -> let StandaloneCommandClient s' = f a in s')

instance MonadIO StandaloneCommandClient where
  liftIO = StandaloneCommandClient . liftIO

instance MonadFail StandaloneCommandClient where
  fail = StandaloneCommandClient . liftIO . Prelude.fail

-- | Submit a pre-encoded command to the multiplexer.
submitMux :: [ByteString] -> StandaloneCommandClient RespData
submitMux args = do
  client <- StandaloneCommandClient State.get
  let cmdBuilder = encodeCommandBuilder args
  liftIO $ submitCommandPooled (standaloneSlotPool client) (standaloneMultiplexer client) cmdBuilder

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
