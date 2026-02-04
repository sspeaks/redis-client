{-# LANGUAGE OverloadedStrings #-}

-- | Shared command classification for cluster routing
-- This module provides lists of Redis commands categorized by their routing requirements
module ClusterCommands
  ( keylessCommands,
    requiresKeyCommands,
  )
where

import Data.ByteString (ByteString)

-- | Commands that don't require a key argument (route to any master node)
-- These commands can be executed on any master node in the cluster
-- Note: This list is based on Redis 7.x commands and may need updates for newer versions
-- See CLUSTERING_IMPLEMENTATION_PLAN.md Phase 15 for future work on eliminating this hardcoded list
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
-- See CLUSTERING_IMPLEMENTATION_PLAN.md Phase 15 for future work on eliminating this hardcoded list
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
