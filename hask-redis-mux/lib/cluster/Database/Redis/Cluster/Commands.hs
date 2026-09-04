{-# LANGUAGE OverloadedStrings #-}

-- | Checked-in Redis command key specifications used by cluster callers.
module Database.Redis.Cluster.Commands
  ( keylessCommands
  , requiresKeyCommands
  , CommandRouting (..)
  , classifyCommand
  , keyArguments
  , keyArgumentsFromResp
  ) where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS8
import           Data.Char             (toUpper)
import           Database.Redis.Resp   (RespData (..))

data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | CommandError String
  deriving (Eq, Show)

-- | Compatibility classification for callers which route only one key.
classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  case keyArguments cmd args of
    Left err      -> CommandError err
    Right []      -> KeylessRoute
    Right (key:_) -> KeyedRoute key

-- | Extract every key from a command's bulk-string arguments.  Unknown
-- commands deliberately fail closed: routing an unrecognised command by its
-- first argument is not safe in a cluster.
keyArguments :: ByteString -> [ByteString] -> Either String [ByteString]
keyArguments cmd args = keyArgumentsWith cmd (map Just args)

-- | RESP-aware version of 'keyArguments'.  Non-key RESP values are allowed so
-- the tunnel can forward the original frame byte-for-byte; a value used as a
-- key must be a bulk string.
keyArgumentsFromResp :: ByteString -> [RespData] -> Either String [ByteString]
keyArgumentsFromResp cmd = keyArgumentsWith cmd . map asBulk
  where
    asBulk (RespBulkString value) = Just value
    asBulk _                      = Nothing

keyArgumentsWith :: ByteString -> [Maybe ByteString] -> Either String [ByteString]
keyArgumentsWith cmd args =
  case BS8.map toUpper cmd of
    command | command `elem` keylessCommands -> Right []
    command | command `elem` firstKeyCommands -> at 0
    command | command `elem` allKeyCommands -> allFrom 0
    "MSET"       -> everyOther 0
    "MSETNX"     -> everyOther 0
    "EVAL"       -> evalKeys
    "EVALSHA"    -> evalKeys
    "FCALL"      -> evalKeys
    "FCALL_RO"   -> evalKeys
    "XREAD"      -> streamKeys
    "XREADGROUP" -> streamKeys
    "ZUNIONSTORE"   -> destinationAndCount 1
    "ZINTERSTORE"   -> destinationAndCount 1
    "ZDIFFSTORE"    -> destinationAndCount 1
    "ZINTERCARD"    -> countOnly 0
    "LMPOP"         -> countOnly 0
    "BLMPOP"        -> countOnly 1
    "ZMPOP"         -> countOnly 0
    "BZMPOP"        -> countOnly 1
    "BITOP"         -> allFrom 1
    "PFMERGE"       -> allFrom 0
    "SINTERCARD"    -> countOnly 0
    "BZPOPMIN"      -> allButLast
    "BZPOPMAX"      -> allButLast
    "BLPOP"         -> allButLast
    "BRPOP"         -> allButLast
    _             -> Left $ "unsupported command for cluster routing: " ++ BS8.unpack cmd
  where
    at n = case drop n args of
      (Just key:_) -> Right [key]
      (Nothing:_)  -> Left "cluster key arguments must be bulk strings"
      []           -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key argument"

    allFrom n =
      case drop n args of
        []   -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key argument"
        keys -> traverse requireKey keys
    everyOther n = traverse requireKey [value | (index, value) <- zip [0 :: Int ..] args, index >= n, even (index - n)]
    allButLast
      | null args  = Left $ "command " ++ BS8.unpack cmd ++ " requires a key argument"
      | otherwise  = traverse requireKey (init args)
    requireKey (Just key) = Right key
    requireKey Nothing    = Left "cluster key arguments must be bulk strings"

    countOnly offset = do
      count <- decimalAt offset
      traverse requireKey (take count (drop (offset + 1) args))

    destinationAndCount countOffset = do
      destination <- at 0
      count <- decimalAt countOffset
      sources <- traverse requireKey (take count (drop (countOffset + 1) args))
      if length sources == count
        then Right (destination ++ sources)
        else Left $ "command " ++ BS8.unpack cmd ++ " has fewer keys than its key count"

    evalKeys = do
      count <- decimalAt 1
      keys <- traverse requireKey (take count (drop 2 args))
      if length keys == count
        then Right keys
        else Left $ "command " ++ BS8.unpack cmd ++ " has fewer keys than its key count"

    streamKeys =
      case break isStreams args of
        (_, []) -> Left $ "command " ++ BS8.unpack cmd ++ " requires a STREAMS key list"
        (_, _:streamArgs)
          | null streamArgs || odd (length streamArgs) ->
              Left $ "command " ++ BS8.unpack cmd ++ " requires matching stream keys and IDs"
          | otherwise -> traverse requireKey (take (length streamArgs `div` 2) streamArgs)
    isStreams (Just value) = BS8.map toUpper value == "STREAMS"
    isStreams Nothing      = False

    decimalAt n = case drop n args of
      (Just value:_) -> case BS8.readInt value of
        Just (count, "") | count >= 0 -> Right count
        _ -> Left $ "command " ++ BS8.unpack cmd ++ " has an invalid key count"
      _ -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key count"

keylessCommands :: [ByteString]
keylessCommands =
  [ "PING", "ECHO", "AUTH", "HELLO", "QUIT", "SELECT", "RESET"
  , "INFO", "TIME", "ROLE", "LASTSAVE", "DBSIZE", "MEMORY", "LATENCY"
  , "CLIENT", "CONFIG", "COMMAND", "CLUSTER", "ACL", "SLOWLOG"
  , "BGSAVE", "BGREWRITEAOF", "SAVE", "SHUTDOWN", "REPLICAOF", "SLAVEOF"
  , "FLUSHALL", "FLUSHDB", "PUBSUB", "MONITOR", "SCRIPT", "FUNCTION"
  ]

-- Kept exported for existing users; this is the fixed-first-key subset.
requiresKeyCommands :: [ByteString]
requiresKeyCommands = firstKeyCommands

firstKeyCommands :: [ByteString]
firstKeyCommands =
  [ "GET", "SET", "SETNX", "SETEX", "PSETEX", "GETEX", "GETDEL", "APPEND"
  , "STRLEN", "GETRANGE", "SETRANGE", "INCR", "INCRBY", "INCRBYFLOAT"
  , "DECR", "DECRBY", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT"
  , "TTL", "PTTL", "PERSIST", "TYPE", "RENAME", "RENAMENX", "COPY"
  , "HGET", "HSET", "HDEL", "HGETALL", "HKEYS", "HVALS", "HEXISTS"
  , "HLEN", "HINCRBY", "HINCRBYFLOAT", "HMGET", "HMSET", "HRANDFIELD"
  , "LPUSH", "RPUSH", "LPOP", "RPOP", "LLEN", "LINDEX", "LRANGE", "LTRIM"
  , "LSET", "LREM", "LPOS", "SADD", "SREM", "SMEMBERS", "SCARD"
  , "SISMEMBER", "SMISMEMBER", "SRANDMEMBER", "SPOP", "ZADD", "ZREM"
  , "ZRANGE", "ZREVRANGE", "ZRANK", "ZREVRANK", "ZSCORE", "ZCARD"
  , "ZCOUNT", "ZLEXCOUNT", "ZRANDMEMBER", "ZINCRBY", "XADD", "XLEN"
  , "XRANGE", "XREVRANGE", "XDEL", "XTRIM", "XACK", "XPENDING", "XCLAIM"
  , "XAUTOCLAIM", "XINFO", "GEOADD", "GEOPOS", "GEODIST", "GEOHASH"
  , "GEORADIUS", "GEORADIUSBYMEMBER", "BITCOUNT", "GETBIT", "SETBIT"
  , "BITFIELD", "BITFIELD_RO", "PFADD", "PFCOUNT", "DUMP", "RESTORE"
  , "OBJECT", "TOUCH", "UNLINK", "WATCH"
  ]

allKeyCommands :: [ByteString]
allKeyCommands =
  [ "DEL", "EXISTS", "MGET", "SUNION", "SINTER", "SDIFF", "SINTERSTORE"
  , "SUNIONSTORE", "SDIFFSTORE", "ZUNION", "ZINTER", "ZDIFF"
  ]
