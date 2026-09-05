{-# LANGUAGE OverloadedStrings #-}

-- | Conservative Redis 7.2 command grammar used by the smart proxy.
--
-- Commands absent from this table deliberately fail closed.  Routing an
-- unknown command by its first argument is incorrect for commands with
-- movable keys and is unsafe when Redis adds a new command.
module Database.Redis.Cluster.Commands
  ( keylessCommands
  , requiresKeyCommands
  , CommandRouting (..)
  , classifyCommand
  ) where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS8
import           Data.Char             (isDigit, toUpper)

data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | MultiKeyRoute [ByteString]
  | CommandError String
  deriving (Eq, Show)

-- | Classify a complete command argument vector (without the command name).
-- Every accepted form has had its key positions checked before it can be
-- dispatched.  'MultiKeyRoute' retains all keys so the proxy can reject
-- cross-slot operations before contacting Redis.
classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand command args =
  case upper command of
    "PING"       -> keylessAtMost 1
    "ECHO"       -> keylessExactly 1
    "AUTH"       -> keylessBetween 1 2
    "QUIT"       -> keylessExactly 0
    "ASKING"     -> keylessExactly 0
    "READONLY"   -> keylessExactly 0
    "READWRITE"  -> keylessExactly 0
    "TIME"       -> keylessExactly 0
    "DBSIZE"     -> keylessExactly 0
    "LASTSAVE"   -> keylessExactly 0
    "SAVE"       -> keylessExactly 0
    "BGSAVE"     -> keylessAtMost 1
    "BGREWRITEAOF" -> keylessExactly 0
    "FLUSHALL"   -> keylessAtMost 1
    "FLUSHDB"    -> keylessAtMost 1
    "INFO"       -> keylessAtMost 1
    "ROLE"       -> keylessExactly 0
    "COMMAND"    -> KeylessRoute
    "CLUSTER"    -> KeylessRoute
    "CLIENT"     -> KeylessRoute
    "CONFIG"     -> KeylessRoute
    "MEMORY"     -> memory args
    "OBJECT"     -> object args
    "SET"        -> set args
    "MSET"       -> pairs "MSET" args
    "MSETNX"     -> pairs "MSETNX" args
    "RENAME"     -> exactlyKeys "RENAME" 2 args
    "RENAMENX"   -> exactlyKeys "RENAMENX" 2 args
    "COPY"       -> copy args
    "EVAL"       -> countedKeys "EVAL" args
    "EVALSHA"    -> countedKeys "EVALSHA" args
    "FCALL"      -> countedKeys "FCALL" args
    "FCALL_RO"   -> countedKeys "FCALL_RO" args
    "XREAD"      -> xread "XREAD" args
    "XREADGROUP" -> xread "XREADGROUP" args
    "ZUNION"     -> zsetCount "ZUNION" False args
    "ZINTER"     -> zsetCount "ZINTER" False args
    "ZDIFF"      -> zsetCount "ZDIFF" False args
    "ZUNIONSTORE" -> zsetCount "ZUNIONSTORE" True args
    "ZINTERSTORE" -> zsetCount "ZINTERSTORE" True args
    "ZDIFFSTORE" -> zsetCount "ZDIFFSTORE" True args
    "BLPOP"      -> blockingKeys "BLPOP" args
    "BRPOP"      -> blockingKeys "BRPOP" args
    "BZPOPMIN"   -> blockingKeys "BZPOPMIN" args
    "BZPOPMAX"   -> blockingKeys "BZPOPMAX" args
    "PFCOUNT"    -> someKeys "PFCOUNT" args
    "TOUCH"      -> someKeys "TOUCH" args
    "UNLINK"     -> someKeys "UNLINK" args
    "WATCH"      -> someKeys "WATCH" args
    "DEL"        -> someKeys "DEL" args
    "EXISTS"     -> someKeys "EXISTS" args
    "MGET"       -> someKeys "MGET" args
    "GEOSEARCH"  -> geoSearch args
    "GEORADIUS"  -> geoRadius args
    "GEORADIUSBYMEMBER" -> geoRadius args
    "XINFO"      -> xinfo args
    c | c `elem` firstKeyCommands -> oneOrMoreKey c args
      | otherwise -> CommandError ("Unsupported Redis command: " ++ BS8.unpack command)
  where
    keylessExactly n | length args == n = KeylessRoute
                      | otherwise = arity (upper command)
    keylessAtMost n | length args <= n = KeylessRoute
                    | otherwise = arity (upper command)
    keylessBetween lo hi | length args >= lo && length args <= hi = KeylessRoute
                         | otherwise = arity (upper command)

keylessCommands :: [ByteString]
keylessCommands =
  ["PING", "ECHO", "AUTH", "QUIT", "ASKING", "READONLY", "READWRITE", "TIME"
  ,"DBSIZE", "LASTSAVE", "SAVE", "BGSAVE", "BGREWRITEAOF", "FLUSHALL"
  ,"FLUSHDB", "INFO", "ROLE", "COMMAND", "CLUSTER", "CLIENT", "CONFIG"]

requiresKeyCommands :: [ByteString]
requiresKeyCommands = firstKeyCommands

firstKeyCommands :: [ByteString]
firstKeyCommands =
  ["GET", "GETDEL", "GETEX", "SETNX", "SETEX", "PSETEX", "APPEND", "STRLEN"
  ,"GETRANGE", "SETRANGE", "INCR", "INCRBY", "INCRBYFLOAT", "DECR", "DECRBY"
  ,"EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "TTL", "PTTL", "PERSIST"
  ,"TYPE", "DUMP", "RESTORE", "HGET", "HSET", "HDEL", "HGETALL", "HKEYS"
  ,"HVALS", "HEXISTS", "HLEN", "HMGET", "HMSET", "HINCRBY", "HINCRBYFLOAT"
  ,"LPUSH", "RPUSH", "LPOP", "RPOP", "LLEN", "LRANGE", "LINDEX", "LSET"
  ,"LTRIM", "LREM", "SADD", "SREM", "SMEMBERS", "SCARD", "SISMEMBER"
  ,"SPOP", "SRANDMEMBER", "ZADD", "ZREM", "ZRANGE", "ZREVRANGE", "ZCARD"
  ,"ZSCORE", "ZRANK", "ZREVRANK", "ZCOUNT", "ZINCRBY", "XADD", "XLEN"
  ,"XRANGE", "XREVRANGE", "XTRIM", "XDEL", "XACK", "XPENDING", "XGROUP"]

oneOrMoreKey :: ByteString -> [ByteString] -> CommandRouting
oneOrMoreKey _ (k:_) = KeyedRoute k
oneOrMoreKey name [] = arity name

someKeys :: ByteString -> [ByteString] -> CommandRouting
someKeys _ ks@(_:_) = MultiKeyRoute ks
someKeys name []    = arity name

exactlyKeys :: ByteString -> Int -> [ByteString] -> CommandRouting
exactlyKeys name count ks
  | length ks == count = MultiKeyRoute ks
  | otherwise = arity name

pairs :: ByteString -> [ByteString] -> CommandRouting
pairs name xs
  | null xs || odd (length xs) = arity name
  | otherwise = MultiKeyRoute (everyOther xs)

set :: [ByteString] -> CommandRouting
set (key:value:options)
  | validSetOptions options = KeyedRoute key
  | otherwise = CommandError "Malformed SET options"
set _ = arity "SET"

validSetOptions :: [ByteString] -> Bool
validSetOptions = go False False False False
  where
    go _ _ _ _ [] = True
    go expiry nx xx get ("EX":n:xs) = expiry == False && positive n && go True nx xx get xs
    go expiry nx xx get ("PX":n:xs) = expiry == False && positive n && go True nx xx get xs
    go expiry nx xx get ("EXAT":n:xs) = expiry == False && positive n && go True nx xx get xs
    go expiry nx xx get ("PXAT":n:xs) = expiry == False && positive n && go True nx xx get xs
    go expiry nx xx get ("KEEPTTL":xs) = expiry == False && go True nx xx get xs
    go expiry nx xx get ("NX":xs) = not nx && not xx && go expiry True xx get xs
    go expiry nx xx get ("XX":xs) = not nx && not xx && go expiry nx True get xs
    go expiry nx xx get ("GET":xs) = not get && go expiry nx xx True xs
    go _ _ _ _ _ = False

memory :: [ByteString] -> CommandRouting
memory ["USAGE", key] = KeyedRoute key
memory ["USAGE", key, "SAMPLES", n] | natural n = KeyedRoute key
memory ["DOCTOR"] = KeylessRoute
memory ["MALLOC-STATS"] = KeylessRoute
memory ["PURGE"] = KeylessRoute
memory ["STATS"] = KeylessRoute
memory _ = CommandError "Malformed MEMORY command"

object :: [ByteString] -> CommandRouting
object [subcommand, key]
  | upper subcommand `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] = KeyedRoute key
object _ = CommandError "Malformed OBJECT command"

countedKeys :: ByteString -> [ByteString] -> CommandRouting
countedKeys name (_script:n:rest)
  | Just count <- decimal n
  , count <= length rest = routeKeys (take count rest)
  | otherwise = CommandError ("Malformed " ++ BS8.unpack name ++ " key count")
countedKeys name _ = arity name

zsetCount :: ByteString -> Bool -> [ByteString] -> CommandRouting
zsetCount name hasDestination args =
  case (hasDestination, args) of
    (True, destination:n:rest) -> counted (destination :) n rest
    (False, n:rest) -> counted id n rest
    _ -> CommandError ("Malformed " ++ BS8.unpack name ++ " key count/options")
  where
    counted add n rest
      | Just count <- decimal n
      , count > 0
      , count <= length rest
      , validZOptions (drop count rest) = routeKeys (add (take count rest))
      | otherwise = CommandError ("Malformed " ++ BS8.unpack name ++ " key count/options")

validZOptions :: [ByteString] -> Bool
validZOptions []                 = True
validZOptions ("WEIGHTS":xs)     = not (null xs) && all number xs
validZOptions ["AGGREGATE", agg] = upper agg `elem` ["SUM", "MIN", "MAX"]
validZOptions ["WITHSCORES"]     = True
validZOptions _                  = False

xread :: ByteString -> [ByteString] -> CommandRouting
xread name args =
  case break ((== "STREAMS") . upper) args of
    (_, []) -> CommandError ("Malformed " ++ BS8.unpack name ++ ": missing STREAMS")
    (prefix, _ : streams)
      | validXReadPrefix name prefix
      , even (length streams)
      , not (null streams) -> routeKeys (take (length streams `div` 2) streams)
      | otherwise -> CommandError ("Malformed " ++ BS8.unpack name ++ " STREAMS arguments")

validXReadPrefix :: ByteString -> [ByteString] -> Bool
validXReadPrefix name xs = go xs
  where
    go []                              = True
    go ("COUNT":n:rest)                = natural n && go rest
    go ("BLOCK":n:rest)                = natural n && go rest
    go ("NOACK":rest)                  = name == "XREADGROUP" && go rest
    go ("GROUP":_group:_consumer:rest) = name == "XREADGROUP" && go rest
    go _                               = False

blockingKeys :: ByteString -> [ByteString] -> CommandRouting
blockingKeys name args =
  case reverse args of
    timeout:keys | not (null keys) && number timeout -> routeKeys (reverse keys)
    _ -> CommandError ("Malformed " ++ BS8.unpack name)

xinfo :: [ByteString] -> CommandRouting
xinfo ["HELP"] = KeylessRoute
xinfo ["STREAM", key] = KeyedRoute key
xinfo ["STREAM", key, "FULL"] = KeyedRoute key
xinfo ["STREAM", key, "FULL", "COUNT", n] | natural n = KeyedRoute key
xinfo ["GROUPS", key] = KeyedRoute key
xinfo ["CONSUMERS", key, _group] = KeyedRoute key
xinfo _ = CommandError "Malformed XINFO command"

copy :: [ByteString] -> CommandRouting
copy (source:destination:options)
  | all (`elem` ["REPLACE", "DB"]) (map upper (filter (not . natural) options))
  , validCopyOptions options = MultiKeyRoute [source, destination]
  | otherwise = CommandError "Malformed COPY command"
copy _ = arity "COPY"

validCopyOptions :: [ByteString] -> Bool
validCopyOptions []                   = True
validCopyOptions ["REPLACE"]          = True
validCopyOptions ["DB", n]            = natural n
validCopyOptions ["REPLACE", "DB", n] = natural n
validCopyOptions ["DB", n, "REPLACE"] = natural n
validCopyOptions _                    = False

geoSearch :: [ByteString] -> CommandRouting
geoSearch (source:rest)
  | Just destination <- storeTarget rest = MultiKeyRoute [source, destination]
  | otherwise = KeyedRoute source
geoSearch _ = arity "GEOSEARCH"

geoRadius :: [ByteString] -> CommandRouting
geoRadius (source:_:_:_:_:rest)
  | Just destination <- storeTarget rest = MultiKeyRoute [source, destination]
  | otherwise = KeyedRoute source
geoRadius _ = arity "GEORADIUS"

storeTarget :: [ByteString] -> Maybe ByteString
storeTarget ("STORE":key:_)     = Just key
storeTarget ("STOREDIST":key:_) = Just key
storeTarget (_:xs)              = storeTarget xs
storeTarget []                  = Nothing

routeKeys :: [ByteString] -> CommandRouting
routeKeys []    = KeylessRoute
routeKeys [key] = KeyedRoute key
routeKeys keys  = MultiKeyRoute keys

everyOther :: [a] -> [a]
everyOther (x:_:xs) = x : everyOther xs
everyOther _        = []

upper :: ByteString -> ByteString
upper = BS8.map toUpper

arity :: ByteString -> CommandRouting
arity name = CommandError ("Malformed " ++ BS8.unpack name ++ " arity")

decimal :: ByteString -> Maybe Int
decimal bs | natural bs = Just (read (BS8.unpack bs))
           | otherwise = Nothing

natural :: ByteString -> Bool
natural bs = not (BS8.null bs) && BS8.all isDigit bs

positive :: ByteString -> Bool
positive bs = natural bs && bs /= "0"

number :: ByteString -> Bool
number bs =
  case BS8.unpack bs of
    ('-':rest) -> decimalText rest
    rest       -> decimalText rest
  where
    decimalText xs =
      case break (== '.') xs of
        (whole, []) -> not (null whole) && all isDigit whole
        (whole, '.':fraction) -> not (null whole) && not (null fraction)
                              && all isDigit whole && all isDigit fraction
        _ -> False
