# REST + Redis Cache Benchmark: Haskell redis-client vs C# StackExchange.Redis

## Overview

A head-to-head performance comparison between this repo's Haskell `redis-client` library and C#'s `StackExchange.Redis`, built around two identical REST+SQLite+Redis cache-aside apps. Both apps expose the same CRUD endpoints for a `users` table, use Redis as a cache-aside layer over SQLite, and are stress-tested under identical conditions using autocannon. The project produces raw benchmark data and a comparison document analyzing throughput, latency, and the architectural reasons behind any performance differences.

## What's New

### Shared Test Data

A SQLite schema and deterministic seed script generate 10,000 user rows so both apps start from identical database state. The seed is reproducible (always seed 42) and idempotent — running it again drops and recreates the data.

### C# / .NET REST API

A .NET 8 minimal API at `benchmarks/dotnet-rest/` implements a full users CRUD with Redis cache-aside. Single-user GETs check Redis first (`user:{id}` key, 60s TTL), fall back to SQLite on cache miss, and populate the cache. Writes invalidate or remove cache entries. Supports standalone and cluster Redis.

### Haskell REST API

A Haskell REST API at `benchmarks/haskell-rest/` mirrors the .NET app's behavior using this repo's `redis-client` library and Scotty for HTTP. Same cache-aside pattern, same endpoints, same Redis key scheme. Supports both standalone (`PlainTextClient`) and cluster mode (`ClusterClient`).

### Benchmark Scripts

An autocannon-based benchmark suite runs four scenarios against both apps: GET single user (random IDs), GET paginated list, POST new user, and a mixed workload (70% GET single / 10% GET list / 10% POST / 5% PUT / 5% DELETE). Results are saved as JSON and a summary table is printed to stdout.

### One-Command Benchmark Runs

Wrapper scripts automate the full benchmark lifecycle — start Redis (standalone or cluster), seed the database, build and launch both apps, run all benchmarks, save results, and clean up. One command for standalone, one for cluster.

### Comparison Document

A detailed comparison document at `benchmarks/results/COMPARISON.md` presents results tables and analyzes *why* the numbers differ — covering connection models, serialization, GHC vs CLR runtimes, thread models, GC behavior, and cluster-mode considerations. A companion script regenerates the tables from JSON results.

## How to Use

### Prerequisites

- Nix shell (for Haskell toolchain) or GHC + Cabal installed
- .NET 8 SDK
- Docker and Docker Compose
- Node.js (for autocannon)
- Python 3 (for seed script)

### 1. Seed the Database

```bash
cd benchmarks/shared
python3 seed.py
# Creates bench.db with 10,000 users
# Override path: SQLITE_DB=/path/to/db.sqlite python3 seed.py
```

### 2. Run Standalone Benchmarks (Recommended Start)

```bash
# Single command — starts Redis, seeds DB, builds apps, runs benchmarks, cleans up
./benchmarks/scripts/run-standalone.sh
```

Results are saved to `benchmarks/results/standalone/`.

### 3. Run Cluster Benchmarks

```bash
# Starts a 5-node Redis Cluster with host networking, then benchmarks
./benchmarks/scripts/run-cluster.sh
```

Results are saved to `benchmarks/results/cluster/`.

### 4. Run Benchmarks Manually

If you want more control:

```bash
# Start Redis yourself (standalone)
docker compose -f docker/docker-compose.yml up -d redis

# Seed DB
SQLITE_DB=benchmarks/shared/bench.db python3 benchmarks/shared/seed.py

# Start Haskell app (port 3000)
cabal build haskell-rest-benchmark
$(cabal list-bin haskell-rest-benchmark) &

# Start .NET app (port 5000)
cd benchmarks/dotnet-rest/RedisBenchmark
dotnet build -c Release
PORT=5000 dotnet run --no-build -c Release &

# Run benchmarks
./benchmarks/scripts/run-benchmarks.sh
```

### 5. Generate/Regenerate Comparison Document

```bash
./benchmarks/results/generate-comparison.sh
# Updates benchmarks/results/COMPARISON.md with data from JSON result files
```

### Configuration (Environment Variables)

| Variable | Default | Description |
|---|---|---|
| `REDIS_HOST` | `127.0.0.1` | Redis host |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_CLUSTER` | (unset) | Set to `true` for cluster mode |
| `SQLITE_DB` | `benchmarks/shared/bench.db` | SQLite database path |
| `PORT` | `3000` (Haskell) / `5000` (.NET) | HTTP listen port |
| `DURATION` | `30` | Benchmark duration in seconds |
| `CONNECTIONS` | `100` | Concurrent connections |
| `PIPELINING` | `10` | HTTP pipelining factor |
| `HASKELL_URL` | `http://localhost:3000` | Haskell app base URL |
| `DOTNET_URL` | `http://localhost:5000` | .NET app base URL |
| `BENCHMARK_MODE` | `standalone` | `standalone` or `cluster` (controls results directory) |

## Technical Notes

- **Haskell HTTP framework:** Scotty 0.22 on Warp. Uses `queryParamMaybe` for optional query params.
- **Redis abstraction:** The Haskell app wraps both `PlainTextClient` (standalone) and `ClusterClient` behind a `RedisConn` type using `RankNTypes`, letting the same business logic work in both modes.
- **Cache pattern:** Both apps use identical cache-aside logic — `user:{id}` keys, 60-second TTL, invalidation on write, removal on delete.
- **Mixed workload:** The mixed benchmark scenario uses autocannon's Node.js programmatic API (not CLI) because autocannon's CLI doesn't support request arrays or config files.
- **Cluster networking:** The cluster benchmarks use `docker-cluster-host/` with `network_mode: host` so cluster nodes announce `127.0.0.1` and are directly reachable from the host. The bridge-networking cluster in `docker-cluster/` announces internal hostnames and won't work for host-side apps.
- **Dependencies added:** `autocannon` (npm, local to `benchmarks/scripts/`), `Microsoft.Data.Sqlite` and `StackExchange.Redis` (NuGet), `haskell-rest-benchmark.cabal` added to `cabal.project`.
- **No database migrations:** SQLite schema is created fresh by `seed.py` on every run.
- **Known limitation:** `COMPARISON.md` has placeholder fields for hardware info that should be filled in after actual benchmark runs. Run `generate-comparison.sh` to populate the data tables.

## Files Changed

### Shared Data Layer
- `benchmarks/shared/schema.sql` — Users table DDL
- `benchmarks/shared/seed.py` — Deterministic 10K-row seed script
- `benchmarks/shared/README.md` — Seed script usage

### C# / .NET App
- `benchmarks/dotnet-rest/RedisBenchmark/Program.cs` — Full REST API with cache-aside
- `benchmarks/dotnet-rest/RedisBenchmark/RedisBenchmark.csproj` — Project file with NuGet deps
- `benchmarks/dotnet-rest/.gitignore` — Excludes bin/obj

### Haskell App
- `benchmarks/haskell-rest/haskell-rest-benchmark.cabal` — Package definition
- `benchmarks/haskell-rest/src/Main.hs` — Full REST API with cache-aside
- `cabal.project` — Added `benchmarks/haskell-rest` to packages list

### Benchmark Scripts
- `benchmarks/scripts/run-benchmarks.sh` — Core benchmark runner (4 scenarios × 2 targets)
- `benchmarks/scripts/mixed-bench.js` — Node.js mixed workload helper
- `benchmarks/scripts/package.json` — Autocannon dependency
- `benchmarks/scripts/run-standalone.sh` — Full standalone automation
- `benchmarks/scripts/run-cluster.sh` — Full cluster automation

### Cluster Infrastructure
- `docker-cluster-host/docker-compose.yml` — 5-node cluster with host networking
- `docker-cluster-host/make_cluster.sh` — Cluster creation script
- `docker-cluster-host/redis{1..5}.conf` — Per-node Redis configs

### Results & Analysis
- `benchmarks/results/COMPARISON.md` — Comparison document with analysis
- `benchmarks/results/generate-comparison.sh` — Regenerates comparison tables from JSON
- `benchmarks/results/.gitkeep` — Placeholder for results directories

### Config
- `.gitignore` — Added entries for bench.db, results dirs, node_modules, cabal.project.local
