{-# LANGUAGE OverloadedStrings #-}

-- | Checked-in Redis command key specifications used by cluster callers.
--
-- The authoritative source is Redis Open Source @7.2.12@
-- (@9913c926510755fa0d241658f550338a02258edb@), specifically the
-- machine-readable @src/commands/*.json@ metadata in
-- <https://github.com/redis/redis/tree/7.2.12/src/commands>.  Command
-- containers (for example @MEMORY USAGE@) are described by their individual
-- JSON files rather than their container's JSON file.
--
-- To audit an update reproducibly, extract the pinned tag with
--
-- @
-- curl -L https://github.com/redis/redis/archive/refs/tags/7.2.12.tar.gz | tar -xz
-- @
--
-- and compare every command below with its @key_specs@, @arity@, and (where
-- applicable) container JSON.  The table-driven assertions in
-- @ClusterTunnelSpec@ cover each routing form used here.  Unknown commands
-- deliberately fail closed; adding a Redis command requires adding its
-- authoritative metadata case and both valid and malformed test rows.
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
    "MSET"       -> everyOther 0
    "MSETNX"     -> everyOther 0
    "OBJECT"     -> objectKeys
    "MEMORY"     -> memoryKeys
    command | command `elem` destinationAndSourceCommands -> allFromMinimum 0 2
    command | command `elem` allKeyCommands -> allFrom 0
    command | command `elem` firstKeyCommands -> at 0
    command | command `elem` multiKeyCommands -> allFrom 0
    "EVAL"       -> evalKeys
    "EVALSHA"    -> evalKeys
    "FCALL"      -> evalKeys
    "FCALL_RO"   -> evalKeys
    "XREAD"      -> streamKeys
    "XREADGROUP" -> streamKeys
    "RENAME"     -> exactly 2
    "RENAMENX"   -> exactly 2
    "COPY"       -> exactly 2
    "XINFO"      -> xinfoKeys
    "ZUNIONSTORE"   -> destinationAndCount 1
    "ZINTERSTORE"   -> destinationAndCount 1
    "ZDIFFSTORE"    -> destinationAndCount 1
    "ZINTERCARD"    -> countOnly 0
    "LMPOP"         -> countOnly 0
    "BLMPOP"        -> countOnly 1
    "ZMPOP"         -> countOnly 0
    "BZMPOP"        -> countOnly 1
    "BITOP"         -> allFromMinimum 1 2
    "PFMERGE"       -> allFrom 0
    "SINTERCARD"    -> countOnly 0
    "ZUNION"        -> countOnly 0
    "ZINTER"        -> countOnly 0
    "ZDIFF"         -> countOnly 0
    "BZPOPMIN"      -> allButLast
    "BZPOPMAX"      -> allButLast
    "BLPOP"         -> allButLast
    "BRPOP"         -> allButLast
    "GEORADIUS"       -> geoRadiusKeys
    "GEORADIUSBYMEMBER" -> geoRadiusKeys
    _                 -> Left $ "unsupported command for cluster routing: " ++ BS8.unpack cmd
  where
    at n = case drop n args of
      (Just key:_) -> Right [key]
      (Nothing:_)  -> Left "cluster key arguments must be bulk strings"
      []           -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key argument"
    exactly count =
      let keys = take count args
      in if length keys == count
          then traverse requireKey keys
          else Left $ "command " ++ BS8.unpack cmd ++ " requires key arguments"

    allFrom n =
      case drop n args of
        []   -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key argument"
        keys -> traverse requireKey keys
    allFromMinimum n minimumKeys
      | length (drop n args) < minimumKeys =
          Left $ "command " ++ BS8.unpack cmd ++ " requires key arguments"
      | otherwise = traverse requireKey (drop n args)
    everyOther n
      | length (drop n args) < 2 || odd (length (drop n args)) =
          Left $ "command " ++ BS8.unpack cmd ++ " requires key-value pairs"
      | otherwise =
          traverse requireKey [value | (index, value) <- zip [0 :: Int ..] args, index >= n, even (index - n)]
    allButLast
      | length args < 2 = Left $ "command " ++ BS8.unpack cmd ++ " requires keys and a timeout"
      | otherwise  = traverse requireKey (init args)
    requireKey (Just key) = Right key
    requireKey Nothing    = Left "cluster key arguments must be bulk strings"

    countOnly offset = do
      count <- decimalAt offset
      if count < 1
        then Left $ "command " ++ BS8.unpack cmd ++ " requires a positive key count"
        else Right ()
      keys <- traverse requireKey (take count (drop (offset + 1) args))
      if length keys == count
        then Right keys
        else Left $ "command " ++ BS8.unpack cmd ++ " has fewer keys than its key count"

    destinationAndCount countOffset = do
      destination <- at 0
      count <- decimalAt countOffset
      if count < 1
        then Left $ "command " ++ BS8.unpack cmd ++ " requires a positive key count"
        else Right ()
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

    objectKeys = case args of
      [Just subcommand]
        | upper subcommand == "HELP" -> Right []
      [Just subcommand, key]
        | upper subcommand `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] ->
            traverse requireKey [key]
      _ -> Left "command OBJECT has an invalid subcommand or arity"

    memoryKeys = case args of
      [Just subcommand]
        | upper subcommand `elem` ["DOCTOR", "HELP", "MALLOC-STATS", "PURGE", "STATS"] ->
            Right []
      [Just subcommand, key]
        | upper subcommand == "USAGE" -> traverse requireKey [key]
      [Just subcommand, key, Just samples, Just count]
        | upper subcommand == "USAGE" && upper samples == "SAMPLES" -> do
            routedKey <- requireKey key
            nonNegativeInteger count "MEMORY USAGE has an invalid sample count"
            Right [routedKey]
      _ -> Left "command MEMORY has an invalid subcommand or arity"

    xinfoKeys = case args of
      [Just subcommand]
        | upper subcommand == "HELP" -> Right []
      (Just subcommand : key : rest)
        | upper subcommand == "STREAM" -> do
            routedKey <- requireKey key
            xinfoStreamOptions rest
            Right [routedKey]
        | upper subcommand == "GROUPS" && null rest -> traverse requireKey [key]
        | upper subcommand == "CONSUMERS" && length rest == 1 ->
            traverse requireKey [key]
      _ -> Left "command XINFO has an invalid subcommand or arity"

    xinfoStreamOptions [] = Right ()
    xinfoStreamOptions [Just full]
      | upper full == "FULL" = Right ()
    xinfoStreamOptions [Just full, Just countKeyword, Just count]
      | upper full == "FULL" && upper countKeyword == "COUNT" =
          nonNegativeInteger count "XINFO STREAM has an invalid count"
    xinfoStreamOptions _ = Left "command XINFO STREAM has an invalid option list"

    geoRadiusKeys = do
      source <- at 0
      let requiredArguments =
            if upper cmd == "GEORADIUS" then 5 else 4
      if length args < requiredArguments
        then Left $ "command " ++ BS8.unpack cmd ++ " requires location arguments"
        else Right ()
      let options = drop requiredArguments args
      destinations <- geoDestinations options
      Right (source ++ destinations)

    geoDestinations [] = Right []
    geoDestinations (Just option : destination : rest)
      | upper option `elem` ["STORE", "STOREDIST"] = do
          key <- requireKey destination
          (key :) <$> geoDestinations rest
    geoDestinations [Just option]
      | upper option `elem` ["STORE", "STOREDIST"] =
          Left "command has a STORE option without a destination key"
    geoDestinations (Nothing : _) = Left "command has a non-bulk option"
    geoDestinations (_ : rest) = geoDestinations rest

    upper = BS8.map toUpper

    nonNegativeInteger value errorMessage =
      case BS8.readInt value of
        Just (count, "") | count >= 0 -> Right ()
        _                             -> Left errorMessage

    decimalAt n = case drop n args of
      (Just value:_) -> case BS8.readInt value of
        Just (count, "") | count >= 0 -> Right count
        _ -> Left $ "command " ++ BS8.unpack cmd ++ " has an invalid key count"
      _ -> Left $ "command " ++ BS8.unpack cmd ++ " requires a key count"

keylessCommands :: [ByteString]
keylessCommands =
  [ "PING", "ECHO", "AUTH", "HELLO", "QUIT", "SELECT", "RESET", "UNWATCH"
  , "INFO", "TIME", "ROLE", "LASTSAVE", "DBSIZE", "LATENCY"
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
  , "TTL", "PTTL", "PERSIST", "TYPE"
  , "HGET", "HSET", "HDEL", "HGETALL", "HKEYS", "HVALS", "HEXISTS"
  , "HLEN", "HINCRBY", "HINCRBYFLOAT", "HMGET", "HMSET", "HRANDFIELD"
  , "LPUSH", "RPUSH", "LPOP", "RPOP", "LLEN", "LINDEX", "LRANGE", "LTRIM"
  , "LSET", "LREM", "LPOS", "SADD", "SREM", "SMEMBERS", "SCARD"
  , "SISMEMBER", "SMISMEMBER", "SRANDMEMBER", "SPOP", "ZADD", "ZREM"
  , "ZRANGE", "ZREVRANGE", "ZRANK", "ZREVRANK", "ZSCORE", "ZCARD"
  , "ZCOUNT", "ZLEXCOUNT", "ZRANDMEMBER", "ZINCRBY", "XADD", "XLEN"
  , "XRANGE", "XREVRANGE", "XDEL", "XTRIM", "XACK", "XPENDING", "XCLAIM"
  , "XAUTOCLAIM", "GEOADD", "GEOPOS", "GEODIST", "GEOHASH"
  , "BITCOUNT", "GETBIT", "SETBIT", "BITFIELD", "BITFIELD_RO", "PFADD"
  , "DUMP", "RESTORE"
  ]

allKeyCommands :: [ByteString]
allKeyCommands =
  ["DEL", "EXISTS", "MGET", "SUNION", "SINTER", "SDIFF"]

destinationAndSourceCommands :: [ByteString]
destinationAndSourceCommands = ["SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE"]

-- These Redis 7.2 key specs have a range ending at the final argument.
multiKeyCommands :: [ByteString]
multiKeyCommands = ["PFCOUNT", "TOUCH", "UNLINK", "WATCH"]
