# PRD: Implement Missing Core Redis Commands

## Overview
The hask-redis-mux library currently implements 49 Redis commands in the `RedisCommands` typeclass. Many commonly-used core Redis commands are missing. This PRD covers adding the most impactful missing commands following the existing patterns.

## Current State
- 49 commands in `RedisCommands` typeclass (Command.hs line 109-158)
- Standalone impl: `RedisCommandClient` instance (Command.hs line 319-412)
- Cluster impl: `ClusterCommandClient` instance (Cluster/Client.hs line 547-631)
- Pattern: add typeclass method → implement `executeCommandAs` → implement `executeKeyedAs`/`executeKeyless`

## Commands to Implement

### String Commands (8)
- `APPEND key value` → Integer (length after append)
- `STRLEN key` → Integer
- `SETEX key seconds value` → Status (SET with EX)
- `INCRBY key increment` → Integer
- `DECRBY key decrement` → Integer
- `INCRBYFLOAT key increment` → BulkString
- `GETDEL key` → BulkString or Nil
- `GETEX key [EX seconds | PX ms | EXAT timestamp | PXAT ms-timestamp | PERSIST]` → BulkString

### Hash Commands (5)
- `HGETALL key` → Array (alternating field/value pairs)
- `HLEN key` → Integer
- `HSETNX key field value` → Integer (0 or 1)
- `HINCRBY key field increment` → Integer
- `HINCRBYFLOAT key field increment` → BulkString

### List Commands (4)
- `LINSERT key BEFORE|AFTER pivot element` → Integer
- `LSET key index element` → Status
- `LTRIM key start stop` → Status
- `LREM key count element` → Integer

### Set Commands (6)
- `SREM key member [member ...]` → Integer
- `SDIFF key [key ...]` → Array
- `SINTER key [key ...]` → Array
- `SUNION key [key ...]` → Array
- `SPOP key [count]` → BulkString or Array
- `SRANDMEMBER key [count]` → BulkString or Array

### Sorted Set Commands (8)
- `ZREM key member [member ...]` → Integer
- `ZCARD key` → Integer
- `ZSCORE key member` → BulkString (double as string)
- `ZRANK key member` → Integer or Nil
- `ZREVRANK key member` → Integer or Nil
- `ZCOUNT key min max` → Integer
- `ZINCRBY key increment member` → BulkString
- `ZRANGESTORE dst src min max [BYSCORE|BYLEX] [REV] [LIMIT offset count]` → Integer

### Key Commands (5)
- `PERSIST key` → Integer (0 or 1)
- `TYPE key` → Status string
- `RENAME key newkey` → Status
- `RENAMENX key newkey` → Integer (0 or 1)
- `UNLINK key [key ...]` → Integer

### HyperLogLog Commands (3)
- `PFADD key [element ...]` → Integer (0 or 1)
- `PFCOUNT key [key ...]` → Integer
- `PFMERGE destkey sourcekey [sourcekey ...]` → Status

## Implementation Pattern

For each command, three changes are needed:

1. **Command.hs typeclass** (line ~109-158): Add method signature
2. **Command.hs RedisCommandClient instance** (line ~319-412): Implement with `executeCommandAs`
3. **Cluster/Client.hs ClusterCommandClient instance** (line ~547-631): Implement with `executeKeyedAs` or `executeKeyless`

All commands use `(FromResp a) =>` for polymorphic returns. Keys and values are `ByteString`.
