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
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- main :: IO ()
-- main =
--   withStandaloneClient defaultStandaloneConfig $ \\client -> do
--     result <- runStandaloneClient client $ do
--       (_ :: Bool) <- set \"key\" \"value\"
--       get \"key\"
--     print (result :: Either RedisClientError ByteString)
-- @
--
-- @since 0.1.0.0
module Database.Redis.Standalone
  ( -- * Configuration
    StandaloneConfig (..)
  , StandaloneConfigException (..)
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

import           Control.Concurrent.MVar             (MVar, newMVar, withMVar)
import           Control.Exception                   (Exception,
                                                      SomeAsyncException,
                                                      SomeException, bracket,
                                                      fromException, mask,
                                                      mask_, onException, throwIO,
                                                      toException, try)
import           Control.Monad.IO.Class              (MonadIO (..))
import           Control.Monad.Reader                (ReaderT, ask, runReaderT)
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString                     as BS
import           Data.IORef                          (IORef, atomicModifyIORef',
                                                      newIORef)
import           Data.Typeable                       (Typeable)
import           Data.Vector                         (Vector)
import qualified Data.Vector                         as V
import           Database.Redis.Client               (Client, PlainTextClient)
import           Database.Redis.Cluster              (NodeAddress (..))
import           Database.Redis.Command              (ClientReplyModeUnsupported (..),
                                                      ClientReplyValues (..),
                                                      CommandDescriptor,
                                                      RedisCommands (..),
                                                      commandDescriptorFrame,
                                                      convertResp,
                                                      definedAppend,
                                                      definedAuth,
                                                      definedBulkSet,
                                                      definedClientReplyOn,
                                                      definedClientSetInfo,
                                                      definedClusterSlots,
                                                      definedDbsize,
                                                      definedDecr,
                                                      definedDecrby, definedDel,
                                                      definedExists,
                                                      definedExpire,
                                                      definedFlushAll,
                                                      definedGeoadd,
                                                      definedGeodist,
                                                      definedGeohash,
                                                      definedGeopos,
                                                      definedGeoradius,
                                                      definedGeoradiusByMember,
                                                      definedGeoradiusByMemberRo,
                                                      definedGeoradiusRo,
                                                      definedGeosearch,
                                                      definedGeosearchstore,
                                                      definedGet, definedGetdel,
                                                      definedGetex, definedHdel,
                                                      definedHexists,
                                                      definedHget,
                                                      definedHgetall,
                                                      definedHincrby,
                                                      definedHincrbyfloat,
                                                      definedHkeys, definedHlen,
                                                      definedHmget, definedHset,
                                                      definedHsetnx,
                                                      definedHvals, definedIncr,
                                                      definedIncrby,
                                                      definedIncrbyfloat,
                                                      definedKeyType,
                                                      definedLindex,
                                                      definedLinsert,
                                                      definedLlen, definedLpop,
                                                      definedLpush,
                                                      definedLrange,
                                                      definedLrem, definedLset,
                                                      definedLtrim, definedMget,
                                                      definedPersist,
                                                      definedPfadd,
                                                      definedPfcount,
                                                      definedPfmerge,
                                                      definedPing,
                                                      definedPsetex,
                                                      definedRename,
                                                      definedRenamenx,
                                                      definedRpop, definedRpush,
                                                      definedSadd, definedScard,
                                                      definedSdiff, definedSet,
                                                      definedSetex,
                                                      definedSetnx,
                                                      definedSinter,
                                                      definedSismember,
                                                      definedSmembers,
                                                      definedSpop,
                                                      definedSrandmember,
                                                      definedSrem,
                                                      definedStrlen,
                                                      definedSunion, definedTtl,
                                                      definedUnlink,
                                                      definedZadd, definedZcard,
                                                      definedZcount,
                                                      definedZincrby,
                                                      definedZrange,
                                                      definedZrangestore,
                                                      definedZrank, definedZrem,
                                                      definedZrevrank,
                                                      definedZscore,
                                                      encodeCommandBuilder,
                                                      redisCommandDefinitions)
import           Database.Redis.Connector            (Connector,
                                                      clusterPlaintextConnector)
import           Database.Redis.FromResp             (FromResp (..))
import           Database.Redis.Internal.Multiplexer (Multiplexer,
                                                      MultiplexerException (..),
                                                      SlotPool,
                                                      createMultiplexerFromConnector,
                                                      createSlotPool,
                                                      destroyMultiplexer,
                                                      submitCommandPooled)
import           Database.Redis.RedisError           (RedisClientError (..),
                                                      RedisLifecycleFailure (..),
                                                      RedisProtocolFailure (..),
                                                      tryRedisClient)
import           Database.Redis.Resp                 (RespData)


-- | Configuration for a standalone Redis client.
data StandaloneConfig client = StandaloneConfig
  { standaloneNodeAddress      :: !NodeAddress       -- ^ Redis node to connect to.
  , standaloneConnector        :: !(Connector client) -- ^ Connection factory (plaintext or TLS).
  , standaloneMultiplexerCount :: !Int                -- ^ Number of multiplexers to create (default: 1).
  }

-- | Invalid standalone client configuration.
newtype StandaloneConfigException
  = InvalidStandaloneMultiplexerCount Int
  deriving (Eq, Show, Typeable)

instance Exception StandaloneConfigException

-- | Default configuration connecting to @localhost:6379@ over plaintext with 1 multiplexer.
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- defaultExample :: IO (Either RedisClientError ByteString)
-- defaultExample =
--   runRedis defaultStandaloneConfig $ do
--     (_ :: Bool) <- set \"key\" \"value\"
--     get \"key\"
-- @
defaultStandaloneConfig :: StandaloneConfig PlainTextClient
defaultStandaloneConfig = StandaloneConfig
  { standaloneNodeAddress      = NodeAddress "localhost" 6379
  , standaloneConnector        = clusterPlaintextConnector
  , standaloneMultiplexerCount = 1
  }

-- | A standalone Redis client backed by round-robin multiplexers and a shared
-- response-slot pool.
data StandaloneClient = StandaloneClient
  { standaloneMuxes     :: !(Vector Multiplexer)
  , standaloneLifecycle :: !(IORef StandaloneLifecycle)
  , standaloneCloseLock :: !(MVar ())
  , standalonePool      :: !SlotPool
  }

data StandaloneLifecycle
  = StandaloneOpen !Int
  | StandaloneClosing !Int
  | StandaloneClosed !Int

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
  createStandaloneClientFromConfig StandaloneConfig
    { standaloneNodeAddress = addr
    , standaloneConnector = connector
    , standaloneMultiplexerCount = 1
    }

-- | Create a standalone client from a 'StandaloneConfig'.
createStandaloneClientFromConfig
  :: (Client client)
  => StandaloneConfig client
  -> IO StandaloneClient
createStandaloneClientFromConfig config
  | count <= 0 = throwIO $ InvalidStandaloneMultiplexerCount count
  | otherwise = mask $ \restore -> do
      muxes <- createMuxes restore [] count
      lifecycle <- newIORef (StandaloneOpen 0)
        `onException` closeStandaloneMuxes muxes
      closeLock <- newMVar ()
        `onException` closeStandaloneMuxes muxes
      pool <- createSlotPool 256
        `onException` closeStandaloneMuxes muxes
      return $ StandaloneClient
        (V.fromList $ reverse muxes)
        lifecycle
        closeLock
        pool
  where
    count = standaloneMultiplexerCount config
    createMuxes _ acc 0 = return acc
    createMuxes restore acc remaining = do
      mux <- restore (createMultiplexerFromConnector
        (standaloneConnector config) (standaloneNodeAddress config))
        `onException` closeStandaloneMuxes acc
      createMuxes restore (mux : acc) (remaining - 1)

-- | Close the standalone client, atomically disabling routing before
-- destroying its multiplexers. Owned plaintext or TLS transports are closed
-- exactly once. Closure is terminal and idempotent; later commands fail with
-- 'MultiplexerDead' instead of routing to a mux that has not yet been destroyed.
-- An interrupted close can be resumed by calling this function again.
--
-- Consider using 'withStandaloneClient' instead for automatic cleanup.
closeStandaloneClient :: StandaloneClient -> IO ()
closeStandaloneClient client = mask_ $
  withMVar (standaloneCloseLock client) $ \() -> do
    lifecycle <- atomicModifyIORef' (standaloneLifecycle client) $ \current ->
      case current of
        StandaloneOpen index ->
          (StandaloneClosing index, current)
        _ ->
          (current, current)
    case lifecycle of
      StandaloneClosed _ -> return ()
      _ -> do
        closeStandaloneMuxes $ V.toList $ standaloneMuxes client
        atomicModifyIORef' (standaloneLifecycle client) $ \current ->
          case current of
            StandaloneClosing index ->
              (StandaloneClosed index, ())
            _ ->
              (current, ())

closeStandaloneMuxes :: [Multiplexer] -> IO ()
closeStandaloneMuxes muxes = do
  results <- mapM tryDestroy muxes
  case
    [ asyncException
    | Left failure <- results
    , Just asyncException <- [fromException failure :: Maybe SomeAsyncException]
    ] of
    asyncException : _ -> throwIO asyncException
    []                 -> return ()
  where
    tryDestroy mux =
      try (destroyMultiplexer mux) :: IO (Either SomeException ())

-- | Bracket-style resource management for standalone clients.
--
-- Creates a client, runs the given action, and ensures the client is closed
-- even if an exception occurs. Prefer this over manual 'createStandaloneClientFromConfig'
-- and 'closeStandaloneClient'. After the callback returns, the client and its
-- transport are permanently closed.
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- bracketExample :: IO (Either RedisClientError ByteString)
-- bracketExample =
--   withStandaloneClient defaultStandaloneConfig $ \\client ->
--     runStandaloneClient client $ do
--       (_ :: Bool) <- set \"key\" \"value\"
--       get \"key\"
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
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
--
-- import Database.Redis
--
-- runRedisExample :: IO (Either RedisClientError ByteString)
-- runRedisExample =
--   runRedis defaultStandaloneConfig $ do
--     (_ :: Bool) <- set \"key\" \"value\"
--     get \"key\"
-- @
runRedis
  :: (Client client)
  => StandaloneConfig client
  -> StandaloneCommandClient a
  -> IO (Either RedisClientError a)
runRedis config action = mask $ \restore -> do
  created <- try $ restore $ createStandaloneClientFromConfig config
  case created of
    Left (setupFailure :: SomeException) ->
      rethrowAsyncOr $ RedisLifecycleError $ RedisSetupFailure setupFailure
    Right client -> do
      outcome <- try $ restore $ runReaderT
        (unStandaloneCommandClient action) client
      cleanup <- try $ closeStandaloneClient client
      case outcome of
        Left (failure :: SomeException) ->
          case fromException failure of
            Just async -> throwIO (async :: SomeAsyncException)
            Nothing ->
              let primary = exceptionToClientError failure
              in case cleanup of
                Right () -> pure $ Left primary
                Left cleanupFailure ->
                  rethrowAsyncOr $ RedisLifecycleError $
                    RedisActionCleanupFailure primary cleanupFailure
        Right value ->
          case cleanup of
            Right () -> pure $ Right value
            Left cleanupFailure ->
              rethrowAsyncOr $ RedisLifecycleError $
                RedisCleanupFailure cleanupFailure

-- | Monad for executing Redis commands on a standalone client.
newtype StandaloneCommandClient a = StandaloneCommandClient
  { unStandaloneCommandClient :: ReaderT StandaloneClient IO a }

-- | Run Redis commands against the standalone client.
runStandaloneClient
  :: StandaloneClient
  -> StandaloneCommandClient a
  -> IO (Either RedisClientError a)
runStandaloneClient client (StandaloneCommandClient action) = do
  result <- tryRedisClient $ runReaderT action client
  pure $ case result of
    Left (RedisTransportError cause)
      | Just (MultiplexerDead _) <- fromException cause ->
          Left $ RedisLifecycleError RedisClientClosed
      | Just (MultiplexerParseError message) <- fromException cause ->
          Left $ RedisProtocolError $ RedisParseFailure message
      | Just MultiplexerConnectionClosed <- fromException cause ->
          Left $ RedisProtocolError RedisConnectionClosed
    _ -> result

exceptionToClientError :: SomeException -> RedisClientError
exceptionToClientError exception =
  case fromException exception of
    Just redisError -> redisError
    Nothing         -> RedisTransportError exception

rethrowAsyncOr :: RedisClientError -> IO (Either RedisClientError a)
rethrowAsyncOr redisError =
  case redisError of
    RedisLifecycleError (RedisSetupFailure cause) -> check cause
    RedisLifecycleError (RedisCleanupFailure cause) -> check cause
    RedisLifecycleError (RedisActionCleanupFailure _ cause) -> check cause
    _ -> pure $ Left redisError
  where
    check cause =
      case fromException cause of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing    -> pure $ Left redisError

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
  mux <- liftIO $ nextStandaloneMux client
  liftIO $ submitCommandPooled (standalonePool client) mux cmdBuilder

nextStandaloneMux :: StandaloneClient -> IO Multiplexer
nextStandaloneMux client = do
  -- Selection and the close transition share one atomic lifecycle update.
  selection <- atomicModifyIORef' (standaloneLifecycle client) $ \lifecycle ->
    case lifecycle of
      StandaloneOpen index ->
        (StandaloneOpen $ index + 1, Right index)
      _ ->
        (lifecycle, Left $ MultiplexerDead "Standalone client closed")
  case selection of
    Left failure -> throwIO failure
    Right index ->
      return $! muxes `V.unsafeIndex` (index `mod` V.length muxes)
  where
    muxes = standaloneMuxes client

-- | Submit a command and convert the result via 'FromResp'.
submitMuxAs :: (FromResp a) => [ByteString] -> StandaloneCommandClient a
submitMuxAs args = submitMux args >>= convertResp

submitMuxDescriptorAs :: (FromResp a) => CommandDescriptor -> StandaloneCommandClient a
submitMuxDescriptorAs =
  submitMuxAs . commandDescriptorFrame

instance RedisCommands StandaloneCommandClient where
  auth username password =
    submitMuxDescriptorAs (definedAuth redisCommandDefinitions username password)
  ping =
    submitMuxDescriptorAs (definedPing redisCommandDefinitions)
  set key value =
    submitMuxDescriptorAs (definedSet redisCommandDefinitions key value)
  get key =
    submitMuxDescriptorAs (definedGet redisCommandDefinitions key)
  mget keys =
    submitMuxDescriptorAs (definedMget redisCommandDefinitions keys)
  setnx key value =
    submitMuxDescriptorAs (definedSetnx redisCommandDefinitions key value)
  decr key =
    submitMuxDescriptorAs (definedDecr redisCommandDefinitions key)
  append key value =
    submitMuxDescriptorAs (definedAppend redisCommandDefinitions key value)
  strlen key =
    submitMuxDescriptorAs (definedStrlen redisCommandDefinitions key)
  setex key seconds value =
    submitMuxDescriptorAs (definedSetex redisCommandDefinitions key seconds value)
  incrby key amount =
    submitMuxDescriptorAs (definedIncrby redisCommandDefinitions key amount)
  decrby key amount =
    submitMuxDescriptorAs (definedDecrby redisCommandDefinitions key amount)
  incrbyfloat key amount =
    submitMuxDescriptorAs (definedIncrbyfloat redisCommandDefinitions key amount)
  getdel key =
    submitMuxDescriptorAs (definedGetdel redisCommandDefinitions key)
  getex key opts =
    submitMuxDescriptorAs (definedGetex redisCommandDefinitions key opts)
  psetex key milliseconds value =
    submitMuxDescriptorAs (definedPsetex redisCommandDefinitions key milliseconds value)
  bulkSet pairs =
    submitMuxDescriptorAs (definedBulkSet redisCommandDefinitions pairs)
  flushAll =
    submitMuxDescriptorAs (definedFlushAll redisCommandDefinitions)
  dbsize =
    submitMuxDescriptorAs (definedDbsize redisCommandDefinitions)
  del keys =
    submitMuxDescriptorAs (definedDel redisCommandDefinitions keys)
  exists keys =
    submitMuxDescriptorAs (definedExists redisCommandDefinitions keys)
  incr key =
    submitMuxDescriptorAs (definedIncr redisCommandDefinitions key)
  hset key field value =
    submitMuxDescriptorAs (definedHset redisCommandDefinitions key field value)
  hget key field =
    submitMuxDescriptorAs (definedHget redisCommandDefinitions key field)
  hmget key fields =
    submitMuxDescriptorAs (definedHmget redisCommandDefinitions key fields)
  hexists key field =
    submitMuxDescriptorAs (definedHexists redisCommandDefinitions key field)
  lpush key values =
    submitMuxDescriptorAs (definedLpush redisCommandDefinitions key values)
  lrange key start stop =
    submitMuxDescriptorAs (definedLrange redisCommandDefinitions key start stop)
  expire key seconds =
    submitMuxDescriptorAs (definedExpire redisCommandDefinitions key seconds)
  ttl key =
    submitMuxDescriptorAs (definedTtl redisCommandDefinitions key)
  persist key =
    submitMuxDescriptorAs (definedPersist redisCommandDefinitions key)
  keyType key =
    submitMuxDescriptorAs (definedKeyType redisCommandDefinitions key)
  rename key newkey =
    submitMuxDescriptorAs (definedRename redisCommandDefinitions key newkey)
  renamenx key newkey =
    submitMuxDescriptorAs (definedRenamenx redisCommandDefinitions key newkey)
  unlink keys =
    submitMuxDescriptorAs (definedUnlink redisCommandDefinitions keys)
  pfadd key elements =
    submitMuxDescriptorAs (definedPfadd redisCommandDefinitions key elements)
  pfcount keys =
    submitMuxDescriptorAs (definedPfcount redisCommandDefinitions keys)
  pfmerge destkey sourcekeys =
    submitMuxDescriptorAs (definedPfmerge redisCommandDefinitions destkey sourcekeys)
  rpush key values =
    submitMuxDescriptorAs (definedRpush redisCommandDefinitions key values)
  lpop key =
    submitMuxDescriptorAs (definedLpop redisCommandDefinitions key)
  rpop key =
    submitMuxDescriptorAs (definedRpop redisCommandDefinitions key)
  sadd key members =
    submitMuxDescriptorAs (definedSadd redisCommandDefinitions key members)
  smembers key =
    submitMuxDescriptorAs (definedSmembers redisCommandDefinitions key)
  scard key =
    submitMuxDescriptorAs (definedScard redisCommandDefinitions key)
  sismember key member =
    submitMuxDescriptorAs (definedSismember redisCommandDefinitions key member)
  srem key members =
    submitMuxDescriptorAs (definedSrem redisCommandDefinitions key members)
  sdiff keys =
    submitMuxDescriptorAs (definedSdiff redisCommandDefinitions keys)
  sinter keys =
    submitMuxDescriptorAs (definedSinter redisCommandDefinitions keys)
  sunion keys =
    submitMuxDescriptorAs (definedSunion redisCommandDefinitions keys)
  spop key =
    submitMuxDescriptorAs (definedSpop redisCommandDefinitions key)
  srandmember key =
    submitMuxDescriptorAs (definedSrandmember redisCommandDefinitions key)
  hdel key fields =
    submitMuxDescriptorAs (definedHdel redisCommandDefinitions key fields)
  hkeys key =
    submitMuxDescriptorAs (definedHkeys redisCommandDefinitions key)
  hvals key =
    submitMuxDescriptorAs (definedHvals redisCommandDefinitions key)
  hgetall key =
    submitMuxDescriptorAs (definedHgetall redisCommandDefinitions key)
  hlen key =
    submitMuxDescriptorAs (definedHlen redisCommandDefinitions key)
  hsetnx key field value =
    submitMuxDescriptorAs (definedHsetnx redisCommandDefinitions key field value)
  hincrby key field amount =
    submitMuxDescriptorAs (definedHincrby redisCommandDefinitions key field amount)
  hincrbyfloat key field amount =
    submitMuxDescriptorAs (definedHincrbyfloat redisCommandDefinitions key field amount)
  llen key =
    submitMuxDescriptorAs (definedLlen redisCommandDefinitions key)
  lindex key index =
    submitMuxDescriptorAs (definedLindex redisCommandDefinitions key index)
  linsert key pos pivot element =
    submitMuxDescriptorAs (definedLinsert redisCommandDefinitions key pos pivot element)
  lset key index element =
    submitMuxDescriptorAs (definedLset redisCommandDefinitions key index element)
  ltrim key start stop =
    submitMuxDescriptorAs (definedLtrim redisCommandDefinitions key start stop)
  lrem key count element =
    submitMuxDescriptorAs (definedLrem redisCommandDefinitions key count element)
  clientSetInfo args =
    submitMuxDescriptorAs (definedClientSetInfo redisCommandDefinitions args)
  clusterSlots =
    submitMuxDescriptorAs (definedClusterSlots redisCommandDefinitions)

  clientReply ON =
    Just <$> submitMux
      (commandDescriptorFrame $ definedClientReplyOn redisCommandDefinitions)
  clientReply val =
    liftIO $ throwIO $ RedisLifecycleError $
      RedisUnsupportedOperation $ toException $ ClientReplyModeUnsupported val
  zadd key members =
    submitMuxDescriptorAs (definedZadd redisCommandDefinitions key members)
  zrange key start stop withScores =
    submitMuxDescriptorAs (definedZrange redisCommandDefinitions key start stop withScores)
  zrem key members =
    submitMuxDescriptorAs (definedZrem redisCommandDefinitions key members)
  zcard key =
    submitMuxDescriptorAs (definedZcard redisCommandDefinitions key)
  zscore key member =
    submitMuxDescriptorAs (definedZscore redisCommandDefinitions key member)
  zrank key member =
    submitMuxDescriptorAs (definedZrank redisCommandDefinitions key member)
  zrevrank key member =
    submitMuxDescriptorAs (definedZrevrank redisCommandDefinitions key member)
  zcount key minScore maxScore =
    submitMuxDescriptorAs (definedZcount redisCommandDefinitions key minScore maxScore)
  zincrby key increment member =
    submitMuxDescriptorAs (definedZincrby redisCommandDefinitions key increment member)
  zrangestore dst src minVal maxVal opts =
    submitMuxDescriptorAs (definedZrangestore redisCommandDefinitions dst src minVal maxVal opts)
  geoadd key entries =
    submitMuxDescriptorAs (definedGeoadd redisCommandDefinitions key entries)
  geodist key member1 member2 unit =
    submitMuxDescriptorAs (definedGeodist redisCommandDefinitions key member1 member2 unit)
  geohash key members =
    submitMuxDescriptorAs (definedGeohash redisCommandDefinitions key members)
  geopos key members =
    submitMuxDescriptorAs (definedGeopos redisCommandDefinitions key members)
  georadius key lon lat radius unit flags =
    submitMuxDescriptorAs
      (definedGeoradius redisCommandDefinitions key lon lat radius unit flags)
  georadiusRo key lon lat radius unit flags =
    submitMuxDescriptorAs
      (definedGeoradiusRo redisCommandDefinitions key lon lat radius unit flags)
  georadiusByMember key member radius unit flags =
    submitMuxDescriptorAs
      (definedGeoradiusByMember redisCommandDefinitions key member radius unit flags)
  georadiusByMemberRo key member radius unit flags =
    submitMuxDescriptorAs
      (definedGeoradiusByMemberRo redisCommandDefinitions key member radius unit flags)
  geosearch key fromSpec bySpec options =
    submitMuxDescriptorAs
      (definedGeosearch redisCommandDefinitions key fromSpec bySpec options)
  geosearchstore dest src fromSpec bySpec options storeDist =
    submitMuxDescriptorAs
      (definedGeosearchstore redisCommandDefinitions dest src fromSpec bySpec options storeDist)
