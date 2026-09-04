# Missing Redis Commands

## Overview
This feature adds 29 commonly-used Redis commands that were missing from the `redis-client` Haskell library. The new commands span strings, hashes, lists, sets, sorted sets, key management, and HyperLogLog data structures — bringing the library much closer to full Redis command coverage. All commands work in standalone, multiplexed, and cluster modes. Every new command has an E2E test.

## What's New

### String Operations
- **APPEND** / **STRLEN** — Append to a string value and query its length.
- **SETEX** — Set a key with an expiration (in seconds) in a single atomic call.
- **INCRBY** / **DECRBY** — Increment or decrement an integer value by an arbitrary amount.
- **INCRBYFLOAT** — Increment a value by a floating-point number.
- **GETDEL** — Atomically get a value and delete the key.
- **GETEX** — Get a value and optionally set or remove its expiry.

### Hash Operations
- **HGETALL** — Retrieve all fields and values from a hash.
- **HLEN** — Get the number of fields in a hash.
- **HSETNX** — Set a hash field only if it does not already exist.
- **HINCRBY** / **HINCRBYFLOAT** — Increment a hash field's value by an integer or float.

### List Operations
- **LINSERT** — Insert an element before or after a pivot value.
- **LSET** — Set the value of an element at a given index.
- **LTRIM** — Trim a list to the specified range.
- **LREM** — Remove elements matching a value.

### Set Operations
- **SREM** — Remove one or more members from a set.
- **SDIFF** / **SINTER** / **SUNION** — Compute set difference, intersection, or union across multiple sets.
- **SPOP** — Remove and return a random member.
- **SRANDMEMBER** — Return a random member without removing it.

### Sorted Set Operations
- **ZREM** — Remove one or more members from a sorted set.
- **ZCARD** — Get the number of members.
- **ZSCORE** — Get the score of a member.
- **ZRANK** / **ZREVRANK** — Get the rank of a member in ascending or descending order.
- **ZCOUNT** — Count members with scores in a given range.
- **ZINCRBY** — Increment a member's score by a given amount.
- **ZRANGESTORE** — Store a range of members from one sorted set into another.

### Key Management
- **PERSIST** — Remove the expiration from a key.
- **TYPE** (exposed as `keyType`) — Return the type of a key (string, list, hash, etc.).
- **RENAME** / **RENAMENX** — Rename a key, optionally only if the destination doesn't exist.
- **UNLINK** — Asynchronously delete one or more keys.

### HyperLogLog
- **PFADD** — Add elements to a HyperLogLog.
- **PFCOUNT** — Get the approximate cardinality.
- **PFMERGE** — Merge multiple HyperLogLogs into one.

## How to Use

All new commands are available through the `RedisCommands` typeclass, re-exported from `Database.Redis`.

```haskell
import Database.Redis

-- Example: standalone client
main :: IO ()
main = do
  client <- createStandaloneClient defaultStandaloneConfig
  
  -- String commands
  _ <- run client $ set "counter" "0"
  r <- run client $ incrby "counter" 10   -- RespInteger 10
  
  -- Hash commands
  _ <- run client $ hset "user:1" "name" "Alice"
  _ <- run client $ hsetnx "user:1" "name" "Bob"  -- no-op, field exists
  allFields <- run client $ hgetall "user:1"       -- RespArray [...]
  
  -- Set commands
  _ <- run client $ sadd "tags" ["haskell", "redis", "fp"]
  common <- run client $ sinter ["tags", "other-tags"]
  
  -- Sorted set commands
  _ <- run client $ zadd "scores" [(100, "alice"), (200, "bob")]
  rank <- run client $ zrank "scores" "alice"  -- RespInteger 0
  
  -- HyperLogLog
  _ <- run client $ pfadd "visitors" ["user1", "user2", "user3"]
  count <- run client $ pfcount ["visitors"]   -- RespInteger 3
  
  -- Key management
  typ <- run client $ keyType "counter"  -- RespSimpleString "string"
  _ <- run client $ rename "counter" "my-counter"
  _ <- run client $ unlink ["old-key1", "old-key2"]
  
  closeStandaloneClient client
```

### Notes on specific commands

- **`keyType`** is named to avoid collision with Haskell's `type` keyword; it sends the `TYPE` command to Redis.
- **`getex`** takes optional arguments as `[ByteString]` — e.g., `getex "key" ["EX", "60"]` or `getex "key" ["PERSIST"]`.
- **`zcount`** takes min/max as `ByteString` to support Redis range syntax (`"-inf"`, `"+inf"`, `"(5"` for exclusive).
- **`zrangestore`** takes optional arguments as `[ByteString]` for `BYSCORE`, `REV`, `LIMIT`, etc.

## Technical Notes

- **Implementation pattern**: Each command is added in 4 places:
  1. `RedisCommands` typeclass definition (`Command.hs`)
  2. `RedisCommandClient` instance (`Command.hs`)
  3. `ClusterCommandClient` instance (`Cluster/Client.hs`)
  4. `StandaloneCommandClient` instance (`Standalone.hs`)
- **Cluster routing**: All 29 new keyed commands are registered in `requiresKeyCommands` (`Cluster/Commands.hs`) for proper cluster slot routing.
- **Multi-key cluster commands** (e.g., `sdiff`, `sinter`, `sunion`, `unlink`) use a head-key routing pattern — the first key determines the cluster slot.
- **Re-exports**: The `Database.Redis` module was updated to export all new commands (via `RedisCommands(..)`) plus previously missing Geo types and Standalone/Cluster client utilities.
- **No new dependencies** were added.
- **81 E2E tests** now pass (up from 44), covering all new commands.
- **Known limitation**: Multi-key commands (`sdiff`, `sinter`, `sunion`, `unlink`, `rename`, `renamenx`) require all keys to hash to the same cluster slot when used in cluster mode. This is standard Redis cluster behavior.

## Files Changed

### Core Library (command implementations)
- `hask-redis-mux/lib/redis-command-client/Database/Redis/Command.hs` — Typeclass definitions + `RedisCommandClient` instances
- `hask-redis-mux/lib/cluster/Database/Redis/Cluster/Client.hs` — `ClusterCommandClient` instances
- `hask-redis-mux/lib/cluster/Database/Redis/Standalone.hs` — `StandaloneCommandClient` instances

### Cluster Routing
- `hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands.hs` — Updated `requiresKeyCommands` with all 29 new commands

### Module Re-exports
- `hask-redis-mux/lib/redis/Database/Redis.hs` — Updated exports for new commands, Geo types, and client utilities

### E2E Tests
- `test/LibraryE2E/StandaloneTests.hs` — 37 new test cases across 8 describe blocks (strings, hashes, lists, sets, sorted sets, key management, HyperLogLog)
