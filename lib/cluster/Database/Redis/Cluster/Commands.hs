{-# LANGUAGE OverloadedStrings #-}

-- | Shared command classification for cluster routing
-- This module provides lists of Redis commands categorized by their routing requirements
module Database.Redis.Cluster.Commands
  ( keylessCommands,
    requiresKeyCommands,
    CommandRouting (..),
    classifyCommand,
  )
where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS8
import           Data.Char             (toUpper)

-- | Result of classifying a command for cluster routing
data CommandRouting
  = KeylessRoute        -- ^ Route to any master node
  | KeyedRoute ByteString  -- ^ Route by this key's hash slot
  | CommandError String    -- ^ Invalid command (e.g., missing required key)

-- | Classify a Redis command for cluster routing.
-- Returns 'KeylessRoute' for commands like PING or AUTH that can go to any master,
-- 'KeyedRoute' with the routing key for commands that target a specific slot,
-- or 'CommandError' if a key-requiring command is missing its key argument.
classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  let cmdUpper = BS8.map toUpper cmd
  in if cmdUpper `elem` keylessCommands
     then KeylessRoute
     else case args of
       [] -> if cmdUpper `elem` requiresKeyCommands
               then CommandError $ "Command " ++ BS8.unpack cmd ++ " requires a key argument"
               else KeylessRoute  -- Unknown command without args, try keyless
       (key:_) -> KeyedRoute key

-- | Commands that don't require a key argument (route to any master node)
-- These commands can be executed on any master node in the cluster
-- Note: This list is based on Redis 7.x commands and may need updates for newer versions
-- See CLUSTERING_IMPLEMENTATION_PLAN.md Phase 17 for future work on eliminating this hardcoded list
keylessCommands :: [ByteString]
keylessCommands =
  [ "PING",
    "AUTH",
    "FLUSHALL",
    "FLUSHDB",
    "DBSIZE",
    "CLUSTER",
    "INFO",
    "TIME",
    "CLIENT",
    "CONFIG",
    "BGREWRITEAOF",
    "BGSAVE",
    "SAVE",
    "LASTSAVE",
    "SHUTDOWN",
    "SLAVEOF",
    "REPLICAOF",
    "ROLE",
    "ECHO",
    "SELECT",
    "QUIT",
    "COMMAND"
  ]

-- | Commands that require a key argument (route by key's hash slot)
-- These commands must be routed to the node responsible for the key's hash slot
-- Note: This list is based on Redis 7.x commands and may need updates for newer versions
-- See CLUSTERING_IMPLEMENTATION_PLAN.md Phase 17 for future work on eliminating this hardcoded list
requiresKeyCommands :: [ByteString]
requiresKeyCommands =
  [ "GET",
    "SET",
    "DEL",
    "EXISTS",
    "INCR",
    "DECR",
    "HGET",
    "HSET",
    "HDEL",
    "HKEYS",
    "HVALS",
    "HGETALL",
    "HEXISTS",
    "LPUSH",
    "RPUSH",
    "LPOP",
    "RPOP",
    "LRANGE",
    "LLEN",
    "LINDEX",
    "SADD",
    "SREM",
    "SMEMBERS",
    "SCARD",
    "SISMEMBER",
    "ZADD",
    "ZREM",
    "ZRANGE",
    "ZCARD",
    "EXPIRE",
    "TTL",
    "PERSIST",
    "MGET",
    "MSET",
    "SETNX",
    "PSETEX",
    "APPEND",
    "GETRANGE",
    "SETRANGE",
    "STRLEN",
    "GETEX",
    "GETDEL",
    "SETEX"
  ]
