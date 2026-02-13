{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
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
--         , standaloneUseMultiplexing = True
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

import           Client                      (Client (..))
import           Cluster                     (NodeAddress (..))
import           Connector                   (Connector)
import           Control.Exception           (SomeException, catch)
import           Control.Monad.IO.Class      (MonadIO (..))
import qualified Control.Monad.State         as State
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Char8       as BS8
import           Data.IORef                  (IORef, newIORef, readIORef,
                                              writeIORef)
import           Multiplexer                 (Multiplexer, SlotPool,
                                              createMultiplexer, createSlotPool,
                                              destroyMultiplexer,
                                              submitCommandPooled)
import           RedisCommandClient          (RedisCommands (..),
                                              ClientState (..),
                                              encodeCommandBuilder, showBS,
                                              geoUnitKeyword, geoRadiusFlagToList,
                                              geoSearchFromToList, geoSearchByToList,
                                              geoSearchOptionToList,
                                              ClientReplyValues (..),
                                              parseWith, wrapInRay)
import           Resp                        (RespData, Encodable (..))
import qualified Data.ByteString.Builder     as Builder

-- | Configuration for a standalone Redis client.
data StandaloneConfig client = StandaloneConfig
  { standaloneNodeAddress      :: !NodeAddress       -- ^ Redis node to connect to.
  , standaloneConnector        :: !(Connector client) -- ^ Connection factory (plaintext or TLS).
  , standaloneMultiplexerCount :: !Int                -- ^ Number of multiplexers to create (default: 1).
  , standaloneUseMultiplexing  :: !Bool               -- ^ Use multiplexed pipelining (default: True). When False, falls back to 'RedisCommandClient' behaviour.
  }

-- | Backend for the standalone client: either multiplexed or direct.
data StandaloneBackend where
  -- | Multiplexed backend using a 'Multiplexer' and 'SlotPool'.
  MuxBackend :: !Multiplexer -> !SlotPool -> StandaloneBackend
  -- | Direct (non-multiplexed) backend using 'RedisCommandClient'-style
  -- sequential command execution over a single connection.
  DirectBackend :: (Client client) => !(IORef (ClientState client)) -> StandaloneBackend

-- | A standalone Redis client. Holds either a multiplexed backend (default)
-- or a direct connection backend when multiplexing is disabled.
newtype StandaloneClient = StandaloneClient
  { standaloneBackend :: StandaloneBackend
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
  return $ StandaloneClient (MuxBackend mux pool)

-- | Create a standalone client from a 'StandaloneConfig'.
-- When 'standaloneUseMultiplexing' is True (the default), creates a multiplexed
-- backend. When False, falls back to direct 'RedisCommandClient' behaviour.
createStandaloneClientFromConfig
  :: (Client client)
  => StandaloneConfig client
  -> IO StandaloneClient
createStandaloneClientFromConfig config
  | standaloneUseMultiplexing config = do
      conn <- standaloneConnector config (standaloneNodeAddress config)
      mux <- createMultiplexer conn (receive conn)
      pool <- createSlotPool 256
      return $ StandaloneClient (MuxBackend mux pool)
  | otherwise = do
      conn <- standaloneConnector config (standaloneNodeAddress config)
      ref <- newIORef (ClientState conn BS8.empty)
      return $ StandaloneClient (DirectBackend ref)

-- | Close the standalone client, destroying the underlying multiplexer
-- or closing the direct connection.
closeStandaloneClient :: StandaloneClient -> IO ()
closeStandaloneClient client =
  case standaloneBackend client of
    MuxBackend mux _ ->
      destroyMultiplexer mux
        `catch` \(_ :: SomeException) -> return ()
    DirectBackend ref -> do
      ClientState conn _ <- readIORef ref
      close conn
        `catch` \(_ :: SomeException) -> return ()

-- | Monad for executing Redis commands on a standalone client.
data StandaloneCommandClient a where
  StandaloneCommandClient ::
    State.StateT StandaloneClient IO a
    -> StandaloneCommandClient a

-- | Run Redis commands against the standalone client.
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

-- | Submit a command via whichever backend is active.
submitMux :: [ByteString] -> StandaloneCommandClient RespData
submitMux args = do
  client <- StandaloneCommandClient State.get
  case standaloneBackend client of
    MuxBackend mux pool -> do
      let cmdBuilder = encodeCommandBuilder args
      liftIO $ submitCommandPooled pool mux cmdBuilder
    DirectBackend ref -> liftIO $ do
      st <- readIORef ref
      executeDirect ref st args

-- | Execute a command on the direct (non-multiplexed) backend by sending the
-- RESP-encoded command and parsing the response, then updating the shared state.
executeDirect :: (Client client) => IORef (ClientState client) -> ClientState client -> [ByteString] -> IO RespData
executeDirect ref (ClientState conn buf) args = do
  send conn (Builder.toLazyByteString . encode $ wrapInRay args)
  (result, st') <- State.runStateT (parseWith (liftIO $ receive conn)) (ClientState conn buf)
  writeIORef ref st'
  return result

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
