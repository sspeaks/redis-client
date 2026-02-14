{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

-- | High-level Redis command interface built on top of 'Client'.
--
-- Provides the 'RedisCommands' typeclass with methods for standard Redis commands
-- (strings, hashes, lists, sets, sorted sets, geo), a 'RedisCommandClient' monad
-- that manages connection state and incremental RESP parsing, and typed error handling
-- via 'RedisError'.
module Database.Redis.Command
  ( -- * Core types
    ClientState (..)
  , RedisCommandClient (..)
  , RedisCommands (..)
  , ClientReplyValues (..)
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

import           Control.Exception                (throwIO)
import           Control.Monad.IO.Class           (MonadIO (..))
import           Control.Monad.State              as State (MonadState (get, put),
                                                            StateT)
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as BS8
import qualified Data.ByteString.Lazy             as LBS
import           Data.Kind                        (Type)
import           Database.Redis.Client            (Client (..),
                                                   ConnectionStatus (..))
import           Database.Redis.Resp              (Encodable (encode),
                                                   RespData (..), parseRespData)
import           FromResp                         (FromResp (..))
import           RedisError                       (RedisError (..))


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
  hset :: (FromResp a) => ByteString -> ByteString -> ByteString -> m a
  hget :: (FromResp a) => ByteString -> ByteString -> m a
  hmget :: (FromResp a) => ByteString -> [ByteString] -> m a
  hexists :: (FromResp a) => ByteString -> ByteString -> m a
  lpush :: (FromResp a) => ByteString -> [ByteString] -> m a
  lrange :: (FromResp a) => ByteString -> Int -> Int -> m a
  expire :: (FromResp a) => ByteString -> Int -> m a
  ttl :: (FromResp a) => ByteString -> m a
  rpush :: (FromResp a) => ByteString -> [ByteString] -> m a
  lpop :: (FromResp a) => ByteString -> m a
  rpop :: (FromResp a) => ByteString -> m a
  sadd :: (FromResp a) => ByteString -> [ByteString] -> m a
  smembers :: (FromResp a) => ByteString -> m a
  scard :: (FromResp a) => ByteString -> m a
  sismember :: (FromResp a) => ByteString -> ByteString -> m a
  hdel :: (FromResp a) => ByteString -> [ByteString] -> m a
  hkeys :: (FromResp a) => ByteString -> m a
  hvals :: (FromResp a) => ByteString -> m a
  llen :: (FromResp a) => ByteString -> m a
  lindex :: (FromResp a) => ByteString -> Int -> m a
  clientSetInfo :: (FromResp a) => [ByteString] -> m a
  clientReply :: ClientReplyValues -> m (Maybe RespData)
  zadd :: (FromResp a) => ByteString -> [(Int, ByteString)] -> m a
  zrange :: (FromResp a) => ByteString -> Int -> Int -> Bool -> m a
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

instance (Client client) => RedisCommands (RedisCommandClient client) where
  ping = executeCommandAs ["PING"]
  set k v = executeCommandAs ["SET", k, v]
  get k = executeCommandAs ["GET", k]
  mget keys = executeCommandAs ("MGET" : keys)
  setnx key value = executeCommandAs ["SETNX", key, value]
  decr key = executeCommandAs ["DECR", key]
  psetex key milliseconds value = executeCommandAs ["PSETEX", key, showBS milliseconds, value]
  auth username password = executeCommandAs ["HELLO", "3", "AUTH", username, password]
  bulkSet kvs = executeCommandAs (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs)
  flushAll = executeCommandAs ["FLUSHALL"]
  dbsize = executeCommandAs ["DBSIZE"]
  del keys = executeCommandAs ("DEL" : keys)
  exists keys = executeCommandAs ("EXISTS" : keys)
  incr key = executeCommandAs ["INCR", key]
  hset key field value = executeCommandAs ["HSET", key, field, value]
  hget key field = executeCommandAs ["HGET", key, field]
  hmget key fields = executeCommandAs ("HMGET" : key : fields)
  hexists key field = executeCommandAs ["HEXISTS", key, field]
  lpush key values = executeCommandAs ("LPUSH" : key : values)
  lrange key start stop = executeCommandAs ["LRANGE", key, showBS start, showBS stop]
  expire key seconds = executeCommandAs ["EXPIRE", key, showBS seconds]
  ttl key = executeCommandAs ["TTL", key]
  rpush key values = executeCommandAs ("RPUSH" : key : values)
  lpop key = executeCommandAs ["LPOP", key]
  rpop key = executeCommandAs ["RPOP", key]
  sadd key members = executeCommandAs ("SADD" : key : members)
  smembers key = executeCommandAs ["SMEMBERS", key]
  scard key = executeCommandAs ["SCARD", key]
  sismember key member = executeCommandAs ["SISMEMBER", key, member]
  hdel key fields = executeCommandAs ("HDEL" : key : fields)
  hkeys key = executeCommandAs ["HKEYS", key]
  hvals key = executeCommandAs ["HVALS", key]
  llen key = executeCommandAs ["LLEN", key]
  lindex key index = executeCommandAs ["LINDEX", key, showBS index]
  clientSetInfo info = executeCommandAs (["CLIENT", "SETINFO"] ++ info)
  clusterSlots = executeCommandAs ["CLUSTER", "SLOTS"]

  clientReply val = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["CLIENT", "REPLY", showBS val])
    case val of
      ON -> Just <$> parseWith (receive client)
      _  -> return Nothing

  zadd key members =
    let payload = concatMap (\(score, member) -> [showBS score, member]) members
    in executeCommandAs ("ZADD" : key : payload)

  zrange key start stop withScores =
    let base = ["ZRANGE", key, showBS start, showBS stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in executeCommandAs command

  geoadd key entries =
    let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
    in executeCommandAs ("GEOADD" : key : payload)

  geodist key member1 member2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in executeCommandAs (["GEODIST", key, member1, member2] ++ unitPart)

  geohash key members = executeCommandAs ("GEOHASH" : key : members)
  geopos key members = executeCommandAs ("GEOPOS" : key : members)

  georadius key longitude latitude radius unit flags =
    let base = ["GEORADIUS", key, showBS longitude, showBS latitude, showBS radius, geoUnitKeyword unit]
    in executeCommandAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusRo key longitude latitude radius unit flags =
    let base = ["GEORADIUS_RO", key, showBS longitude, showBS latitude, showBS radius, geoUnitKeyword unit]
    in executeCommandAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMember key member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", key, member, showBS radius, geoUnitKeyword unit]
    in executeCommandAs (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMemberRo key member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", key, member, showBS radius, geoUnitKeyword unit]
    in executeCommandAs (base ++ concatMap geoRadiusFlagToList flags)

  geosearch key fromSpec bySpec options =
    executeCommandAs (["GEOSEARCH", key]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)

  geosearchstore dest source fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, source]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in executeCommandAs command

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
