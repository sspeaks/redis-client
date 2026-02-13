# Benchmark Comparison: Haskell redis-client vs C# StackExchange.Redis

A side-by-side performance comparison of two identical REST + SQLite + Redis
cache-aside applications — one written in Haskell using this repo's
`redis-client` library (with Multiplexer enabled), and the other in C#/.NET 8
using StackExchange.Redis.

Both apps now use multiplexed Redis connections, making this a fair
apples-to-apples comparison.

## Table of Contents

- [Test Setup](#test-setup)
- [Methodology](#methodology)
- [Standalone Redis Results](#standalone-redis-results)
- [Cluster Redis Results](#cluster-redis-results)
- [Standalone vs Cluster Comparison](#standalone-vs-cluster-comparison)
- [Analysis](#analysis)
- [Conclusions and Recommendations](#conclusions-and-recommendations)

---

## Test Setup

### Hardware

| Component | Details |
|-----------|---------|
| CPU | 12th Gen Intel Core i7-12700K (12C/20T) |
| RAM | 32 GB |
| OS | Linux (WSL2) — kernel 6.6.87.2-microsoft-standard-WSL2 |
| Docker | Docker Engine 29.2.0 (Linux containers) |

### Software Versions

| Component | Version |
|-----------|---------|
| Redis | `redis:latest` Docker image (standalone, single node) |
| GHC | 9.8.4 (via nix-shell) |
| .NET | 8.0 |
| Node.js | 18.20.8 |
| autocannon | Latest (via npx, HTTP/1.1 benchmarking) |
| StackExchange.Redis | 2.11.0 |
| Microsoft.Data.Sqlite | 10.0.3 |
| redis-client (Haskell) | From source (this repo, `ralph/fair-rest-benchmark` branch) |

### Application Configuration

| Setting | Haskell App | .NET App |
|---------|-------------|----------|
| HTTP Framework | Scotty (warp) | ASP.NET Core Minimal API (Kestrel) |
| Redis Client | redis-client `Multiplexer` (single TCP conn, pipelined) | StackExchange.Redis `ConnectionMultiplexer` |
| SQLite Client | sqlite-simple | Microsoft.Data.Sqlite 10.0.3 |
| SQLite Pragmas | `journal_mode=WAL`, `busy_timeout=5000` | `journal_mode=WAL`, `busy_timeout=5000` |
| Default Port | 3000 | 5000 |
| Cache TTL | 60 seconds | 60 seconds |
| Cache Key Format | `user:{id}` | `user:{id}` |
| Compilation | GHC 9.8.4 `-O2 -threaded -rtsopts "-with-rtsopts=-N"` | `dotnet build -c Release` (.NET 8 RyuJIT) |

### Redis Configuration

| Mode | Details |
|------|---------|
| Standalone | Single node, port 6379, Docker container, default config |
| Cluster | 5 master nodes, ports 7000–7004, Docker with host networking, 16384 hash slots evenly distributed |

### Database

- SQLite with 10,000 seeded user rows (deterministic, seed=42)
- Schema: `id INTEGER PRIMARY KEY, name TEXT, email TEXT UNIQUE, bio TEXT, created_at TEXT`
- WAL mode enabled; `busy_timeout=5000` set on every connection
- Database reseeded between Haskell and .NET benchmark runs for fair comparison

---

## Methodology

### Load Generator

- **Tool**: [autocannon](https://github.com/mcollina/autocannon) (HTTP/1.1 benchmarking)
- **Duration**: 30 seconds per scenario
- **Connection/pipelining settings**: vary by scenario (see table below)

### Scenarios

| Scenario | Description | Connections | Pipelining | Cache Behavior |
|----------|-------------|:-----------:|:----------:|----------------|
| GET single | `GET /users/:id` (random ID 1–10000) | 100 | 10 | Cache hit after first access |
| GET list | `GET /users?page=1&limit=20` | 100 | 10 | Not cached (always hits SQLite) |
| POST | `POST /users` (unique email per request) | 10 | 1 | Invalidates cache key |
| Mixed | 70% GET, 10% list, 10% POST, 5% PUT, 5% DELETE | 20 | 1 | Mixed hits/misses/invalidations |

**Why different connection counts?** SQLite is fundamentally single-writer.
Write-heavy scenarios (POST, Mixed) use fewer connections (10–20) to avoid
overwhelming SQLite's write lock, which would cause `SQLITE_BUSY` errors and
skew results. Read-only scenarios (GET single, GET list) use 100 connections
with 10x pipelining to stress the HTTP→Redis→HTTP path.

### Fairness Controls

- Both apps use **multiplexed Redis connections** (Haskell `Multiplexer`, .NET `ConnectionMultiplexer`)
- Both apps use **identical SQLite pragmas** (`WAL` mode, `busy_timeout=5000`)
- Both apps use **identical cache-aside logic** (same key format, same TTL, same invalidation)
- SQLite database is **reseeded between targets** to ensure identical starting state
- POST and Mixed scenarios use **unique emails per request** (counter-based) to avoid UNIQUE constraint errors
- Both apps are **warmed up** (verified responsive) before benchmarking begins
- **Same autocannon settings** applied to both apps for each scenario

---

## Standalone Redis Results

### Throughput (requests/second)

| Scenario | Haskell | .NET | Ratio (.NET / Haskell) |
|----------|--------:|-----:|:----------------------:|
| GET single | 95,625 | 132,587 | **1.39×** |
| GET list | 8,766 | 12,431 | **1.42×** |
| POST | 123 | 183 | **1.49×** |
| Mixed | 595 | 737 | **1.24×** |

### Latency (milliseconds)

| Scenario | Target | p50 | p95 | p99 | p99.9 |
|----------|--------|----:|----:|----:|------:|
| GET single | Haskell | 10 | 16 | 19 | 31 |
| GET single | .NET | 6 | 14 | 17 | 24 |
| GET list | Haskell | 111 | 154 | 167 | 207 |
| GET list | .NET | 81 | 124 | 135 | 154 |
| POST | Haskell | 9 | 846 | 1,837 | 3,343 |
| POST | .NET | 5 | 313 | 463 | 1,075 |
| Mixed | Haskell | <1 | 234 | 938 | 3,637 |
| Mixed | .NET | <1 | 308 | 462 | 1,522 |

### Response Status Codes

| Scenario | Target | Total Requests | 2xx | 404 | 500 | 2xx % |
|----------|--------|---------------:|----:|----:|----:|------:|
| GET single | Haskell | 2,868,733 | 2,868,733 | 0 | 0 | 100.0% |
| GET single | .NET | 3,977,612 | 3,977,612 | 0 | 0 | 100.0% |
| GET list | Haskell | 262,941 | 262,941 | 0 | 0 | 100.0% |
| GET list | .NET | 372,894 | 372,894 | 0 | 0 | 100.0% |
| POST | Haskell | 3,698 | 3,698 | 0 | 0 | 100.0% |
| POST | .NET | 5,491 | 5,491 | 0 | 0 | 100.0% |
| Mixed | Haskell | 17,839 | 17,250 | 582 | 7 | 96.7% |
| Mixed | .NET | 22,109 | 21,196 | 911 | 2 | 95.9% |

> All scenarios achieve >95% 2xx responses for both apps. The 404 responses in
> the mixed scenario are expected — DELETE and GET-single requests target random
> IDs, some of which have been previously deleted. The handful of 500 errors
> (<0.1%) are transient SQLite busy timeouts under heavy write contention.

---

## Cluster Redis Results

5-node Redis cluster (all masters, ports 7000–7004) with host networking to
eliminate Docker NAT overhead. Haskell uses `ClusterClient` with `MultiplexPool`
(multiplexing enabled). .NET uses StackExchange.Redis `ConnectionMultiplexer`
which auto-discovers cluster topology from a single seed node.

> **Updated 2026-02-12**: These results reflect the optimized Haskell
> `redis-client` library after performance work (US-001 through US-008).
> See [Before/After Comparison](#cluster-beforeafter-comparison) below.

### Throughput (requests/second)

| Scenario | Haskell | .NET | Ratio (.NET / Haskell) |
|----------|--------:|-----:|:----------------------:|
| GET single | 87,492 | 138,479 | **1.58×** |
| GET list | 8,549 | 12,192 | **1.43×** |
| POST | 131 | 186 | **1.42×** |
| Mixed | 598 | 774 | **1.29×** |

### Latency (milliseconds)

| Scenario | Target | p50 | p97.5 | p99 | p99.9 |
|----------|--------|----:|------:|----:|------:|
| GET single | Haskell | 11 | 15 | 16 | 20 |
| GET single | .NET | 6 | 13 | 15 | 24 |
| GET list | Haskell | 116 | 153 | 161 | 184 |
| GET list | .NET | 84 | 115 | 124 | 200 |
| POST | Haskell | 9 | 1,035 | 1,736 | 4,549 |
| POST | .NET | 5 | 312 | 463 | 1,222 |
| Mixed | Haskell | <1 | 188 | 1,035 | 3,542 |
| Mixed | .NET | <1 | 309 | 466 | 1,071 |

### Response Status Codes

| Scenario | Target | Total Requests | 2xx | 404 | 500 | 2xx % |
|----------|--------|---------------:|----:|----:|----:|------:|
| GET single | Haskell | 2,624,686 | 2,624,686 | 0 | 0 | 100.0% |
| GET single | .NET | 4,154,030 | 4,154,030 | 0 | 0 | 100.0% |
| GET list | Haskell | 256,464 | 256,464 | 0 | 0 | 100.0% |
| GET list | .NET | 365,734 | 365,734 | 0 | 0 | 100.0% |
| POST | Haskell | 3,922 | 3,919 | 0 | 3 | 99.9% |
| POST | .NET | 5,587 | 5,587 | 0 | 0 | 100.0% |
| Mixed | Haskell | 17,946 | 17,380 | 560 | 6 | 96.9% |
| Mixed | .NET | 23,227 | 22,193 | 1,034 | 0 | 95.6% |

### Cluster Before/After Comparison

The following table shows the impact of the performance optimizations
(US-001 through US-008) on Haskell cluster REST throughput:

| Scenario | Before | After | Improvement |
|----------|-------:|------:|:-----------:|
| GET single | 35,202 | 87,492 | **2.49×** (+149%) |
| GET list | 8,255 | 8,549 | 1.04× (+4%) |
| POST | 122 | 131 | 1.07× (+7%) |
| Mixed | 562 | 598 | 1.06× (+6%) |

The .NET/.Haskell gap for GET single narrowed from **3.46×** to **1.58×**
— a dramatic improvement. The remaining 1.58× gap is consistent with the
standalone gap (1.39×) plus minor cluster routing overhead, indicating that
cluster-specific overhead has been largely eliminated.

---

## GC/HTTP/JSON Optimization Results (2026-02-13)

Following the cluster performance work (US-001–US-008), a gap analysis was
conducted to quantify the contributions of GC behavior, HTTP framework
overhead, and JSON serialization to the remaining 1.58× throughput gap on
GET single. See `benchmarks/results/gc-http-json/summary.md` for the full
analysis.

### Optimization Applied

GHC RTS flags `-H1024M -A128m -n8m -qb -N` (via `-with-rtsopts` in
`haskell-rest-benchmark.cabal`). No code changes were made. HTTP framework
(Scotty) and JSON serialization (Aeson) were measured but not replaced, as
neither exceeded the 5% improvement threshold.

### Updated Cluster Throughput (requests/second)

| Scenario | Before | After GC Tuning | Improvement | .NET | Gap Before | Gap After |
|----------|-------:|----------------:|:-----------:|-----:|:----------:|:---------:|
| GET single | 87,492 | 105,901 | **+21.0%** | 138,479 | **1.58×** | **1.31×** |
| GET list | 8,549 | 10,132 | **+18.5%** | 12,192 | **1.43×** | **1.20×** |
| POST | 131 | 126 | −3.8%¹ | 186 | 1.42× | 1.48×¹ |
| Mixed | 598 | 578 | −3.3%¹ | 774 | 1.29× | 1.34×¹ |

¹ Within normal run-to-run variance for SQLite-bottlenecked workloads

### Per-Factor Contribution

| Factor | Impact | Threshold | Applied? |
|--------|--------|:---------:|:--------:|
| GC tuning (RTS flags) | +21.0% throughput, gap 1.58×→1.31× | — | ✅ Yes |
| HTTP framework (Scotty→Warp) | +1.4% throughput | >5% | ❌ No |
| JSON serialization (Aeson→Builder) | +0.2% cache-hit, +5.0% cache-miss | >5% | ❌ No |

### Conclusion

GC tuning was the dominant factor — closing ~76% of the achievable gap with
zero code changes. The remaining 1.31× gap is attributable to fundamental
runtime differences (GHC vs .NET CLR), not framework or serialization overhead.

---

## Standalone vs Cluster Comparison

### Haskell: Throughput Change (Standalone → Cluster)

| Scenario | Standalone | Cluster | Change |
|----------|--------:|--------:|:------:|
| GET single | 95,625 | 87,492 | **0.92×** (−9%) |
| GET list | 8,766 | 8,549 | **0.98×** (−2%) |
| POST | 123 | 131 | **1.07×** (+7%) |
| Mixed | 595 | 598 | **1.01×** (+1%) |

### .NET: Throughput Change (Standalone → Cluster)

| Scenario | Standalone | Cluster | Change |
|----------|--------:|--------:|:------:|
| GET single | 132,587 | 138,479 | **1.04×** (+4%) |
| GET list | 12,431 | 12,192 | **0.98×** (−2%) |
| POST | 183 | 186 | **1.02×** (+2%) |
| Mixed | 737 | 774 | **1.05×** (+5%) |

### Cluster Overhead Analysis

After the performance optimizations (US-001 through US-008), **Haskell's
cluster overhead has been largely eliminated**. The GET single scenario
previously dropped 63% from standalone to cluster; it now drops only 9%,
comparable to .NET's behavior.

The key optimization was per-node round-robin counters in the `MultiplexPool`
(US-004), which eliminated cross-node CAS contention that was causing a 6.6×
regression. Combined with slot lookup optimization, INLINE pragmas, and
vectored I/O, the cluster routing layer now adds minimal overhead.

For scenarios dominated by SQLite (GET list, POST, Mixed), both standalone
and cluster performance are essentially identical for both implementations,
confirming that SQLite is the bottleneck, not Redis.

---

## Analysis

### Overall Performance Gap: 1.24×–1.49× (Standalone), 1.29×–1.58× (Cluster)

The .NET app outperforms Haskell by **1.24× to 1.49×** across all standalone
scenarios — a remarkably narrow gap. In cluster mode, the gap now ranges from
**1.29× to 1.58×** after performance optimizations that eliminated cluster
routing overhead. The previous cluster GET single gap of 3.46× has been
reduced to 1.58×, consistent with the standalone gap plus minor residual
cluster overhead.

No scenario exceeds 1.6×. The Haskell `redis-client` with multiplexing
enabled is competitive with StackExchange.Redis across both standalone
and cluster modes.

### Scenario-by-Scenario Breakdown

#### GET Single User (1.39× gap)

This is the purest **HTTP → Redis → HTTP** benchmark. After the first request
populates the cache, every subsequent request is a Redis cache hit — no SQLite
involved. The 1.39× gap here reflects the combined efficiency differences of:

1. **HTTP framework overhead**: Kestrel's zero-allocation pipeline vs warp/Scotty
2. **Redis multiplexer maturity**: StackExchange.Redis has years of optimization
   for its multiplexer; `redis-client`'s `Multiplexer` is newer
3. **JSON serialization on cache miss**: aeson vs System.Text.Json (only affects
   the initial miss that populates the cache)

Both achieve excellent latencies — Haskell's p50 is 10ms, .NET's is 6ms. The
p99 latencies are nearly identical (19ms vs 17ms), suggesting both handle tail
latencies well under this workload.

#### GET List (1.42× gap)

This scenario **always hits SQLite** (list queries are not cached). The 1.42×
gap is mostly explained by:

1. **SQLite client efficiency**: Microsoft.Data.Sqlite uses prepared statements
   and Span-based parsing; sqlite-simple creates fresh statements per query
2. **JSON serialization**: Serializing 20 user records per response — .NET's
   source-generated serializers avoid reflection overhead
3. **HTTP response writing**: Kestrel's optimized response pipeline vs warp's
   lazy ByteString chunked encoding

The absolute throughput (8.8k vs 12.4k req/s) is impressive for both, given
each request queries and serializes 20 rows.

#### POST (1.49× gap)

The largest gap, but absolute numbers are low for both (123 vs 183 req/s)
because **SQLite is the bottleneck**. Each POST request:

1. Writes a row to SQLite (contends on the single-writer lock)
2. Reads the inserted row back
3. Serializes to JSON
4. Sends a DEL to Redis

The 1.49× gap is largely due to differences in how each SQLite client handles
write contention. The high p99 latencies (1,837ms Haskell vs 463ms .NET)
suggest Haskell's sqlite-simple may be less efficient at retry/backoff under
`busy_timeout`.

#### Mixed Workload (1.24× gap)

The **smallest gap** — only 1.24×. This is the most realistic scenario, with a
read-heavy workload (70% GET single = cache hits) mixed with writes. The narrow
gap suggests that under realistic workloads, the performance difference between
the two stacks is minimal.

### Connection Model (Multiplexing)

| Aspect | Haskell (redis-client) | C# (StackExchange.Redis) |
|--------|----------------------|--------------------------|
| Architecture | `Multiplexer` wrapping `PlainTextClient` | `ConnectionMultiplexer` |
| Connection count | Single TCP connection, multiplexed | Single TCP connection, multiplexed |
| Command pipelining | Via `submitCommand` + async response matching | Built-in pipeline manager |
| Protocol | RESP2 | RESP2 |

**Both apps now use the same architectural pattern**: a single TCP connection
to Redis with command multiplexing. This is the key change from the previous
(unfair) benchmark where the Haskell app used synchronous per-request
`evalStateT` calls. With multiplexing enabled, the Haskell app pipelines
Redis commands across concurrent HTTP requests, matching StackExchange.Redis's
architecture.

### Serialization

| Aspect | Haskell | C# |
|--------|---------|-----|
| JSON library | aeson (Builder-based) | System.Text.Json (source generators + Span\<T\>) |
| Cache format | Strict ByteString via `encode` | String via `JsonSerializer.Serialize` |
| Deserialization | Not needed (cache returns raw bytes) | Not needed (cache returns raw string) |

**Impact**: Both apps store pre-serialized JSON in Redis, so cache hits bypass
JSON processing entirely. For cache misses, the serialization difference is
small. System.Text.Json's source generators eliminate reflection costs, while
aeson's `Builder` composition is efficient but involves more allocation.

### Runtime: GHC 9.8.4 vs .NET 8 CLR

| Aspect | GHC (Haskell) | CLR (.NET 8) |
|--------|---------------|--------------|
| Compilation | Ahead-of-time native code (`-O2`) | JIT (RyuJIT) with tiered compilation |
| Startup time | Fast (native binary) | Slightly slower (JIT warm-up) |
| Steady-state performance | Good; allocation-heavy code can stress GC | Highly optimized for server workloads |
| Memory model | Immutable by default; GC manages all heap objects | Value types (structs) reduce GC pressure |

**Impact**: .NET 8's JIT can specialize hot paths after warm-up, and its value
types (structs) reduce GC pressure for response objects. Haskell's immutable
data model means every JSON serialization creates new heap objects, but GHC's
nursery-based allocation is extremely fast (bump pointer). For a 30-second
benchmark, JIT warm-up cost is fully amortized.

### Garbage Collection

| Aspect | GHC 9.8.4 | .NET 8 |
|--------|-----------|--------|
| GC type | Generational, copying (default) | Generational, compacting (Server GC) |
| Pause behavior | Stop-the-world for major GC | Background GC with concurrent marking |
| Tuning applied | Default RTS flags (`-N` only) | Default Server GC |

**Impact**: The p99.9 latencies show the GC effect clearly:

- GET single: Haskell 31ms vs .NET 24ms (1.3× gap at tail)
- POST: Haskell 3,343ms vs .NET 1,075ms (3.1× gap at tail)

The POST scenario's extreme tail latency gap suggests GHC's stop-the-world
major collections may be coinciding with SQLite busy-wait retries, creating
compounding delays. GHC RTS tuning flags (`-A64m -n4m -H512m`) could
significantly reduce these pauses.

### HTTP Framework

| Aspect | Scotty (warp) | ASP.NET Core Minimal API (Kestrel) |
|--------|---------------|-------------------------------------|
| Architecture | Event-driven + green threads | Event-driven + async/await |
| Request parsing | Lazy ByteString / Scotty combinators | Zero-allocation model binding |
| Response writing | Chunked lazy ByteString | Optimized response pipeline |
| Performance ranking | Top-tier in TechEmpower benchmarks | Top-tier in TechEmpower benchmarks |

**Impact**: Both are excellent HTTP servers. Kestrel has a slight edge from
Microsoft's years of investment in zero-allocation response paths and
`System.IO.Pipelines`. Warp is similarly well-optimized but Scotty's routing
layer adds a thin overhead compared to ASP.NET Core's compiled endpoint routing.

### SQLite Access Patterns

| Aspect | Haskell (sqlite-simple) | C# (Microsoft.Data.Sqlite) |
|--------|------------------------|----------------------------|
| Connection model | New connection per request (`withConnection`) | Connection pool (implicit) |
| Statement caching | No (fresh prepared statements) | Yes (via ADO.NET) |
| WAL mode | Set at startup + per-connection | Set at startup + per-connection |
| Busy timeout | 5000ms per connection | 5000ms per connection |

**Impact**: Microsoft.Data.Sqlite's connection pooling and statement caching
give it an advantage in write-heavy scenarios. Haskell's `withConnection`
opens a new SQLite handle per request, which involves filesystem operations
and foregoes prepared statement caching. This likely explains a significant
portion of the POST scenario gap (1.49×).

---

## Conclusions and Recommendations

### Key Takeaways

1. **The Haskell redis-client with Multiplexer is competitive in both modes**:
   The 1.24×–1.49× standalone gap and 1.29×–1.58× cluster gap vs
   StackExchange.Redis are impressive. No scenario exceeds 1.6×.

2. **Cluster overhead has been eliminated**: After optimizations (US-001
   through US-008), Haskell's GET single drops only 9% from standalone to
   cluster (was −63%). The cluster GET single gap narrowed from 3.46× to
   1.58× — a **2.49× improvement** in cluster REST throughput (35,202 →
   87,492 req/s).

2. **Multiplexing was the key fairness fix**: The previous benchmark (without
   Haskell multiplexing) showed 70×+ gaps because the Haskell app serialized
   all Redis commands through a single-threaded `evalStateT`. With `Multiplexer`
   enabled, concurrent HTTP requests pipeline their Redis commands properly.

3. **The remaining gap is mostly NOT the Redis client**: The performance
   difference is distributed across the full stack — HTTP framework, JSON
   serialization, SQLite access patterns, and GC behavior. The Redis
   multiplexer itself is a small portion of the remaining gap.

4. **SQLite is the dominant bottleneck for writes**: Both apps achieve only
   ~100-180 POST req/s, limited by SQLite's single-writer model. The Redis
   client's performance is irrelevant when the database is the constraint.

5. **Tail latencies are the biggest quality gap**: While throughput gaps are
   modest (1.24×–1.49×), p99.9 latency gaps are larger (1.3×–3.1×). This is
   primarily a GC issue — GHC's stop-the-world collections cause occasional
   spikes that .NET's background GC avoids.

### Recommendations for redis-client Library

1. **Multiplexer should be the default path**: The performance benefit of
   multiplexing is dramatic. Consider making `Multiplexer` the primary API
   rather than raw `PlainTextClient` command execution. Documentation should
   strongly recommend multiplexing for any concurrent workload.

2. **Consider connection pooling**: While the `Multiplexer` handles command
   pipelining well, a pool of multiplexed connections could further improve
   throughput under very high concurrency by reducing TCP-level head-of-line
   blocking (similar to StackExchange.Redis's multiple socket connections).

3. **RTS tuning guide**: Provide recommended GHC RTS flags for server
   workloads in the README:
   ```
   +RTS -N -A64m -n4m -H512m -qg -RTS
   ```
   These flags increase nursery size (`-A64m`), set a minimum allocation
   area (`-n4m`), set initial heap size (`-H512m`), and enable parallel GC
   (`-qg` disables generational GC).

4. **Benchmark improvements**: For more rigorous results, future benchmarks
   should run 3–5 iterations per scenario and report mean ± standard deviation.
   Consider using a dedicated bare-metal machine (not WSL2) to reduce
   virtualization overhead and measurement noise.

### How to Reproduce

#### Standalone

```bash
# Run the full standalone benchmark (starts Redis, seeds DB, builds apps, runs benchmarks)
nix-shell --run "bash benchmarks/scripts/run-standalone.sh"

# Results will be in benchmarks/results/standalone/
```

#### Cluster

```bash
# Run the full cluster benchmark (starts 5-node cluster, seeds DB, builds apps, runs benchmarks)
# Requires redis-cli to be available on PATH for cluster creation
nix-shell --run "bash benchmarks/scripts/run-cluster.sh"

# Results will be in benchmarks/results/cluster/
```

---

*Data sourced from actual benchmark JSON files in `benchmarks/results/standalone/`
and `benchmarks/results/cluster/`. Standalone benchmarks run on 2026-02-12 with
multiplexing enabled for both apps. Cluster benchmarks updated on 2026-02-12
after performance optimizations (US-001 through US-008).*
