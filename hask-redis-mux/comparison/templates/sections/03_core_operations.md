# 3. Core Operations

## 3.1 GET / SET / DEL

### Haskell (hask-redis-mux)

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Database.Redis

main :: IO ()
main = withStandaloneClient defaultStandaloneConfig $ \client ->
  runStandaloneClient client $ do
    -- SET returns Bool (True from +OK)
    (ok :: Bool) <- set "user:1:name" "Alice"

    -- GET with typed return
    (name :: ByteString) <- get "user:1:name"    -- "Alice"
    (missing :: Maybe ByteString) <- get "no:key" -- Nothing

    -- DEL takes a list of keys, returns Integer (count deleted)
    (n :: Integer) <- del ["user:1:name", "no:key"]
    return n  -- 1
```

### C# (StackExchange.Redis)

```csharp
IDatabase db = connection.GetDatabase();

bool ok = await db.StringSetAsync("user:1:name", "Alice");

RedisValue name = await db.StringGetAsync("user:1:name");    // "Alice"
RedisValue missing = await db.StringGetAsync("no:key");       // RedisValue.Null

bool deleted = await db.KeyDeleteAsync("user:1:name");        // true
// Bulk delete:
long count = await db.KeyDeleteAsync(new RedisKey[] { "k1", "k2" });
```

> **Comparison:** hask-redis-mux returns typed values at compile time via `FromResp`. StackExchange.Redis returns `RedisValue` which must be cast at runtime. hask-redis-mux's `del` mirrors the Redis DEL command (accepts a list), while StackExchange.Redis has both single-key (`KeyDeleteAsync(key)`) and multi-key overloads.

## 3.2 PING

### Haskell (hask-redis-mux)

```haskell
runStandaloneClient client $ do
  (reply :: ByteString) <- ping  -- "PONG"
  return reply
```

### C# (StackExchange.Redis)

```csharp
TimeSpan latency = await db.PingAsync();  // Returns round-trip time
```

> **Comparison:** hask-redis-mux's `ping` returns the RESP response ("PONG"). StackExchange.Redis's `PingAsync` measures and returns round-trip latency directly.

## 3.3 Pipelining

### Haskell (hask-redis-mux)

```haskell
-- hask-redis-mux pipelines implicitly via the multiplexer.
-- Concurrent commands from multiple green threads are batched
-- automatically over the shared TCP connection.

import Control.Concurrent.Async (concurrently)

main :: IO ()
main = withStandaloneClient defaultStandaloneConfig $ \client -> do
  -- These two commands are pipelined automatically
  (a, b) <- concurrently
    (runStandaloneClient client $ get "key1" :: IO ByteString)
    (runStandaloneClient client $ get "key2" :: IO ByteString)
  print (a, b)
```

### C# (StackExchange.Redis)

```csharp
// Explicit batching
IBatch batch = db.CreateBatch();
Task<RedisValue> t1 = batch.StringGetAsync("key1");
Task<RedisValue> t2 = batch.StringGetAsync("key2");
batch.Execute();
RedisValue v1 = await t1;
RedisValue v2 = await t2;

// Or fire-and-forget (no response):
db.StringSet("key", "value", flags: CommandFlags.FireAndForget);
```

> **Comparison:** hask-redis-mux's multiplexer automatically batches commands from concurrent threads — no explicit batch API needed. StackExchange.Redis requires `CreateBatch()` for explicit pipelining or uses fire-and-forget for one-way commands.

## 3.4 TTL / Expiry

### Haskell (hask-redis-mux)

```haskell
runStandaloneClient client $ do
  set "session:abc" "data"
  (ok :: Bool) <- expire "session:abc" 300       -- 300 seconds TTL
  (remaining :: Integer) <- ttl "session:abc"     -- seconds remaining
  return remaining
```

### C# (StackExchange.Redis)

```csharp
await db.StringSetAsync("session:abc", "data");
bool ok = await db.KeyExpireAsync("session:abc", TimeSpan.FromSeconds(300));
TimeSpan? ttl = await db.KeyTimeToLiveAsync("session:abc");

// Or set TTL inline:
await db.StringSetAsync("session:abc", "data", TimeSpan.FromSeconds(300));
```

> **Comparison:** Both libraries support separate `EXPIRE` + `TTL` commands. StackExchange.Redis additionally allows setting TTL inline with `StringSetAsync`. hask-redis-mux uses `psetex` for SET with millisecond expiry.

## 3.5 MGET / MSET

### Haskell (hask-redis-mux)

```haskell
runStandaloneClient client $ do
  -- MGET returns a list of values
  (vals :: [Maybe ByteString]) <- mget ["key1", "key2", "key3"]
  return vals
```

> **Note:** hask-redis-mux does not currently expose an `mset` command in the `RedisCommands` typeclass. For bulk SET, use sequential `set` calls which are automatically pipelined by the multiplexer.

### C# (StackExchange.Redis)

```csharp
// MGET
RedisValue[] values = await db.StringGetAsync(
    new RedisKey[] { "key1", "key2", "key3" });

// MSET
await db.StringSetAsync(new[]
{
    new KeyValuePair<RedisKey, RedisValue>("key1", "val1"),
    new KeyValuePair<RedisKey, RedisValue>("key2", "val2"),
});
```

> **Comparison:** Both support `MGET` for bulk reads. StackExchange.Redis has built-in `MSET` support. In hask-redis-mux, multiple `set` calls are effectively pipelined by the multiplexer, achieving similar throughput.

## 3.6 Pub/Sub

### Haskell (hask-redis-mux)

```haskell
-- Pub/Sub is not yet implemented in hask-redis-mux.
-- For publish/subscribe patterns, use raw RESP commands
-- via the low-level executeCommand interface.
```

### C# (StackExchange.Redis)

```csharp
ISubscriber sub = connection.GetSubscriber();

// Subscribe
await sub.SubscribeAsync(RedisChannel.Literal("notifications"), (channel, message) =>
{
    Console.WriteLine($"Received: {message} on {channel}");
});

// Publish
long receivers = await sub.PublishAsync(RedisChannel.Literal("notifications"), "hello!");
```

> **Comparison:** StackExchange.Redis has full pub/sub support with pattern subscriptions and channel management. hask-redis-mux does not yet expose pub/sub in its high-level API.

## 3.7 Transactions (MULTI/EXEC)

### Haskell (hask-redis-mux)

```haskell
-- hask-redis-mux does not expose MULTI/EXEC transactions directly.
-- The multiplexed architecture pipelines commands automatically.
-- For atomic operations, use CLIENT REPLY to control response buffering:
runStandaloneClient client $ do
  clientReply ClientReplyOff   -- suppress replies
  set "counter" "0"
  incr "counter"
  clientReply ClientReplyOn    -- re-enable replies
  (val :: Integer) <- get "counter"
  return val
```

### C# (StackExchange.Redis)

```csharp
ITransaction txn = db.CreateTransaction();

// Add conditions (optimistic locking)
txn.AddCondition(Condition.StringEqual("key", "expected"));

// Queue commands
Task<bool> setTask = txn.StringSetAsync("key", "new-value");
Task<long> incrTask = txn.StringIncrementAsync("counter");

// Execute atomically
bool committed = await txn.ExecuteAsync();
if (committed)
{
    bool setResult = await setTask;
    long incrResult = await incrTask;
}
```

> **Comparison:** StackExchange.Redis provides full MULTI/EXEC transaction support with optimistic locking via conditions. hask-redis-mux takes a different approach — its multiplexed pipelining handles most concurrent scenarios, and `CLIENT REPLY` can be used for response control. For true atomic transactions, raw MULTI/EXEC can be sent via low-level RESP commands.
