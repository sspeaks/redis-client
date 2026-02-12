#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# generate-comparison.sh — Generate COMPARISON.md from benchmark JSON results
#
# Reads autocannon JSON output files from benchmarks/results/standalone/ and
# benchmarks/results/cluster/, extracts key metrics, and produces a markdown
# comparison document at benchmarks/results/COMPARISON.md.
#
# Usage: bash benchmarks/results/generate-comparison.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STANDALONE_DIR="$SCRIPT_DIR/standalone"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
OUTPUT="$SCRIPT_DIR/COMPARISON.md"

# Extract a metric from an autocannon JSON file via node
metric() {
  local file="$1" path="$2"
  if [ -f "$file" ]; then
    node -e "const d=require('$file'); console.log($path ?? 'N/A')" 2>/dev/null || echo "N/A"
  else
    echo "—"
  fi
}

# Format a results table for a given mode directory
format_table() {
  local dir="$1"

  printf "| %-12s | %-15s | %10s | %10s | %10s | %10s |\n" \
    "Target" "Scenario" "Req/s" "p50 (ms)" "p95 (ms)" "p99 (ms)"
  printf "|%s|%s|%s|%s|%s|%s|\n" \
    "--------------" "-----------------" "------------" "------------" "------------" "------------"

  for label in haskell dotnet; do
    for scenario in get_single get_list post mixed; do
      local f="$dir/${label}_${scenario}.json"
      local rps p50 p95 p99
      rps=$(metric "$f" "d.requests?.average")
      p50=$(metric "$f" "d.latency?.p50")
      p95=$(metric "$f" "d.latency?.p95")
      p99=$(metric "$f" "d.latency?.p99")
      printf "| %-12s | %-15s | %10s | %10s | %10s | %10s |\n" \
        "$label" "$scenario" "$rps" "$p50" "$p95" "$p99"
    done
  done
}

# Check for result files
has_standalone=false
has_cluster=false
[ -f "$STANDALONE_DIR/haskell_get_single.json" ] && has_standalone=true
[ -f "$CLUSTER_DIR/haskell_get_single.json" ] && has_cluster=true

cat > "$OUTPUT" << 'HEADER'
# Benchmark Comparison: Haskell redis-client vs C# StackExchange.Redis

A side-by-side performance comparison of two identical REST + SQLite + Redis
cache-aside applications — one written in Haskell using this repo's
`redis-client` library, and the other in C#/.NET 8 using StackExchange.Redis.

## Table of Contents

- [Test Setup](#test-setup)
- [Methodology](#methodology)
- [Standalone Redis Results](#standalone-redis-results)
- [Redis Cluster Results](#redis-cluster-results)
- [Analysis](#analysis)
- [Conclusions and Recommendations](#conclusions-and-recommendations)

---

## Test Setup

### Hardware

| Component | Details |
|-----------|---------|
| CPU | _Fill in after benchmark run_ |
| RAM | _Fill in after benchmark run_ |
| OS | Linux (WSL2 / native) |
| Docker | Docker Engine (Linux containers) |

### Software Versions

| Component | Version |
|-----------|---------|
| Redis | Latest (docker `redis` image) |
| GHC | 9.6.x (via nix) |
| .NET | 8.0 |
| Node.js / autocannon | Latest (for load generation) |
| StackExchange.Redis | 2.11.0 |
| redis-client (Haskell) | From source (this repo) |

### Application Configuration

| Setting | Haskell App | .NET App |
|---------|-------------|----------|
| HTTP Framework | Scotty 0.22 (warp) | ASP.NET Core Minimal API |
| Redis Client | redis-client (PlainTextClient / ClusterClient) | StackExchange.Redis (ConnectionMultiplexer) |
| SQLite Client | sqlite-simple | Microsoft.Data.Sqlite |
| Default Port | 3000 | 5000 |
| Cache TTL | 60 seconds | 60 seconds |
| Cache Key Format | `user:{id}` | `user:{id}` |
| Compilation | GHC -O2 -threaded -rtsopts "-with-rtsopts=-N" | dotnet build -c Release |

### Redis Configuration

| Mode | Details |
|------|---------|
| Standalone | Single node, port 6379, docker compose |
| Cluster | 5 nodes, ports 6379-6383, host networking, 3 masters + 2 replicas |

### Database

- SQLite with 10,000 seeded user rows (deterministic, seed=42)
- Schema: `id INTEGER PRIMARY KEY, name TEXT, email TEXT UNIQUE, bio TEXT, created_at TEXT`

---

## Methodology

### Load Generator

- **Tool**: [autocannon](https://github.com/mcollina/autocannon) (HTTP/1.1 benchmarking)
- **Connections**: 100 concurrent
- **Pipelining**: 10 requests per connection
- **Duration**: 30 seconds per scenario

### Scenarios

| Scenario | Description | Cache Behavior |
|----------|-------------|----------------|
| GET single | `GET /users/:id` (random ID 1–10000) | Cache hit after first access |
| GET list | `GET /users?page=1&limit=20` | Not cached |
| POST | `POST /users` (create new user) | Invalidates cache key |
| Mixed | 70% GET single, 10% GET list, 10% POST, 5% PUT, 5% DELETE | Mixed cache hits/misses/invalidations |

### Warm-up

- No explicit warm-up phase; first requests in each scenario serve as implicit warm-up
- Each scenario runs for the full duration independently
- Both apps are verified responsive (`GET /users/1` returns 200) before benchmarking begins

### Number of Runs

- Single run per configuration (standalone / cluster)
- For statistically rigorous results, run `run-standalone.sh` and `run-cluster.sh` multiple times and average

---

HEADER

# Standalone results
if $has_standalone; then
  echo "## Standalone Redis Results" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
  format_table "$STANDALONE_DIR" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
else
  cat >> "$OUTPUT" << 'STANDALONE_PLACEHOLDER'
## Standalone Redis Results

> **Results pending.** Run `benchmarks/scripts/run-standalone.sh` to generate data,
> then re-run this script to populate the table.

| Target | Scenario | Req/s | p50 (ms) | p95 (ms) | p99 (ms) |
|--------|----------|-------|----------|----------|----------|
| haskell | get_single | — | — | — | — |
| haskell | get_list | — | — | — | — |
| haskell | post | — | — | — | — |
| haskell | mixed | — | — | — | — |
| dotnet | get_single | — | — | — | — |
| dotnet | get_list | — | — | — | — |
| dotnet | post | — | — | — | — |
| dotnet | mixed | — | — | — | — |

STANDALONE_PLACEHOLDER
fi

# Cluster results
if $has_cluster; then
  echo "## Redis Cluster Results" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
  format_table "$CLUSTER_DIR" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
else
  cat >> "$OUTPUT" << 'CLUSTER_PLACEHOLDER'
## Redis Cluster Results

> **Results pending.** Run `benchmarks/scripts/run-cluster.sh` to generate data,
> then re-run this script to populate the table.

| Target | Scenario | Req/s | p50 (ms) | p95 (ms) | p99 (ms) |
|--------|----------|-------|----------|----------|----------|
| haskell | get_single | — | — | — | — |
| haskell | get_list | — | — | — | — |
| haskell | post | — | — | — | — |
| haskell | mixed | — | — | — | — |
| dotnet | get_single | — | — | — | — |
| dotnet | get_list | — | — | — | — |
| dotnet | post | — | — | — | — |
| dotnet | mixed | — | — | — | — |

CLUSTER_PLACEHOLDER
fi

cat >> "$OUTPUT" << 'ANALYSIS'
---

## Analysis

### Connection Model

| Aspect | Haskell (redis-client) | C# (StackExchange.Redis) |
|--------|----------------------|--------------------------|
| Connection type | Plain TCP socket per command client | Multiplexed pipeline over single TCP connection |
| Connection pooling | Manual via `PlainTextClient` / `ClusterClient` pool | Built-in `ConnectionMultiplexer` with automatic pooling |
| Protocol | RESP2/RESP3 | RESP2 with automatic multiplexing |

**Impact**: StackExchange.Redis's multiplexed design allows many concurrent operations
over a single TCP connection, reducing overhead for high-concurrency workloads. The
Haskell `redis-client` uses a simpler model with direct command execution, which may
have lower overhead per individual command but less connection sharing.

### Serialization

| Aspect | Haskell | C# |
|--------|---------|-----|
| JSON library | aeson | System.Text.Json |
| Cache format | JSON byte string via `encode` | JSON string via `JsonSerializer.Serialize` |
| Deserialization | Not needed (cache returns raw bytes) | Not needed (cache returns raw string) |

**Impact**: Both apps store pre-serialized JSON in Redis, so cache hits bypass
deserialization entirely. For cache misses, Haskell's `aeson` and .NET's
`System.Text.Json` are both mature, high-performance JSON libraries. The difference
is typically small — `System.Text.Json` uses source generators and Span<T> for
zero-allocation paths, while `aeson` uses efficient `Builder` composition.

### Runtime: GHC vs CLR

| Aspect | GHC (Haskell) | CLR (.NET 8) |
|--------|---------------|--------------|
| Compilation | Ahead-of-time native code (-O2) | JIT (RyuJIT) with tiered compilation |
| Startup time | Fast (native binary) | Slightly slower (JIT warm-up) |
| Steady-state perf | Comparable; depends on allocation patterns | Highly optimized for server workloads |
| Binary size | Larger (statically linked by default) | Smaller (shared framework) |

**Impact**: .NET 8's tiered JIT compilation can produce highly optimized machine code
for hot paths after warm-up. GHC's ahead-of-time compilation with `-O2` produces
good native code but may not match JIT-specialized optimizations for specific workloads.
For a 30-second benchmark, JIT warm-up cost is amortized.

### Thread Model

| Aspect | Haskell | C# |
|--------|---------|-----|
| Concurrency model | Green threads (GHC RTS `-N` = all cores) | async/await on ThreadPool |
| HTTP server | warp (event-driven, green threads) | Kestrel (event-driven, async/await) |
| SQLite access | Synchronous per green thread | Async ADO.NET |
| Redis access | Synchronous per green thread | Async StackExchange.Redis |

**Impact**: Both apps handle concurrency well but differently. Warp uses GHC's
lightweight green threads — each request runs in its own green thread with preemptive
scheduling managed by the RTS. Kestrel uses .NET's async/await pattern with the
thread pool. Both can handle thousands of concurrent connections efficiently.

SQLite is a key bottleneck for both: it's fundamentally single-writer, so under
heavy POST/PUT/DELETE load, both apps contend on the SQLite write lock regardless
of their concurrency model.

### Garbage Collection

| Aspect | GHC | .NET 8 |
|--------|-----|--------|
| GC type | Generational, copying (default) | Generational, compacting (Server GC) |
| Pause behavior | Stop-the-world for major GC | Background GC with concurrent marking |
| Tuning | RTS flags (-H, -A, -n) | Server/Workstation GC, regions |

**Impact**: Under high-throughput HTTP workloads, GC pause times affect tail latencies
(p95, p99). .NET's Server GC is specifically tuned for server workloads with background
collection. GHC's default GC may show higher p99 latencies due to stop-the-world major
collections, though this can be mitigated with RTS tuning flags (e.g., `-A64m` to
increase nursery size).

### HTTP Framework

| Aspect | Scotty (Haskell) | ASP.NET Core Minimal API |
|--------|------------------|--------------------------|
| Underlying server | warp | Kestrel |
| Routing | Pattern matching | Endpoint routing |
| Request parsing | Lazy bytestring / scotty combinators | Model binding / System.Text.Json |
| Known performance | warp is consistently top-tier in benchmarks | Kestrel is top-tier, heavily optimized |

**Impact**: Both warp and Kestrel are high-performance HTTP servers that regularly
appear at the top of framework benchmarks. Scotty adds a thin routing layer over
warp with minimal overhead. ASP.NET Core Minimal APIs have very little ceremony
and near-raw Kestrel performance.

### Cluster Mode Considerations

| Aspect | Haskell (redis-client) | C# (StackExchange.Redis) |
|--------|----------------------|--------------------------|
| Cluster discovery | Manual seed node + topology refresh | Automatic cluster discovery |
| Slot routing | Client-side CRC16 hash slot routing | Transparent slot routing |
| Redirect handling | Client handles ASK/MOVED | Automatic ASK/MOVED handling |
| Connection pool | Per-node pool via ClusterClient | Per-node multiplexed connections |

**Impact**: In cluster mode, both clients must route commands to the correct node
based on key hash slots. StackExchange.Redis handles this transparently, while
`redis-client`'s `ClusterClient` also manages topology and routing. The overhead
of cluster-aware routing typically adds 1-5% latency compared to standalone mode
due to hash slot computation and potentially following redirects.

---

## Conclusions and Recommendations

### Key Takeaways

1. **Both stacks are production-viable** for REST + Redis cache workloads. The
   performance difference is likely within 2-3x for most scenarios, with the
   exact numbers depending on the specific workload mix.

2. **Cache-hit performance** (GET single user) is where Redis client efficiency
   matters most — this path bypasses SQLite entirely and measures pure
   HTTP → Redis → HTTP round-trip performance.

3. **SQLite-bound operations** (GET list, POST, PUT, DELETE) are bottlenecked
   by SQLite's single-writer model, so Redis client performance is less of a
   differentiator here.

4. **Tail latencies** (p95, p99) are influenced more by GC behavior and
   connection management than raw throughput. Watch for GHC major GC pauses
   affecting p99 numbers.

5. **Cluster mode** adds routing overhead for both clients but should show
   similar relative performance to standalone mode.

### Recommendations

- **For Haskell users**: The `redis-client` library provides a clean, type-safe
  Redis interface that integrates well with the Haskell ecosystem. Use
  `-threaded -rtsopts "-with-rtsopts=-N"` for multi-core utilization. Consider
  RTS GC tuning (`-A64m -n4m`) for lower tail latencies under load.

- **For production workloads**: Connection pooling and multiplexing (as in
  StackExchange.Redis) generally win under very high concurrency. If the Haskell
  app needs to match .NET's concurrency characteristics, consider adding
  connection pooling to the redis-client usage.

- **For benchmarking**: Run multiple iterations and report averages with standard
  deviation. A single 30-second run provides directional data but may be affected
  by system noise, Docker overhead, or GC timing.

### How to Reproduce

```bash
# Standalone benchmark
bash benchmarks/scripts/run-standalone.sh

# Cluster benchmark
bash benchmarks/scripts/run-cluster.sh

# Regenerate this document with actual results
bash benchmarks/results/generate-comparison.sh
```

---

*Generated from autocannon JSON results in `benchmarks/results/`.
Re-run `benchmarks/results/generate-comparison.sh` to update tables with fresh data.*
ANALYSIS

echo "Comparison document written to: $OUTPUT"
