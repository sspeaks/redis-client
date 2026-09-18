{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

-- | High-level Redis command interface built on top of 'Client'.
--
-- Provides the 'RedisCommands' typeclass with methods for standard Redis commands
-- (strings, hashes, lists, sets, sorted sets, geo), a 'RedisCommandClient' monad
-- that manages connection state and incremental RESP parsing, and typed error handling
-- via 'RedisError'.
--
-- @since 0.1.0.0
module Database.Redis.Command
  ( -- * Core types
    ClientState (..)
  , RedisCommandClient (..)
  , RedisCommands (..)
  , CommandDescriptor (..)
  , CommandRoute (..)
  , RedisCommandDefinitions (..)
  , redisCommandDefinitions
  , ClientReplyValues (..)
  , ClientReplyModeUnsupported (..)
  , ClientReplyUncertainWrite (..)
  , sendCommandWithoutReply
  , sendClientReplySkipAndCommand
  , authenticatePassword
  , authenticateACL
    -- * Errors
  , RedisError (..)
    -- * Geo types
  , GeoUnit (..)
  , GeoRadiusFlag (..)
  , GeoSearchFrom (..)
  , GeoSearchBy (..)
  , GeoSearchOption (..)
    -- * Helpers
  , wrapInRay
  , encodeCommand
  , encodeCommandBuilder
  , encodeSetBuilder
  , encodeGetBuilder
  , executeCommandDescriptor
  , executeCommandDescriptorAs
  , encodeBulkArg
  , showBS
  , geoUnitKeyword
  , geoRadiusFlagToList
  , geoSearchFromToList
  , geoSearchByToList
  , geoSearchOptionToList
    -- * Parsing
  , parseWith
  , parseManyWith
    -- * FromResp conversion
  , convertResp
  ) where

import           Control.Exception                (Exception,
                                                   SomeAsyncException,
                                                   SomeException,
                                                   displayException,
                                                   fromException, mask, throwIO,
                                                   try, uninterruptibleMask_)
import           Control.Monad.IO.Class           (MonadIO (..))
import           Control.Monad.State              as State (MonadState (get, put),
                                                            StateT)
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as BS8
import qualified Data.ByteString.Lazy             as LBS
import           Data.Kind                        (Type)
import           Data.Typeable                    (Typeable)
import           Database.Redis.Client            (Client (..),
                                                   ConnectionStatus (..))
import           Database.Redis.FromResp          (FromResp (..))
import           Database.Redis.RedisError        (RedisError (..))
import           Database.Redis.Resp              (Encodable (encode),
                                                   RespData (..), parseRespData)
import           System.IO                        (hPutStrLn, stderr)


-- | Mutable state carried through a 'RedisCommandClient' session: the live connection
-- and an unparsed RESP byte buffer from previous receives.
data ClientState client = ClientState
  { getClient      :: client 'Connected,
    getParseBuffer :: BS8.ByteString
  }

-- | A monad for sequencing Redis commands over a single connection.
-- Wraps 'StateT' over 'ClientState' to manage the connection handle and
-- an incremental parse buffer, so callers never deal with raw bytes.
data RedisCommandClient client (a :: Type) where
  RedisCommandClient :: (Client client) => {runRedisCommandClient :: State.StateT (ClientState client) IO a} -> RedisCommandClient client a

instance (Client client) => Functor (RedisCommandClient client) where
  fmap :: (a -> b) -> RedisCommandClient client a -> RedisCommandClient client b
  fmap f (RedisCommandClient s) = RedisCommandClient (fmap f s)

instance (Client client) => Applicative (RedisCommandClient client) where
  pure :: a -> RedisCommandClient client a
  pure = RedisCommandClient . pure
  (<*>) :: RedisCommandClient client (a -> b) -> RedisCommandClient client a -> RedisCommandClient client b
  RedisCommandClient f <*> RedisCommandClient s = RedisCommandClient (f <*> s)

instance (Client client) => Monad (RedisCommandClient client) where
  (>>=) :: RedisCommandClient client a -> (a -> RedisCommandClient client b) -> RedisCommandClient client b
  RedisCommandClient s >>= f = RedisCommandClient (s >>= \a -> let RedisCommandClient s' = f a in s')

instance (Client client) => MonadIO (RedisCommandClient client) where
  liftIO :: IO a -> RedisCommandClient client a
  liftIO = RedisCommandClient . liftIO

instance (Client client) => MonadState (ClientState client) (RedisCommandClient client) where
  get :: RedisCommandClient client (ClientState client)
  get = RedisCommandClient State.get
  put :: ClientState client -> RedisCommandClient client ()
  put = RedisCommandClient . State.put

instance (Client client) => MonadFail (RedisCommandClient client) where
  fail :: String -> RedisCommandClient client a
  fail = RedisCommandClient . liftIO . fail

-- | The standard set of Redis commands. Implemented for both single-node
-- ('RedisCommandClient') and cluster ('ClusterCommandClient') monads.
-- Keys and values use strict 'ByteString' to avoid O(n) String conversions.
-- Command return types are polymorphic via 'FromResp', allowing typed results.
class (MonadIO m) => RedisCommands m where
  -- | Authenticate the current standalone physical connection. Cluster
  -- clients reject this operation; use construction-time cluster credentials.
  auth :: (FromResp a) => ByteString -> ByteString -> m a
  ping :: (FromResp a) => m a
  set :: (FromResp a) => ByteString -> ByteString -> m a
  get :: (FromResp a) => ByteString -> m a
  mget :: (FromResp a) => [ByteString] -> m a
  setnx :: (FromResp a) => ByteString -> ByteString -> m a
  decr :: (FromResp a) => ByteString -> m a
  psetex :: (FromResp a) => ByteString -> Int -> ByteString -> m a
  bulkSet :: (FromResp a) => [(ByteString, ByteString)] -> m a
  flushAll :: (FromResp a) => m a
  dbsize :: (FromResp a) => m a
  del :: (FromResp a) => [ByteString] -> m a
  exists :: (FromResp a) => [ByteString] -> m a
  incr :: (FromResp a) => ByteString -> m a
  append :: (FromResp a) => ByteString -> ByteString -> m a
  strlen :: (FromResp a) => ByteString -> m a
  setex :: (FromResp a) => ByteString -> Int -> ByteString -> m a
  incrby :: (FromResp a) => ByteString -> Int -> m a
  decrby :: (FromResp a) => ByteString -> Int -> m a
  incrbyfloat :: (FromResp a) => ByteString -> Double -> m a
  getdel :: (FromResp a) => ByteString -> m a
  getex :: (FromResp a) => ByteString -> [ByteString] -> m a
  hset :: (FromResp a) => ByteString -> ByteString -> ByteString -> m a
  hget :: (FromResp a) => ByteString -> ByteString -> m a
  hmget :: (FromResp a) => ByteString -> [ByteString] -> m a
  hexists :: (FromResp a) => ByteString -> ByteString -> m a
  lpush :: (FromResp a) => ByteString -> [ByteString] -> m a
  lrange :: (FromResp a) => ByteString -> Int -> Int -> m a
  expire :: (FromResp a) => ByteString -> Int -> m a
  ttl :: (FromResp a) => ByteString -> m a
  persist :: (FromResp a) => ByteString -> m a
  keyType :: (FromResp a) => ByteString -> m a
  rename :: (FromResp a) => ByteString -> ByteString -> m a
  renamenx :: (FromResp a) => ByteString -> ByteString -> m a
  unlink :: (FromResp a) => [ByteString] -> m a
  pfadd :: (FromResp a) => ByteString -> [ByteString] -> m a
  pfcount :: (FromResp a) => [ByteString] -> m a
  pfmerge :: (FromResp a) => ByteString -> [ByteString] -> m a
  rpush :: (FromResp a) => ByteString -> [ByteString] -> m a
  lpop :: (FromResp a) => ByteString -> m a
  rpop :: (FromResp a) => ByteString -> m a
  sadd :: (FromResp a) => ByteString -> [ByteString] -> m a
  smembers :: (FromResp a) => ByteString -> m a
  scard :: (FromResp a) => ByteString -> m a
  sismember :: (FromResp a) => ByteString -> ByteString -> m a
  srem :: (FromResp a) => ByteString -> [ByteString] -> m a
  sdiff :: (FromResp a) => [ByteString] -> m a
  sinter :: (FromResp a) => [ByteString] -> m a
  sunion :: (FromResp a) => [ByteString] -> m a
  spop :: (FromResp a) => ByteString -> m a
  srandmember :: (FromResp a) => ByteString -> m a
  hdel :: (FromResp a) => ByteString -> [ByteString] -> m a
  hkeys :: (FromResp a) => ByteString -> m a
  hvals :: (FromResp a) => ByteString -> m a
  hgetall :: (FromResp a) => ByteString -> m a
  hlen :: (FromResp a) => ByteString -> m a
  hsetnx :: (FromResp a) => ByteString -> ByteString -> ByteString -> m a
  hincrby :: (FromResp a) => ByteString -> ByteString -> Int -> m a
  hincrbyfloat :: (FromResp a) => ByteString -> ByteString -> Double -> m a
  llen :: (FromResp a) => ByteString -> m a
  lindex :: (FromResp a) => ByteString -> Int -> m a
  linsert :: (FromResp a) => ByteString -> ByteString -> ByteString -> ByteString -> m a
  lset :: (FromResp a) => ByteString -> Int -> ByteString -> m a
  ltrim :: (FromResp a) => ByteString -> Int -> Int -> m a
  lrem :: (FromResp a) => ByteString -> Int -> ByteString -> m a
  clientSetInfo :: (FromResp a) => [ByteString] -> m a
  -- | Change Redis reply behavior for the current physical connection.
  --
  -- @ON@ returns its server reply. @OFF@ is supported only by a dedicated
  -- sequential 'RedisCommandClient' connection. It sends @CLIENT REPLY OFF@
  -- without reading a reply, so it returns 'Nothing'. While replies are
  -- disabled, every intervening command /must/ use
  -- 'sendCommandWithoutReply' (or an equivalent documented raw no-read
  -- operation); ordinary reply-waiting commands are invalid and may block or
  -- desynchronize the connection. @ON@ uses the normal reply-reading path,
  -- consumes its own @OK@ reply, and restores normal replies for subsequent
  -- commands.
  --
  -- Shared multiplexed and cluster clients synchronously reject @OFF@ and
  -- @SKIP@ with 'ClientReplyModeUnsupported' /before/ connection acquisition,
  -- queueing, bytes sent, slot allocation, or reply-stream/state mutation.
  -- @SKIP@ is not composable through 'clientReply': use
  -- 'sendClientReplySkipAndCommand' on a dedicated sequential connection to
  -- atomically bind it to the command whose reply Redis suppresses.
  clientReply :: ClientReplyValues -> m (Maybe RespData)
  zadd :: (FromResp a) => ByteString -> [(Int, ByteString)] -> m a
  zrange :: (FromResp a) => ByteString -> Int -> Int -> Bool -> m a
  zrem :: (FromResp a) => ByteString -> [ByteString] -> m a
  zcard :: (FromResp a) => ByteString -> m a
  zscore :: (FromResp a) => ByteString -> ByteString -> m a
  zrank :: (FromResp a) => ByteString -> ByteString -> m a
  zrevrank :: (FromResp a) => ByteString -> ByteString -> m a
  zcount :: (FromResp a) => ByteString -> ByteString -> ByteString -> m a
  zincrby :: (FromResp a) => ByteString -> Double -> ByteString -> m a
  zrangestore :: (FromResp a) => ByteString -> ByteString -> ByteString -> ByteString -> [ByteString] -> m a
  geoadd :: (FromResp a) => ByteString -> [(Double, Double, ByteString)] -> m a
  geodist :: (FromResp a) => ByteString -> ByteString -> ByteString -> Maybe GeoUnit -> m a
  geohash :: (FromResp a) => ByteString -> [ByteString] -> m a
  geopos :: (FromResp a) => ByteString -> [ByteString] -> m a
  georadius :: (FromResp a) => ByteString -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> m a
  georadiusRo :: (FromResp a) => ByteString -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> m a
  georadiusByMember :: (FromResp a) => ByteString -> ByteString -> Double -> GeoUnit -> [GeoRadiusFlag] -> m a
  georadiusByMemberRo :: (FromResp a) => ByteString -> ByteString -> Double -> GeoUnit -> [GeoRadiusFlag] -> m a
  geosearch :: (FromResp a) => ByteString -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> m a
  geosearchstore :: (FromResp a) => ByteString -> ByteString -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> Bool -> m a
  clusterSlots :: (FromResp a) => m a

-- | Shared command-routing intent for Redis command backends.
data CommandRoute
  = CommandKeyless
  | CommandByKey ByteString
  | CommandByKeys [ByteString]
  | CommandByMetadata
  deriving (Eq, Show)

-- | Shared command description used by sequential, standalone, and cluster
-- backends. The frame is already encoded at the Redis command-argument level;
-- backends only decide how to transport it.
data CommandDescriptor = CommandDescriptor
  { commandDescriptorFrame :: [ByteString]
  , commandDescriptorRoute :: CommandRoute
  }
  deriving (Eq, Show)

-- | Centralized definitions for every public Redis command.
data RedisCommandDefinitions command = RedisCommandDefinitions
  { definedAuth                :: ByteString -> ByteString -> command
  , definedPing                :: command
  , definedSet                 :: ByteString -> ByteString -> command
  , definedGet                 :: ByteString -> command
  , definedMget                :: [ByteString] -> command
  , definedSetnx               :: ByteString -> ByteString -> command
  , definedDecr                :: ByteString -> command
  , definedAppend              :: ByteString -> ByteString -> command
  , definedStrlen              :: ByteString -> command
  , definedSetex               :: ByteString -> Int -> ByteString -> command
  , definedIncrby              :: ByteString -> Int -> command
  , definedDecrby              :: ByteString -> Int -> command
  , definedIncrbyfloat         :: ByteString -> Double -> command
  , definedGetdel              :: ByteString -> command
  , definedGetex               :: ByteString -> [ByteString] -> command
  , definedPsetex              :: ByteString -> Int -> ByteString -> command
  , definedBulkSet             :: [(ByteString, ByteString)] -> command
  , definedFlushAll            :: command
  , definedDbsize              :: command
  , definedDel                 :: [ByteString] -> command
  , definedExists              :: [ByteString] -> command
  , definedIncr                :: ByteString -> command
  , definedHset                :: ByteString -> ByteString -> ByteString -> command
  , definedHget                :: ByteString -> ByteString -> command
  , definedHmget               :: ByteString -> [ByteString] -> command
  , definedHexists             :: ByteString -> ByteString -> command
  , definedLpush               :: ByteString -> [ByteString] -> command
  , definedLrange              :: ByteString -> Int -> Int -> command
  , definedExpire              :: ByteString -> Int -> command
  , definedTtl                 :: ByteString -> command
  , definedPersist             :: ByteString -> command
  , definedKeyType             :: ByteString -> command
  , definedRename              :: ByteString -> ByteString -> command
  , definedRenamenx            :: ByteString -> ByteString -> command
  , definedUnlink              :: [ByteString] -> command
  , definedPfadd               :: ByteString -> [ByteString] -> command
  , definedPfcount             :: [ByteString] -> command
  , definedPfmerge             :: ByteString -> [ByteString] -> command
  , definedRpush               :: ByteString -> [ByteString] -> command
  , definedLpop                :: ByteString -> command
  , definedRpop                :: ByteString -> command
  , definedSadd                :: ByteString -> [ByteString] -> command
  , definedSmembers            :: ByteString -> command
  , definedScard               :: ByteString -> command
  , definedSismember           :: ByteString -> ByteString -> command
  , definedSrem                :: ByteString -> [ByteString] -> command
  , definedSdiff               :: [ByteString] -> command
  , definedSinter              :: [ByteString] -> command
  , definedSunion              :: [ByteString] -> command
  , definedSpop                :: ByteString -> command
  , definedSrandmember         :: ByteString -> command
  , definedHdel                :: ByteString -> [ByteString] -> command
  , definedHkeys               :: ByteString -> command
  , definedHvals               :: ByteString -> command
  , definedHgetall             :: ByteString -> command
  , definedHlen                :: ByteString -> command
  , definedHsetnx              :: ByteString -> ByteString -> ByteString -> command
  , definedHincrby             :: ByteString -> ByteString -> Int -> command
  , definedHincrbyfloat        :: ByteString -> ByteString -> Double -> command
  , definedLlen                :: ByteString -> command
  , definedLindex              :: ByteString -> Int -> command
  , definedLinsert             :: ByteString -> ByteString -> ByteString -> ByteString -> command
  , definedLset                :: ByteString -> Int -> ByteString -> command
  , definedLtrim               :: ByteString -> Int -> Int -> command
  , definedLrem                :: ByteString -> Int -> ByteString -> command
  , definedClientSetInfo       :: [ByteString] -> command
  , definedClientReplyOn       :: command
  , definedClientReplyOff      :: command
  , definedClientReplySkip     :: command
  , definedZadd                :: ByteString -> [(Int, ByteString)] -> command
  , definedZrange              :: ByteString -> Int -> Int -> Bool -> command
  , definedZrem                :: ByteString -> [ByteString] -> command
  , definedZcard               :: ByteString -> command
  , definedZscore              :: ByteString -> ByteString -> command
  , definedZrank               :: ByteString -> ByteString -> command
  , definedZrevrank            :: ByteString -> ByteString -> command
  , definedZcount              :: ByteString -> ByteString -> ByteString -> command
  , definedZincrby             :: ByteString -> Double -> ByteString -> command
  , definedZrangestore         :: ByteString -> ByteString -> ByteString -> ByteString -> [ByteString] -> command
  , definedGeoadd              :: ByteString -> [(Double, Double, ByteString)] -> command
  , definedGeodist             :: ByteString -> ByteString -> ByteString -> Maybe GeoUnit -> command
  , definedGeohash             :: ByteString -> [ByteString] -> command
  , definedGeopos              :: ByteString -> [ByteString] -> command
  , definedGeoradius           :: ByteString -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> command
  , definedGeoradiusRo         :: ByteString -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> command
  , definedGeoradiusByMember   :: ByteString -> ByteString -> Double -> GeoUnit -> [GeoRadiusFlag] -> command
  , definedGeoradiusByMemberRo :: ByteString -> ByteString -> Double -> GeoUnit -> [GeoRadiusFlag] -> command
  , definedGeosearch           :: ByteString -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> command
  , definedGeosearchstore      :: ByteString -> ByteString -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> Bool -> command
  , definedClusterSlots        :: command
  }

keylessCommand :: [ByteString] -> CommandDescriptor
keylessCommand frame =
  CommandDescriptor frame CommandKeyless

keyedCommand :: ByteString -> [ByteString] -> CommandDescriptor
keyedCommand key frame =
  CommandDescriptor frame (CommandByKey key)

keysCommand :: [ByteString] -> [ByteString] -> CommandDescriptor
keysCommand keys frame
  | null keys = keylessCommand frame
  | otherwise = CommandDescriptor frame (CommandByKeys keys)

requiredKeysCommand :: [ByteString] -> [ByteString] -> CommandDescriptor
requiredKeysCommand keys frame
  | null keys = metadataCommand frame
  | otherwise = keysCommand keys frame

metadataCommand :: [ByteString] -> CommandDescriptor
metadataCommand frame =
  CommandDescriptor frame CommandByMetadata

redisCommandDefinitions :: RedisCommandDefinitions CommandDescriptor
redisCommandDefinitions =
  RedisCommandDefinitions
    { definedAuth = \username password ->
        if BS8.null username || username == "default"
          then keylessCommand ["AUTH", password]
          else keylessCommand ["HELLO", "2", "AUTH", username, password]
    , definedPing = keylessCommand ["PING"]
    , definedSet = \key value -> keyedCommand key ["SET", key, value]
    , definedGet = \key -> keyedCommand key ["GET", key]
    , definedMget = \keys -> keysCommand keys ("MGET" : keys)
    , definedSetnx = \key value -> keyedCommand key ["SETNX", key, value]
    , definedDecr = \key -> keyedCommand key ["DECR", key]
    , definedAppend = \key value -> metadataCommand ["APPEND", key, value]
    , definedStrlen = \key -> metadataCommand ["STRLEN", key]
    , definedSetex = \key seconds value -> metadataCommand ["SETEX", key, showBS seconds, value]
    , definedIncrby = \key amount -> metadataCommand ["INCRBY", key, showBS amount]
    , definedDecrby = \key amount -> metadataCommand ["DECRBY", key, showBS amount]
    , definedIncrbyfloat = \key amount -> metadataCommand ["INCRBYFLOAT", key, showBS amount]
    , definedGetdel = \key -> metadataCommand ["GETDEL", key]
    , definedGetex = \key opts -> metadataCommand (["GETEX", key] ++ opts)
    , definedPsetex = \key milliseconds value -> keyedCommand key ["PSETEX", key, showBS milliseconds, value]
    , definedBulkSet = \pairs ->
        let frame = ["MSET"] <> concatMap (\(key, value) -> [key, value]) pairs
        in keysCommand (fst <$> pairs) frame
    , definedFlushAll = keylessCommand ["FLUSHALL"]
    , definedDbsize = keylessCommand ["DBSIZE"]
    , definedDel = \keys -> keysCommand keys ("DEL" : keys)
    , definedExists = \keys -> keysCommand keys ("EXISTS" : keys)
    , definedIncr = \key -> keyedCommand key ["INCR", key]
    , definedHset = \key field value -> keyedCommand key ["HSET", key, field, value]
    , definedHget = \key field -> keyedCommand key ["HGET", key, field]
    , definedHmget = \key fields -> keyedCommand key ("HMGET" : key : fields)
    , definedHexists = \key field -> keyedCommand key ["HEXISTS", key, field]
    , definedLpush = \key values -> keyedCommand key ("LPUSH" : key : values)
    , definedLrange = \key start stop -> keyedCommand key ["LRANGE", key, showBS start, showBS stop]
    , definedExpire = \key seconds -> keyedCommand key ["EXPIRE", key, showBS seconds]
    , definedTtl = \key -> keyedCommand key ["TTL", key]
    , definedPersist = \key -> metadataCommand ["PERSIST", key]
    , definedKeyType = \key -> metadataCommand ["TYPE", key]
    , definedRename = \key newkey -> keysCommand [key, newkey] ["RENAME", key, newkey]
    , definedRenamenx = \key newkey -> keysCommand [key, newkey] ["RENAMENX", key, newkey]
    , definedUnlink = \keys -> requiredKeysCommand keys ("UNLINK" : keys)
    , definedPfadd = \key elements -> metadataCommand ("PFADD" : key : elements)
    , definedPfcount = \keys -> requiredKeysCommand keys ("PFCOUNT" : keys)
    , definedPfmerge = \destkey sourcekeys -> keysCommand (destkey : sourcekeys) ("PFMERGE" : destkey : sourcekeys)
    , definedRpush = \key values -> keyedCommand key ("RPUSH" : key : values)
    , definedLpop = \key -> keyedCommand key ["LPOP", key]
    , definedRpop = \key -> keyedCommand key ["RPOP", key]
    , definedSadd = \key members -> keyedCommand key ("SADD" : key : members)
    , definedSmembers = \key -> keyedCommand key ["SMEMBERS", key]
    , definedScard = \key -> keyedCommand key ["SCARD", key]
    , definedSismember = \key member -> keyedCommand key ["SISMEMBER", key, member]
    , definedSrem = \key members -> metadataCommand ("SREM" : key : members)
    , definedSdiff = \keys -> requiredKeysCommand keys ("SDIFF" : keys)
    , definedSinter = \keys -> requiredKeysCommand keys ("SINTER" : keys)
    , definedSunion = \keys -> requiredKeysCommand keys ("SUNION" : keys)
    , definedSpop = \key -> metadataCommand ["SPOP", key]
    , definedSrandmember = \key -> metadataCommand ["SRANDMEMBER", key]
    , definedHdel = \key fields -> keyedCommand key ("HDEL" : key : fields)
    , definedHkeys = \key -> keyedCommand key ["HKEYS", key]
    , definedHvals = \key -> keyedCommand key ["HVALS", key]
    , definedHgetall = \key -> metadataCommand ["HGETALL", key]
    , definedHlen = \key -> metadataCommand ["HLEN", key]
    , definedHsetnx = \key field value -> metadataCommand ["HSETNX", key, field, value]
    , definedHincrby = \key field amount -> metadataCommand ["HINCRBY", key, field, showBS amount]
    , definedHincrbyfloat = \key field amount -> metadataCommand ["HINCRBYFLOAT", key, field, showBS amount]
    , definedLlen = \key -> keyedCommand key ["LLEN", key]
    , definedLindex = \key index -> keyedCommand key ["LINDEX", key, showBS index]
    , definedLinsert = \key pos pivot element -> metadataCommand ["LINSERT", key, pos, pivot, element]
    , definedLset = \key index element -> metadataCommand ["LSET", key, showBS index, element]
    , definedLtrim = \key start stop -> metadataCommand ["LTRIM", key, showBS start, showBS stop]
    , definedLrem = \key count element -> metadataCommand ["LREM", key, showBS count, element]
    , definedClientSetInfo = \args -> keylessCommand (["CLIENT", "SETINFO"] ++ args)
    , definedClientReplyOn = keylessCommand ["CLIENT", "REPLY", "ON"]
    , definedClientReplyOff = keylessCommand ["CLIENT", "REPLY", "OFF"]
    , definedClientReplySkip = keylessCommand ["CLIENT", "REPLY", "SKIP"]
    , definedZadd = \key members ->
        let payload = concatMap (\(score, member) -> [showBS score, member]) members
        in keyedCommand key ("ZADD" : key : payload)
    , definedZrange = \key start stop withScores ->
        let base = ["ZRANGE", key, showBS start, showBS stop]
        in keyedCommand key (if withScores then base ++ ["WITHSCORES"] else base)
    , definedZrem = \key members -> metadataCommand ("ZREM" : key : members)
    , definedZcard = \key -> metadataCommand ["ZCARD", key]
    , definedZscore = \key member -> metadataCommand ["ZSCORE", key, member]
    , definedZrank = \key member -> metadataCommand ["ZRANK", key, member]
    , definedZrevrank = \key member -> metadataCommand ["ZREVRANK", key, member]
    , definedZcount = \key minScore maxScore -> metadataCommand ["ZCOUNT", key, minScore, maxScore]
    , definedZincrby = \key increment member -> metadataCommand ["ZINCRBY", key, showBS increment, member]
    , definedZrangestore = \dest source minVal maxVal options ->
        metadataCommand (["ZRANGESTORE", dest, source, minVal, maxVal] ++ options)
    , definedGeoadd = \key entries ->
        let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
        in keyedCommand key ("GEOADD" : key : payload)
    , definedGeodist = \key member1 member2 unit ->
        let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
        in keyedCommand key (["GEODIST", key, member1, member2] ++ unitPart)
    , definedGeohash = \key members -> keyedCommand key ("GEOHASH" : key : members)
    , definedGeopos = \key members -> keyedCommand key ("GEOPOS" : key : members)
    , definedGeoradius = \key lon lat radius unit flags ->
        let base = ["GEORADIUS", key, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
        in metadataCommand (base ++ concatMap geoRadiusFlagToList flags)
    , definedGeoradiusRo = \key lon lat radius unit flags ->
        let base = ["GEORADIUS_RO", key, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
        in metadataCommand (base ++ concatMap geoRadiusFlagToList flags)
    , definedGeoradiusByMember = \key member radius unit flags ->
        let base = ["GEORADIUSBYMEMBER", key, member, showBS radius, geoUnitKeyword unit]
        in metadataCommand (base ++ concatMap geoRadiusFlagToList flags)
    , definedGeoradiusByMemberRo = \key member radius unit flags ->
        let base = ["GEORADIUSBYMEMBER_RO", key, member, showBS radius, geoUnitKeyword unit]
        in metadataCommand (base ++ concatMap geoRadiusFlagToList flags)
    , definedGeosearch = \key fromSpec bySpec options ->
        metadataCommand
          ( [ "GEOSEARCH"
            , key
            ]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
          )
    , definedGeosearchstore = \dest source fromSpec bySpec options storeDist ->
        let base = ["GEOSEARCHSTORE", dest, source]
                ++ geoSearchFromToList fromSpec
                ++ geoSearchByToList bySpec
                ++ concatMap geoSearchOptionToList options
        in keysCommand
             [dest, source]
             (if storeDist then base ++ ["STOREDIST"] else base)
    , definedClusterSlots = keylessCommand ["CLUSTER", "SLOTS"]
    }

-- | Authenticate with the legacy/default Redis user while retaining RESP2.
authenticatePassword
  :: (Client client, FromResp a)
  => ByteString
  -> RedisCommandClient client a
authenticatePassword password = executeCommandAs ["AUTH", password]

-- | Authenticate an ACL user while explicitly retaining RESP2.
authenticateACL
  :: (Client client, FromResp a)
  => ByteString
  -> ByteString
  -> RedisCommandClient client a
authenticateACL username password =
  executeCommandAs ["HELLO", "2", "AUTH", username, password]

-- | Helper to convert a showable value to ByteString for use in commands.
showBS :: (Show a) => a -> ByteString
showBS = BS8.pack . show

-- | Wrap a list of strict ByteStrings into a RESP array of bulk strings.
wrapInRay :: [ByteString] -> RespData
wrapInRay inp =
  let !res = RespArray . map RespBulkString $ inp
   in res

-- | Encode a Redis command (list of arguments) into a Builder for efficient batching.
-- Used by the multiplexer to defer materialization until the writer batches commands.
encodeCommandBuilder :: [ByteString] -> Builder.Builder
encodeCommandBuilder args =
  Builder.char8 '*' <> Builder.intDec (length args) <> Builder.byteString "\r\n" <>
  foldMap encodeBulkArg args

-- | Encode a single bulk string argument: $LEN\r\nDATA\r\n
{-# INLINE encodeBulkArg #-}
encodeBulkArg :: ByteString -> Builder.Builder
encodeBulkArg a = Builder.char8 '$' <> Builder.intDec (BS8.length a) <> Builder.byteString "\r\n"
               <> Builder.byteString a <> Builder.byteString "\r\n"

-- | Pre-computed RESP preamble for SET: *3\r\n$3\r\nSET\r\n
setPreamble :: Builder.Builder
setPreamble = Builder.byteString "*3\r\n$3\r\nSET\r\n"
{-# NOINLINE setPreamble #-}

-- | Pre-computed RESP preamble for GET: *2\r\n$3\r\nGET\r\n
getPreamble :: Builder.Builder
getPreamble = Builder.byteString "*2\r\n$3\r\nGET\r\n"
{-# NOINLINE getPreamble #-}

-- | Specialized SET encoder: avoids list construction, length, and foldMap.
{-# INLINE encodeSetBuilder #-}
encodeSetBuilder :: ByteString -> ByteString -> Builder.Builder
encodeSetBuilder key val = setPreamble <> encodeBulkArg key <> encodeBulkArg val

-- | Specialized GET encoder: avoids list construction, length, and foldMap.
{-# INLINE encodeGetBuilder #-}
encodeGetBuilder :: ByteString -> Builder.Builder
encodeGetBuilder key = getPreamble <> encodeBulkArg key

-- | Encode a Redis command (list of arguments) into its RESP wire format as a strict ByteString.
-- Used by the multiplexer to pre-encode commands before queuing.
encodeCommand :: [ByteString] -> ByteString
encodeCommand args = LBS.toStrict $ Builder.toLazyByteString $ encodeCommandBuilder args

-- | Send a command and parse the response.
executeCommand :: (Client client) => [ByteString] -> RedisCommandClient client RespData
executeCommand args = do
  ClientState !client _ <- State.get
  liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay args)
  parseWith (receive client)

-- | Execute a shared command descriptor on a dedicated sequential connection.
executeCommandDescriptor
  :: (Client client)
  => CommandDescriptor
  -> RedisCommandClient client RespData
executeCommandDescriptor =
  executeCommand . commandDescriptorFrame

-- | Execute a shared command descriptor and convert the response via 'FromResp'.
executeCommandDescriptorAs
  :: (Client client, FromResp a)
  => CommandDescriptor
  -> RedisCommandClient client a
executeCommandDescriptorAs descriptor =
  executeCommandDescriptor descriptor >>= convertResp

-- | Send a command without reading a response on a dedicated sequential
-- connection whose reply mode is already @OFF@. This is the required
-- fire-and-forget operation while replies are disabled; do not use ordinary
-- reply-waiting command functions until @CLIENT REPLY ON@ has consumed its
-- own @OK@ reply.
sendCommandWithoutReply :: (Client client) => [ByteString] -> RedisCommandClient client ()
sendCommandWithoutReply args = do
  ClientState !client _ <- State.get
  liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay args)

-- | Atomically transfer @CLIENT REPLY SKIP@ and its target command on a
-- dedicated sequential connection. Redis suppresses the target reply, so no
-- reply is read and the following command remains aligned.
--
-- If the transfer throws or is cancelled, this function closes the physical
-- connection before propagating an error. If close succeeds, the original
-- transfer error is rethrown unchanged. If transfer and close both fail
-- synchronously, 'ClientReplyUncertainWrite' retains both failures. An
-- asynchronous transfer failure takes precedence over any close failure;
-- otherwise an asynchronous close failure takes precedence over the
-- synchronous transfer failure. When exactly one failure is asynchronous, the
-- synchronous counterpart is reported to standard error. If both failures are
-- asynchronous, the transfer failure wins and the close failure is reported.
--
-- The target may have executed, so callers must reconnect and decide whether
-- retrying it is safe; the connection passed to this function must not be reused.
sendClientReplySkipAndCommand
  :: (Client client)
  => [ByteString]
  -> RedisCommandClient client ()
sendClientReplySkipAndCommand args = do
  ClientState !client _ <- State.get
  let builder =
        encode (wrapInRay ["CLIENT", "REPLY", "SKIP"]) <> encode (wrapInRay args)
  liftIO $ sendSkipAndCommand client (Builder.toLazyByteString builder)

-- | Transfer a reply-suppression pair while owning the connection on every
-- exceptional path. The write is interruptible; once it has started we cannot
-- distinguish no-byte from partial-byte delivery, so either outcome is
-- terminal for this physical connection. Cleanup is uninterruptible only for
-- the single close operation, preventing a second cancellation from leaving
-- the connection eligible for accidental reuse.
sendSkipAndCommand
  :: (Client client)
  => client 'Connected
  -> LBS.ByteString
  -> IO ()
sendSkipAndCommand client bytes = mask $ \restore -> do
  transfer <- try $ restore $ send client bytes
  case transfer of
    Right () -> return ()
    Left (primary :: SomeException) -> do
      closeResult <- uninterruptibleMask_ $ try $ close client
      case closeResult of
        Right () -> throwIO primary
        Left (closeFailure :: SomeException) ->
          resolveUncertainWrite primary closeFailure

resolveUncertainWrite :: SomeException -> SomeException -> IO a
resolveUncertainWrite primary closeFailure =
  case fromException primary of
    Just (async :: SomeAsyncException) -> do
      reportClientReplyCloseFailure primary closeFailure
      throwIO async
    Nothing ->
      case fromException closeFailure of
        Just (async :: SomeAsyncException) -> do
          reportClientReplyCloseFailure primary closeFailure
          throwIO async
        Nothing ->
          throwIO $ ClientReplyUncertainWrite primary closeFailure

reportClientReplyCloseFailure :: SomeException -> SomeException -> IO ()
reportClientReplyCloseFailure primary closeFailure = do
  _ <- (try (hPutStrLn stderr $
    "CLIENT REPLY SKIP transfer failed before connection close: "
      ++ displayException primary
      ++ "\nConnection close also failed: "
      ++ displayException closeFailure) :: IO (Either SomeException ()))
  return ()

-- | Convert a raw 'RespData' value using 'FromResp', throwing on failure.
convertResp :: (FromResp a, MonadIO m) => RespData -> m a
convertResp rd = case fromResp rd of
  Right a  -> return a
  Left err -> liftIO $ throwIO err

-- | Execute a command and convert the result via 'FromResp'.
executeCommandAs :: (Client client, FromResp a) => [ByteString] -> RedisCommandClient client a
executeCommandAs args = executeCommand args >>= convertResp

-- | Distance unit for Redis GEO commands.
data GeoUnit
  = Meters
  | Kilometers
  | Miles
  | Feet
  deriving (Eq, Show)

-- | Convert a 'GeoUnit' to its Redis protocol keyword.
geoUnitKeyword :: GeoUnit -> ByteString
geoUnitKeyword unit =
  case unit of
    Meters     -> "M"
    Kilometers -> "KM"
    Miles      -> "MI"
    Feet       -> "FT"

-- | Optional flags for GEORADIUS and GEORADIUSBYMEMBER commands.
data GeoRadiusFlag
  = GeoWithCoord
  | GeoWithDist
  | GeoWithHash
  | GeoRadiusCount Int Bool -- Bool indicates whether ANY is appended
  | GeoRadiusAsc
  | GeoRadiusDesc
  | GeoRadiusStore ByteString
  | GeoRadiusStoreDist ByteString
  deriving (Eq, Show)

-- | Convert a 'GeoRadiusFlag' to its Redis protocol argument list.
geoRadiusFlagToList :: GeoRadiusFlag -> [ByteString]
geoRadiusFlagToList flag =
  case flag of
    GeoWithCoord            -> ["WITHCOORD"]
    GeoWithDist             -> ["WITHDIST"]
    GeoWithHash             -> ["WITHHASH"]
    GeoRadiusCount n useAny -> ["COUNT", showBS n] <> ["ANY" | useAny]
    GeoRadiusAsc            -> ["ASC"]
    GeoRadiusDesc           -> ["DESC"]
    GeoRadiusStore key      -> ["STORE", key]
    GeoRadiusStoreDist key  -> ["STOREDIST", key]

-- | Origin for a GEOSEARCH query: either a longitude\/latitude pair or an existing member.
data GeoSearchFrom
  = GeoFromLonLat Double Double
  | GeoFromMember ByteString
  deriving (Eq, Show)

-- | Convert a 'GeoSearchFrom' to its Redis protocol argument list.
geoSearchFromToList :: GeoSearchFrom -> [ByteString]
geoSearchFromToList fromSpec =
  case fromSpec of
    GeoFromLonLat lon lat -> ["FROMLONLAT", showBS lon, showBS lat]
    GeoFromMember member  -> ["FROMMEMBER", member]

-- | Shape for a GEOSEARCH query: circular radius or rectangular box.
data GeoSearchBy
  = GeoByRadius Double GeoUnit
  | GeoByBox Double Double GeoUnit
  deriving (Eq, Show)

-- | Convert a 'GeoSearchBy' to its Redis protocol argument list.
geoSearchByToList :: GeoSearchBy -> [ByteString]
geoSearchByToList bySpec =
  case bySpec of
    GeoByRadius radius unit -> ["BYRADIUS", showBS radius, geoUnitKeyword unit]
    GeoByBox width height unit -> ["BYBOX", showBS width, showBS height, geoUnitKeyword unit]

-- | Optional modifiers for GEOSEARCH: include coordinates, distances, hashes,
-- limit count, or sort order.
data GeoSearchOption
  = GeoSearchWithCoord
  | GeoSearchWithDist
  | GeoSearchWithHash
  | GeoSearchCount Int Bool -- Bool indicates ANY
  | GeoSearchAsc
  | GeoSearchDesc
  deriving (Eq, Show)

-- | Convert a 'GeoSearchOption' to its Redis protocol argument list.
geoSearchOptionToList :: GeoSearchOption -> [ByteString]
geoSearchOptionToList opt =
  case opt of
    GeoSearchWithCoord      -> ["WITHCOORD"]
    GeoSearchWithDist       -> ["WITHDIST"]
    GeoSearchWithHash       -> ["WITHHASH"]
    GeoSearchCount n useAny -> ["COUNT", showBS n] <> ["ANY" | useAny]
    GeoSearchAsc            -> ["ASC"]
    GeoSearchDesc           -> ["DESC"]

-- | Values for the CLIENT REPLY command.
data ClientReplyValues = OFF | ON | SKIP
  deriving (Eq, Show)

-- | A reply mode that cannot be represented safely by the requested API.
--
-- Multiplexed and cluster clients reject @OFF@ and @SKIP@ because both alter
-- the reply stream of a shared connection. Sequential clients reject @SKIP@
-- from 'clientReply'; use 'sendClientReplySkipAndCommand' to bind it to its
-- target command atomically.
data ClientReplyModeUnsupported
  = ClientReplyModeUnsupported ClientReplyValues
  deriving (Eq, Show, Typeable)

instance Exception ClientReplyModeUnsupported

-- | Both an atomic @CLIENT REPLY SKIP@ transfer and its required connection
-- close failed synchronously. The primary transfer error and cleanup error are
-- retained so callers can diagnose the uncertain command outcome without
-- losing either.
--
-- This exception never wraps an asynchronous exception. An asynchronous
-- transfer failure wins over the close failure; otherwise an asynchronous
-- close failure wins over the synchronous transfer failure. When exactly one
-- failure is asynchronous, the synchronous counterpart is reported to
-- standard error. If both failures are asynchronous, the transfer failure wins
-- and the close failure is reported.
data ClientReplyUncertainWrite = ClientReplyUncertainWrite
  { clientReplyPrimaryError :: SomeException
  , clientReplyCloseError   :: SomeException
  }
  deriving Typeable

instance Show ClientReplyUncertainWrite where
  show failure =
    "CLIENT REPLY SKIP transfer failed: "
      ++ displayException (clientReplyPrimaryError failure)
      ++ "\nConnection close also failed: "
      ++ displayException (clientReplyCloseError failure)

instance Exception ClientReplyUncertainWrite

instance (Client client) => RedisCommands (RedisCommandClient client) where
  auth username password =
    executeCommandDescriptorAs (definedAuth redisCommandDefinitions username password)
  ping =
    executeCommandDescriptorAs (definedPing redisCommandDefinitions)
  set key value =
    executeCommandDescriptorAs (definedSet redisCommandDefinitions key value)
  get key =
    executeCommandDescriptorAs (definedGet redisCommandDefinitions key)
  mget keys =
    executeCommandDescriptorAs (definedMget redisCommandDefinitions keys)
  setnx key value =
    executeCommandDescriptorAs (definedSetnx redisCommandDefinitions key value)
  decr key =
    executeCommandDescriptorAs (definedDecr redisCommandDefinitions key)
  append key value =
    executeCommandDescriptorAs (definedAppend redisCommandDefinitions key value)
  strlen key =
    executeCommandDescriptorAs (definedStrlen redisCommandDefinitions key)
  setex key seconds value =
    executeCommandDescriptorAs (definedSetex redisCommandDefinitions key seconds value)
  incrby key amount =
    executeCommandDescriptorAs (definedIncrby redisCommandDefinitions key amount)
  decrby key amount =
    executeCommandDescriptorAs (definedDecrby redisCommandDefinitions key amount)
  incrbyfloat key amount =
    executeCommandDescriptorAs (definedIncrbyfloat redisCommandDefinitions key amount)
  getdel key =
    executeCommandDescriptorAs (definedGetdel redisCommandDefinitions key)
  getex key opts =
    executeCommandDescriptorAs (definedGetex redisCommandDefinitions key opts)
  psetex key milliseconds value =
    executeCommandDescriptorAs (definedPsetex redisCommandDefinitions key milliseconds value)
  bulkSet pairs =
    executeCommandDescriptorAs (definedBulkSet redisCommandDefinitions pairs)
  flushAll =
    executeCommandDescriptorAs (definedFlushAll redisCommandDefinitions)
  dbsize =
    executeCommandDescriptorAs (definedDbsize redisCommandDefinitions)
  del keys =
    executeCommandDescriptorAs (definedDel redisCommandDefinitions keys)
  exists keys =
    executeCommandDescriptorAs (definedExists redisCommandDefinitions keys)
  incr key =
    executeCommandDescriptorAs (definedIncr redisCommandDefinitions key)
  hset key field value =
    executeCommandDescriptorAs (definedHset redisCommandDefinitions key field value)
  hget key field =
    executeCommandDescriptorAs (definedHget redisCommandDefinitions key field)
  hmget key fields =
    executeCommandDescriptorAs (definedHmget redisCommandDefinitions key fields)
  hexists key field =
    executeCommandDescriptorAs (definedHexists redisCommandDefinitions key field)
  lpush key values =
    executeCommandDescriptorAs (definedLpush redisCommandDefinitions key values)
  lrange key start stop =
    executeCommandDescriptorAs (definedLrange redisCommandDefinitions key start stop)
  expire key seconds =
    executeCommandDescriptorAs (definedExpire redisCommandDefinitions key seconds)
  ttl key =
    executeCommandDescriptorAs (definedTtl redisCommandDefinitions key)
  persist key =
    executeCommandDescriptorAs (definedPersist redisCommandDefinitions key)
  keyType key =
    executeCommandDescriptorAs (definedKeyType redisCommandDefinitions key)
  rename key newkey =
    executeCommandDescriptorAs (definedRename redisCommandDefinitions key newkey)
  renamenx key newkey =
    executeCommandDescriptorAs (definedRenamenx redisCommandDefinitions key newkey)
  unlink keys =
    executeCommandDescriptorAs (definedUnlink redisCommandDefinitions keys)
  pfadd key elements =
    executeCommandDescriptorAs (definedPfadd redisCommandDefinitions key elements)
  pfcount keys =
    executeCommandDescriptorAs (definedPfcount redisCommandDefinitions keys)
  pfmerge destkey sourcekeys =
    executeCommandDescriptorAs (definedPfmerge redisCommandDefinitions destkey sourcekeys)
  rpush key values =
    executeCommandDescriptorAs (definedRpush redisCommandDefinitions key values)
  lpop key =
    executeCommandDescriptorAs (definedLpop redisCommandDefinitions key)
  rpop key =
    executeCommandDescriptorAs (definedRpop redisCommandDefinitions key)
  sadd key members =
    executeCommandDescriptorAs (definedSadd redisCommandDefinitions key members)
  smembers key =
    executeCommandDescriptorAs (definedSmembers redisCommandDefinitions key)
  scard key =
    executeCommandDescriptorAs (definedScard redisCommandDefinitions key)
  sismember key member =
    executeCommandDescriptorAs (definedSismember redisCommandDefinitions key member)
  srem key members =
    executeCommandDescriptorAs (definedSrem redisCommandDefinitions key members)
  sdiff keys =
    executeCommandDescriptorAs (definedSdiff redisCommandDefinitions keys)
  sinter keys =
    executeCommandDescriptorAs (definedSinter redisCommandDefinitions keys)
  sunion keys =
    executeCommandDescriptorAs (definedSunion redisCommandDefinitions keys)
  spop key =
    executeCommandDescriptorAs (definedSpop redisCommandDefinitions key)
  srandmember key =
    executeCommandDescriptorAs (definedSrandmember redisCommandDefinitions key)
  hdel key fields =
    executeCommandDescriptorAs (definedHdel redisCommandDefinitions key fields)
  hkeys key =
    executeCommandDescriptorAs (definedHkeys redisCommandDefinitions key)
  hvals key =
    executeCommandDescriptorAs (definedHvals redisCommandDefinitions key)
  hgetall key =
    executeCommandDescriptorAs (definedHgetall redisCommandDefinitions key)
  hlen key =
    executeCommandDescriptorAs (definedHlen redisCommandDefinitions key)
  hsetnx key field value =
    executeCommandDescriptorAs (definedHsetnx redisCommandDefinitions key field value)
  hincrby key field amount =
    executeCommandDescriptorAs (definedHincrby redisCommandDefinitions key field amount)
  hincrbyfloat key field amount =
    executeCommandDescriptorAs (definedHincrbyfloat redisCommandDefinitions key field amount)
  llen key =
    executeCommandDescriptorAs (definedLlen redisCommandDefinitions key)
  lindex key index =
    executeCommandDescriptorAs (definedLindex redisCommandDefinitions key index)
  linsert key pos pivot element =
    executeCommandDescriptorAs (definedLinsert redisCommandDefinitions key pos pivot element)
  lset key index element =
    executeCommandDescriptorAs (definedLset redisCommandDefinitions key index element)
  ltrim key start stop =
    executeCommandDescriptorAs (definedLtrim redisCommandDefinitions key start stop)
  lrem key count element =
    executeCommandDescriptorAs (definedLrem redisCommandDefinitions key count element)
  clientSetInfo info =
    executeCommandDescriptorAs (definedClientSetInfo redisCommandDefinitions info)
  clusterSlots =
    executeCommandDescriptorAs (definedClusterSlots redisCommandDefinitions)

  clientReply val = do
    case val of
      ON ->
        Just <$> executeCommandDescriptor (definedClientReplyOn redisCommandDefinitions)
      OFF -> do
        sendCommandWithoutReply
          (commandDescriptorFrame $ definedClientReplyOff redisCommandDefinitions)
        return Nothing
      SKIP -> liftIO $ throwIO (ClientReplyModeUnsupported SKIP)
  zadd key members =
    executeCommandDescriptorAs (definedZadd redisCommandDefinitions key members)
  zrange key start stop withScores =
    executeCommandDescriptorAs (definedZrange redisCommandDefinitions key start stop withScores)
  zrem key members =
    executeCommandDescriptorAs (definedZrem redisCommandDefinitions key members)
  zcard key =
    executeCommandDescriptorAs (definedZcard redisCommandDefinitions key)
  zscore key member =
    executeCommandDescriptorAs (definedZscore redisCommandDefinitions key member)
  zrank key member =
    executeCommandDescriptorAs (definedZrank redisCommandDefinitions key member)
  zrevrank key member =
    executeCommandDescriptorAs (definedZrevrank redisCommandDefinitions key member)
  zcount key minScore maxScore =
    executeCommandDescriptorAs (definedZcount redisCommandDefinitions key minScore maxScore)
  zincrby key increment member =
    executeCommandDescriptorAs (definedZincrby redisCommandDefinitions key increment member)
  zrangestore dst src minVal maxVal opts =
    executeCommandDescriptorAs (definedZrangestore redisCommandDefinitions dst src minVal maxVal opts)
  geoadd key entries =
    executeCommandDescriptorAs (definedGeoadd redisCommandDefinitions key entries)
  geodist key member1 member2 unit =
    executeCommandDescriptorAs (definedGeodist redisCommandDefinitions key member1 member2 unit)
  geohash key members =
    executeCommandDescriptorAs (definedGeohash redisCommandDefinitions key members)
  geopos key members =
    executeCommandDescriptorAs (definedGeopos redisCommandDefinitions key members)
  georadius key longitude latitude radius unit flags =
    executeCommandDescriptorAs
      (definedGeoradius redisCommandDefinitions key longitude latitude radius unit flags)
  georadiusRo key longitude latitude radius unit flags =
    executeCommandDescriptorAs
      (definedGeoradiusRo redisCommandDefinitions key longitude latitude radius unit flags)
  georadiusByMember key member radius unit flags =
    executeCommandDescriptorAs
      (definedGeoradiusByMember redisCommandDefinitions key member radius unit flags)
  georadiusByMemberRo key member radius unit flags =
    executeCommandDescriptorAs
      (definedGeoradiusByMemberRo redisCommandDefinitions key member radius unit flags)
  geosearch key fromSpec bySpec options =
    executeCommandDescriptorAs
      (definedGeosearch redisCommandDefinitions key fromSpec bySpec options)
  geosearchstore dest source fromSpec bySpec options storeDist =
    executeCommandDescriptorAs
      (definedGeosearchstore redisCommandDefinitions dest source fromSpec bySpec options storeDist)

-- | Receive exactly one RESP value, fetching more bytes from the connection as needed.
-- Throws 'ParseError' on malformed data and 'ConnectionClosed' if the remote end hangs up.
parseWith :: (Client client, MonadIO m, MonadState (ClientState client) m) => m BS8.ByteString -> m RespData
parseWith recv = do
  result <- parseManyWith 1 recv
  case result of
    [x] -> return x
    _ -> liftIO $ throwIO $ ParseError "parseWith: expected exactly one result"

-- | Receive exactly @cnt@ RESP values from the connection, performing incremental
-- parsing against the internal buffer and fetching more bytes as needed.
parseManyWith :: (Client client, MonadIO m, MonadState (ClientState client) m) => Int -> m BS8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  (ClientState !client !input) <- State.get
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> liftIO $ throwIO $ ParseError err
    part@(StrictParse.Partial _) -> runUntilDone client part recv
    StrictParse.Done remainder !r -> do
      State.put (ClientState client remainder)
      return r
  where
    runUntilDone :: (Client client, MonadIO m, MonadState (ClientState client) m) => client 'Connected -> StrictParse.IResult BS8.ByteString r -> m BS8.ByteString -> m r
    runUntilDone _client (StrictParse.Fail _ _ err) _ = liftIO $ throwIO $ ParseError err
    runUntilDone client (StrictParse.Partial f) getMore = do
      moreData <- getMore
      if BS8.null moreData
        then liftIO $ throwIO ConnectionClosed
        else runUntilDone client (f moreData) getMore
    runUntilDone client (StrictParse.Done remainder !r) _ = do
      State.put (ClientState client remainder)
      return r
