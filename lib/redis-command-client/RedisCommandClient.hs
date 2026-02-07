{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | High-level Redis command interface built on top of 'Client'.
--
-- Provides the 'RedisCommands' typeclass with methods for standard Redis commands
-- (strings, hashes, lists, sets, sorted sets, geo), a 'RedisCommandClient' monad
-- that manages connection state and incremental RESP parsing, and typed error handling
-- via 'RedisError'.
module RedisCommandClient
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
  , geoUnitKeyword
  , geoRadiusFlagToList
  , geoSearchFromToList
  , geoSearchByToList
  , geoSearchOptionToList
    -- * Parsing
  , parseWith
  , parseManyWith
  ) where

import Client (Client (..), ConnectionStatus (..))
import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.State as State
  ( MonadState (get, put),
    StateT,
  )
import Data.Attoparsec.ByteString.Char8 qualified as StrictParse
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as SB8
import Data.ByteString.Lazy.Char8 qualified as BSC
import Data.Kind (Type)
import Data.Typeable (Typeable)
import Resp (Encodable (encode), RespData (..), parseRespData)

-- | Typed exceptions for Redis protocol errors.
data RedisError
  = ParseError String        -- ^ RESP parse failure
  | ConnectionClosed         -- ^ Remote end closed the connection
  deriving (Show, Typeable)

instance Exception RedisError

-- | Mutable state carried through a 'RedisCommandClient' session: the live connection
-- and an unparsed RESP byte buffer from previous receives.
data ClientState client = ClientState
  { getClient :: client 'Connected,
    getParseBuffer :: SB8.ByteString
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
class (MonadIO m) => RedisCommands m where
  auth :: String -> String -> m RespData
  ping :: m RespData
  set :: String -> String -> m RespData
  get :: String -> m RespData
  mget :: [String] -> m RespData
  setnx :: String -> String -> m RespData
  decr :: String -> m RespData
  psetex :: String -> Int -> String -> m RespData
  bulkSet :: [(String, String)] -> m RespData
  flushAll :: m RespData
  dbsize :: m RespData
  del :: [String] -> m RespData
  exists :: [String] -> m RespData
  incr :: String -> m RespData
  hset :: String -> String -> String -> m RespData
  hget :: String -> String -> m RespData
  hmget :: String -> [String] -> m RespData
  hexists :: String -> String -> m RespData
  lpush :: String -> [String] -> m RespData
  lrange :: String -> Int -> Int -> m RespData
  expire :: String -> Int -> m RespData
  ttl :: String -> m RespData
  rpush :: String -> [String] -> m RespData
  lpop :: String -> m RespData
  rpop :: String -> m RespData
  sadd :: String -> [String] -> m RespData
  smembers :: String -> m RespData
  scard :: String -> m RespData
  sismember :: String -> String -> m RespData
  hdel :: String -> [String] -> m RespData
  hkeys :: String -> m RespData
  hvals :: String -> m RespData
  llen :: String -> m RespData
  lindex :: String -> Int -> m RespData
  clientSetInfo :: [String] -> m RespData
  clientReply :: ClientReplyValues -> m (Maybe RespData)
  zadd :: String -> [(Int, String)] -> m RespData
  zrange :: String -> Int -> Int -> Bool -> m RespData
  geoadd :: String -> [(Double, Double, String)] -> m RespData
  geodist :: String -> String -> String -> Maybe GeoUnit -> m RespData
  geohash :: String -> [String] -> m RespData
  geopos :: String -> [String] -> m RespData
  georadius :: String -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> m RespData
  georadiusRo :: String -> Double -> Double -> Double -> GeoUnit -> [GeoRadiusFlag] -> m RespData
  georadiusByMember :: String -> String -> Double -> GeoUnit -> [GeoRadiusFlag] -> m RespData
  georadiusByMemberRo :: String -> String -> Double -> GeoUnit -> [GeoRadiusFlag] -> m RespData
  geosearch :: String -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> m RespData
  geosearchstore :: String -> String -> GeoSearchFrom -> GeoSearchBy -> [GeoSearchOption] -> Bool -> m RespData
  clusterSlots :: m RespData

-- | Wrap a list of strings into a RESP array of bulk strings, ready for sending.
wrapInRay :: [String] -> RespData
wrapInRay inp =
  let !res = RespArray . map (RespBulkString . BSC.pack) $ inp
   in res

-- | Send a command and parse the response. Eliminates the 3-line boilerplate
-- of State.get → send wrapInRay → parseWith receive repeated across all commands.
executeCommand :: (Client client) => [String] -> RedisCommandClient client RespData
executeCommand args = do
  ClientState !client _ <- State.get
  liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay args)
  parseWith (receive client)

-- | Distance unit for Redis GEO commands.
data GeoUnit
  = Meters
  | Kilometers
  | Miles
  | Feet
  deriving (Eq, Show)

geoUnitKeyword :: GeoUnit -> String
geoUnitKeyword unit =
  case unit of
    Meters -> "M"
    Kilometers -> "KM"
    Miles -> "MI"
    Feet -> "FT"

-- | Optional flags for GEORADIUS and GEORADIUSBYMEMBER commands.
data GeoRadiusFlag
  = GeoWithCoord
  | GeoWithDist
  | GeoWithHash
  | GeoRadiusCount Int Bool -- Bool indicates whether ANY is appended
  | GeoRadiusAsc
  | GeoRadiusDesc
  | GeoRadiusStore String
  | GeoRadiusStoreDist String
  deriving (Eq, Show)

geoRadiusFlagToList :: GeoRadiusFlag -> [String]
geoRadiusFlagToList flag =
  case flag of
    GeoWithCoord -> ["WITHCOORD"]
    GeoWithDist -> ["WITHDIST"]
    GeoWithHash -> ["WITHHASH"]
    GeoRadiusCount n useAny -> ["COUNT", show n] <> ["ANY" | useAny]
    GeoRadiusAsc -> ["ASC"]
    GeoRadiusDesc -> ["DESC"]
    GeoRadiusStore key -> ["STORE", key]
    GeoRadiusStoreDist key -> ["STOREDIST", key]

-- | Origin for a GEOSEARCH query: either a longitude\/latitude pair or an existing member.
data GeoSearchFrom
  = GeoFromLonLat Double Double
  | GeoFromMember String
  deriving (Eq, Show)

geoSearchFromToList :: GeoSearchFrom -> [String]
geoSearchFromToList fromSpec =
  case fromSpec of
    GeoFromLonLat lon lat -> ["FROMLONLAT", show lon, show lat]
    GeoFromMember member -> ["FROMMEMBER", member]

-- | Shape for a GEOSEARCH query: circular radius or rectangular box.
data GeoSearchBy
  = GeoByRadius Double GeoUnit
  | GeoByBox Double Double GeoUnit
  deriving (Eq, Show)

geoSearchByToList :: GeoSearchBy -> [String]
geoSearchByToList bySpec =
  case bySpec of
    GeoByRadius radius unit -> ["BYRADIUS", show radius, geoUnitKeyword unit]
    GeoByBox width height unit -> ["BYBOX", show width, show height, geoUnitKeyword unit]

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

geoSearchOptionToList :: GeoSearchOption -> [String]
geoSearchOptionToList opt =
  case opt of
    GeoSearchWithCoord -> ["WITHCOORD"]
    GeoSearchWithDist -> ["WITHDIST"]
    GeoSearchWithHash -> ["WITHHASH"]
    GeoSearchCount n useAny -> ["COUNT", show n] <> ["ANY" | useAny]
    GeoSearchAsc -> ["ASC"]
    GeoSearchDesc -> ["DESC"]

-- | Values for the CLIENT REPLY command.
data ClientReplyValues = OFF | ON | SKIP
  deriving (Eq, Show)

instance (Client client) => RedisCommands (RedisCommandClient client) where
  ping = executeCommand ["PING"]
  set k v = executeCommand ["SET", k, v]
  get k = executeCommand ["GET", k]
  mget keys = executeCommand ("MGET" : keys)
  setnx key value = executeCommand ["SETNX", key, value]
  decr key = executeCommand ["DECR", key]
  psetex key milliseconds value = executeCommand ["PSETEX", key, show milliseconds, value]
  auth username password = executeCommand ["HELLO", "3", "AUTH", username, password]
  bulkSet kvs = executeCommand (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs)
  flushAll = executeCommand ["FLUSHALL"]
  dbsize = executeCommand ["DBSIZE"]
  del keys = executeCommand ("DEL" : keys)
  exists keys = executeCommand ("EXISTS" : keys)
  incr key = executeCommand ["INCR", key]
  hset key field value = executeCommand ["HSET", key, field, value]
  hget key field = executeCommand ["HGET", key, field]
  hmget key fields = executeCommand ("HMGET" : key : fields)
  hexists key field = executeCommand ["HEXISTS", key, field]
  lpush key values = executeCommand ("LPUSH" : key : values)
  lrange key start stop = executeCommand ["LRANGE", key, show start, show stop]
  expire key seconds = executeCommand ["EXPIRE", key, show seconds]
  ttl key = executeCommand ["TTL", key]
  rpush key values = executeCommand ("RPUSH" : key : values)
  lpop key = executeCommand ["LPOP", key]
  rpop key = executeCommand ["RPOP", key]
  sadd key members = executeCommand ("SADD" : key : members)
  smembers key = executeCommand ["SMEMBERS", key]
  scard key = executeCommand ["SCARD", key]
  sismember key member = executeCommand ["SISMEMBER", key, member]
  hdel key fields = executeCommand ("HDEL" : key : fields)
  hkeys key = executeCommand ["HKEYS", key]
  hvals key = executeCommand ["HVALS", key]
  llen key = executeCommand ["LLEN", key]
  lindex key index = executeCommand ["LINDEX", key, show index]
  clientSetInfo info = executeCommand (["CLIENT", "SETINFO"] ++ info)
  clusterSlots = executeCommand ["CLUSTER", "SLOTS"]

  clientReply val = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["CLIENT", "REPLY", show val])
    case val of
      ON -> Just <$> parseWith (receive client)
      _ -> return Nothing

  zadd key members =
    let payload = concatMap (\(score, member) -> [show score, member]) members
    in executeCommand ("ZADD" : key : payload)

  zrange key start stop withScores =
    let base = ["ZRANGE", key, show start, show stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in executeCommand command

  geoadd key entries =
    let payload = concatMap (\(lon, lat, member) -> [show lon, show lat, member]) entries
    in executeCommand ("GEOADD" : key : payload)

  geodist key member1 member2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in executeCommand (["GEODIST", key, member1, member2] ++ unitPart)

  geohash key members = executeCommand ("GEOHASH" : key : members)
  geopos key members = executeCommand ("GEOPOS" : key : members)

  georadius key longitude latitude radius unit flags =
    let base = ["GEORADIUS", key, show longitude, show latitude, show radius, geoUnitKeyword unit]
    in executeCommand (base ++ concatMap geoRadiusFlagToList flags)

  georadiusRo key longitude latitude radius unit flags =
    let base = ["GEORADIUS_RO", key, show longitude, show latitude, show radius, geoUnitKeyword unit]
    in executeCommand (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMember key member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", key, member, show radius, geoUnitKeyword unit]
    in executeCommand (base ++ concatMap geoRadiusFlagToList flags)

  georadiusByMemberRo key member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", key, member, show radius, geoUnitKeyword unit]
    in executeCommand (base ++ concatMap geoRadiusFlagToList flags)

  geosearch key fromSpec bySpec options =
    executeCommand (["GEOSEARCH", key]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)

  geosearchstore dest source fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, source]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in executeCommand command

-- | Receive exactly one RESP value, fetching more bytes from the connection as needed.
-- Throws 'ParseError' on malformed data and 'ConnectionClosed' if the remote end hangs up.
parseWith :: (Client client, MonadIO m, MonadState (ClientState client) m) => m SB8.ByteString -> m RespData
parseWith recv = do
  result <- parseManyWith 1 recv
  case result of
    [x] -> return x
    _ -> liftIO $ throwIO $ ParseError "parseWith: expected exactly one result"

-- | Receive exactly @cnt@ RESP values from the connection, performing incremental
-- parsing against the internal buffer and fetching more bytes as needed.
parseManyWith :: (Client client, MonadIO m, MonadState (ClientState client) m) => Int -> m SB8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  (ClientState !client !input) <- State.get
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> liftIO $ throwIO $ ParseError err
    part@(StrictParse.Partial f) -> runUntilDone client part recv
    StrictParse.Done remainder !r -> do
      State.put (ClientState client remainder)
      return r
  where
    runUntilDone :: (Client client, MonadIO m, MonadState (ClientState client) m) => client 'Connected -> StrictParse.IResult SB8.ByteString r -> m SB8.ByteString -> m r
    runUntilDone client (StrictParse.Fail _ _ err) _ = liftIO $ throwIO $ ParseError err
    runUntilDone client (StrictParse.Partial f) getMore = do
      moreData <- getMore
      if SB8.null moreData
        then liftIO $ throwIO ConnectionClosed
        else runUntilDone client (f moreData) getMore
    runUntilDone client (StrictParse.Done remainder !r) _ = do
      State.put (ClientState client remainder)
      return r
