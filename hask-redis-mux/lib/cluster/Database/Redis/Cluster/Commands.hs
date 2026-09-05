{-# LANGUAGE OverloadedStrings #-}

-- | Generated-from Redis command key-spec subset used by the smart proxy.
-- The provenance and reproducible audit procedure are in
-- @data/redis-7.2.12-command-metadata@.
module Database.Redis.Cluster.Commands
  ( CommandRouting (..)
  , classifyCommand
  , commandForms
  ) where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS8
import           Data.Char             (toUpper)

data CommandRouting
  = KeylessRoute
  | KeyedRoute [ByteString]
  | CommandError String
  deriving (Eq, Show)

-- | The command forms represented by the checked-in Redis 7.2.12 metadata.
-- Tests deliberately enumerate this list, so adding metadata requires adding
-- an extraction/arity test at the same time.
commandForms :: [ByteString]
commandForms =
  [ "PING", "ECHO", "AUTH", "INFO", "TIME", "COMMAND", "CLUSTER", "CLIENT"
  , "GET", "SET", "MEMORY USAGE", "RENAME", "RENAMENX", "COPY"
  , "DEL", "EXISTS", "MGET", "PFCOUNT", "TOUCH", "UNLINK", "WATCH", "MSET"
  , "BLPOP", "BRPOP", "BZPOPMIN", "BZPOPMAX"
  , "ZUNION", "ZINTER", "ZDIFF", "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE"
  , "EVAL", "EVALSHA", "FCALL", "FCALL_RO"
  , "XREAD", "XREADGROUP", "XINFO STREAM", "XINFO GROUPS", "XINFO CONSUMERS"
  , "OBJECT ENCODING", "OBJECT FREQ", "OBJECT IDLETIME", "OBJECT REFCOUNT"
  , "GEOSEARCH", "GEOSEARCHSTORE", "GEORADIUS", "GEORADIUSBYMEMBER"
  ]

classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand command arguments =
  let cmd = upper command
      args = arguments
  in if BS8.null cmd then bad "missing command" else
    if cmd `elem` keyless then keylessArity cmd args
    else if cmd == "GET" then exact 1 cmd args
    else if cmd == "MEMORY" then memory args
    else if cmd `elem` firstKey then fixed 1 cmd args
    else if cmd `elem` multiKey then nonEmpty cmd args
    else if cmd == "MSET" then pairs cmd args
    else if cmd `elem` ["RENAME", "RENAMENX"] then exact 2 cmd args
    else if cmd == "COPY" then fixed 2 cmd args
    else if cmd `elem` ["BLPOP", "BRPOP", "BZPOPMIN", "BZPOPMAX"] then blocking cmd args
    else if cmd `elem` ["ZUNION", "ZINTER", "ZDIFF"] then counted cmd 0 args
    else if cmd `elem` ["ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE"] then counted cmd 1 args
    else if cmd `elem` ["EVAL", "EVALSHA", "FCALL", "FCALL_RO"] then scripted cmd args
    else if cmd == "XREAD" then xread cmd args
    else if cmd == "XREADGROUP" then xreadGroup args
    else if cmd == "XINFO" then xinfo args
    else if cmd == "OBJECT" then object args
    else if cmd == "GEOSEARCH" then fixed 1 cmd args
    else if cmd `elem` ["GEORADIUS", "GEORADIUSBYMEMBER"] then geoRadius cmd args
    else if cmd == "GEOSEARCHSTORE" then fixed 2 cmd args
    else bad ("unsupported command " ++ BS8.unpack cmd)
  where
    -- Keyless commands are deliberately explicit: unknown commands never
    -- acquire a routing key merely because they have arguments.
    keyless = ["PING", "ECHO", "AUTH", "INFO", "TIME", "COMMAND", "CLUSTER", "CLIENT"]
    firstKey =
      [ "GET", "SET", "APPEND", "DECR", "INCR", "HGET", "HSET"
      , "LPUSH", "RPUSH", "SADD", "ZADD", "EXPIRE", "TTL", "PERSIST"
      , "XADD", "XRANGE", "XREVRANGE", "XLEN", "XTRIM", "PFADD"
      ]
    multiKey = ["DEL", "EXISTS", "MGET", "PFCOUNT", "TOUCH", "UNLINK", "WATCH"]

keylessArity :: ByteString -> [ByteString] -> CommandRouting
keylessArity cmd args
  | cmd == "ECHO" && length args /= 1 = bad "ECHO requires exactly one argument"
  | cmd == "PING" && length args > 1 = bad "PING accepts at most one argument"
  | cmd == "AUTH" && length args `notElem` [1, 2] = bad "AUTH requires one or two arguments"
  | otherwise = KeylessRoute

fixed :: Int -> ByteString -> [ByteString] -> CommandRouting
fixed n cmd args
  | length args < n = bad $ BS8.unpack cmd ++ " has too few arguments"
  | otherwise = KeyedRoute (take n args)

exact :: Int -> ByteString -> [ByteString] -> CommandRouting
exact n cmd args
  | length args /= n = bad $ BS8.unpack cmd ++ " has an invalid argument count"
  | otherwise = KeyedRoute args

nonEmpty :: ByteString -> [ByteString] -> CommandRouting
nonEmpty cmd [] = bad $ BS8.unpack cmd ++ " requires at least one key"
nonEmpty _ args = KeyedRoute args

pairs :: ByteString -> [ByteString] -> CommandRouting
pairs cmd args
  | null args || odd (length args) = bad $ BS8.unpack cmd ++ " requires key/value pairs"
  | otherwise = KeyedRoute (everyOther args)

blocking :: ByteString -> [ByteString] -> CommandRouting
blocking cmd args
  | length args < 2 = bad $ BS8.unpack cmd ++ " requires one or more keys and a timeout"
  | readNatural (last args) == Nothing = bad $ BS8.unpack cmd ++ " has an invalid timeout"
  | otherwise = KeyedRoute (init args)

counted :: ByteString -> Int -> [ByteString] -> CommandRouting
counted cmd countOffset args
  | length args <= countOffset = bad $ BS8.unpack cmd ++ " is missing its key count"
  | otherwise =
      case readNatural (args !! countOffset) of
        Nothing -> bad $ BS8.unpack cmd ++ " has an invalid key count"
        Just count
          | count <= 0 -> bad $ BS8.unpack cmd ++ " key count must be positive"
          | length args < countOffset + 1 + count -> bad $ BS8.unpack cmd ++ " has fewer keys than declared"
          | otherwise ->
              let keys = take count (drop (countOffset + 1) args)
              in KeyedRoute (if countOffset == 0 then keys else take 1 args <> keys)

scripted :: ByteString -> [ByteString] -> CommandRouting
scripted cmd args
  | length args < 2 = bad $ BS8.unpack cmd ++ " is missing its key count"
  | otherwise =
      case readNatural (args !! 1) of
        Nothing -> bad $ BS8.unpack cmd ++ " has an invalid key count"
        Just count
          | length args < 2 + count -> bad $ BS8.unpack cmd ++ " has fewer keys than declared"
          | count == 0 -> KeylessRoute
          | otherwise -> KeyedRoute (take count (drop 2 args))

xread :: ByteString -> [ByteString] -> CommandRouting
xread cmd = streams cmd

xreadGroup :: [ByteString] -> CommandRouting
xreadGroup (group : _group : _consumer : rest) | upper group == "GROUP" = streams "XREADGROUP" rest
xreadGroup _ = bad "XREADGROUP requires GROUP, group, consumer, and STREAMS"

streams :: ByteString -> [ByteString] -> CommandRouting
streams cmd args =
  case break ((== "STREAMS") . upper) args of
    (_, []) -> bad $ BS8.unpack cmd ++ " requires STREAMS"
    (prefix, _ : streamArgs)
      | not (validXreadPrefix cmd prefix) -> bad $ BS8.unpack cmd ++ " has malformed options"
      | null streamArgs || odd (length streamArgs) -> bad $ BS8.unpack cmd ++ " requires equal stream and id counts"
      | otherwise -> KeyedRoute (take (length streamArgs `div` 2) streamArgs)

xinfo :: [ByteString] -> CommandRouting
xinfo (sub : _) | upper sub == "HELP" = KeylessRoute
xinfo (sub : args)
  | upper sub `elem` ["STREAM", "GROUPS"] = fixed 1 "XINFO" args
  | upper sub == "CONSUMERS" = keyWithArguments 2 "XINFO CONSUMERS" args
  | otherwise = bad "unsupported XINFO subcommand"
xinfo _ = bad "XINFO requires a subcommand"

object :: [ByteString] -> CommandRouting
object (sub : _) | upper sub == "HELP" = KeylessRoute
object (sub : args)
  | upper sub `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] = fixed 1 "OBJECT" args
  | otherwise = bad "unsupported OBJECT subcommand"
object _ = bad "OBJECT requires a subcommand"

memory :: [ByteString] -> CommandRouting
memory (sub : args)
  | upper sub == "HELP" = KeylessRoute
  | upper sub == "USAGE" = fixed 1 "MEMORY USAGE" args
  | otherwise = bad "unsupported MEMORY subcommand"
memory _ = bad "MEMORY requires a subcommand"

geoRadius :: ByteString -> [ByteString] -> CommandRouting
geoRadius cmd args =
  case args of
    [] -> bad $ BS8.unpack cmd ++ " requires a key"
    source : rest ->
      case dropWhile (\arg -> upper arg /= "STORE" && upper arg /= "STOREDIST") rest of
        [] -> KeyedRoute [source]
        _ : destination : _ -> KeyedRoute [source, destination]
        _ -> bad $ BS8.unpack cmd ++ " STORE requires a destination key"

keyWithArguments :: Int -> ByteString -> [ByteString] -> CommandRouting
keyWithArguments n cmd args
  | length args < n = bad $ BS8.unpack cmd ++ " has too few arguments"
  | otherwise = KeyedRoute (take 1 args)

validXreadPrefix :: ByteString -> [ByteString] -> Bool
validXreadPrefix command = go
  where
    go [] = True
    go (option : value : rest)
      | upper option `elem` ["COUNT", "BLOCK"]
      , readNatural value /= Nothing = go rest
    go (option : rest)
      | command == "XREADGROUP", upper option == "NOACK" = go rest
    go _ = False

everyOther :: [a] -> [a]
everyOther (x : _ : xs) = x : everyOther xs
everyOther _            = []

readNatural :: ByteString -> Maybe Int
readNatural bs = case BS8.readInt bs of
  Just (n, rest) | n >= 0 && BS8.null rest -> Just n
  _                                        -> Nothing

upper :: ByteString -> ByteString
upper = BS8.map toUpper

bad :: String -> CommandRouting
bad = CommandError
