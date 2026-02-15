# 5. Feature Matrix

| Feature | hask-redis-mux | StackExchange.Redis |
|---|:---:|:---:|
| **Redis Cluster** | ✅ Auto MOVED/ASK redirection, topology discovery | ✅ Auto MOVED/ASK redirection |
| **TLS / SSL** | ✅ via `crypton` | ✅ via `SslStream` |
| **Connection Pooling** | ✅ Per-node pools (cluster), multiplexer count (standalone) | ⚠️ Single multiplexed connection per endpoint |
| **Multiplexed Pipelining** | ✅ FIFO multiplexer, automatic batching | ✅ Multiplexed, explicit `CreateBatch` |
| **Typed Responses** | ✅ Compile-time via `FromResp` typeclass | ⚠️ Runtime via `RedisValue` casts |
| **Pub/Sub** | ❌ Not yet implemented | ✅ Full support with pattern subscriptions |
| **Transactions (MULTI/EXEC)** | ⚠️ Via CLIENT REPLY / raw commands | ✅ Full support via `CreateTransaction` |
| **Lua Scripting** | ⚠️ Via raw `executeCommand` | ✅ `ScriptEvaluate` with prepared scripts |
| **Redis Sentinel** | ❌ Not supported | ✅ Sentinel-aware connection |
| **Redis Streams** | ❌ Not supported | ✅ Full Streams API |
| **Async Model** | IO monad + green threads | async/await + ThreadPool |
| **Fire-and-Forget** | ⚠️ Via CLIENT REPLY OFF | ✅ `CommandFlags.FireAndForget` |
| **Profiling** | ⚠️ Via GHC RTS flags | ✅ Built-in `ProfilingSession` |
| **Client-Side Caching** | ❌ Not supported | ✅ Server-assisted (Redis 6+) |
| **RESP Protocol** | RESP3 | RESP2 (RESP3 experimental) |
| **Geo Commands** | ✅ Full geo command set | ✅ Full geo command set |
| **Hash Commands** | ✅ hset, hget, hdel, hmget, etc. | ✅ Full hash API |
| **List Commands** | ✅ lpush, rpush, lpop, rpop, lrange | ✅ Full list API |
| **Set Commands** | ✅ sadd, smembers, scard, sismember | ✅ Full set API |
| **Sorted Set Commands** | ✅ zadd, zrange (with scores) | ✅ Full sorted set API |

**Legend:** ✅ Full support | ⚠️ Partial / workaround available | ❌ Not available
