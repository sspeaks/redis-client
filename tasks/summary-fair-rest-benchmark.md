# Fair REST Benchmark

## Overview

Re-ran the REST+Redis benchmark suite with Haskell multiplexing enabled to produce a trustworthy, apples-to-apples comparison between the Haskell `redis-client` library and .NET's StackExchange.Redis. The previous benchmark results were unfair because the Haskell app serialized every Redis command through a single connection while the .NET app used built-in multiplexing. This effort fixed that disparity, repaired broken POST and mixed-workload scenarios, and produced a detailed comparison document with real data.

## What's New

### Multiplexed Redis in the Haskell Benchmark App

The Haskell REST benchmark app now uses the `Multiplexer` for standalone Redis mode, allowing concurrent HTTP requests to pipeline Redis commands over a single connection — matching how StackExchange.Redis works in the .NET app. Cluster mode continues to use `MultiplexPool` (which already supported multiplexing).

### Fixed POST and Mixed Workload Benchmarks

- **POST scenario**: Now generates unique email addresses per request using autocannon's programmatic API (`setupRequest` callback), preventing SQLite UNIQUE constraint violations that previously caused near-100% 500 errors after the first request.
- **Mixed scenario**: All request types (GET, POST, PUT, DELETE) now generate per-request variation — unique emails for writes, randomized user IDs for reads and deletes. The 70/10/10/5/5 distribution is maintained. Throughput went from 7–46 req/s (broken) to 595–737 req/s (working).

### SQLite Concurrency Fixes

Both the Haskell and .NET apps now enable WAL mode and set `busy_timeout=5000` on every SQLite connection, preventing write stalls under concurrent load. Connection counts are tuned per scenario: 100 connections for read-only, 10–20 for write-heavy workloads.

### Fair Comparison Document

A comprehensive benchmark comparison document at `benchmarks/results/COMPARISON.md` replaces the old placeholder data with actual results. It includes hardware specs, configuration details, per-scenario results tables, and a detailed analysis of why the numbers differ.

## How to Use

### Prerequisites

- Docker (for Redis)
- Node.js with `autocannon` installed (`npm install` in `benchmarks/scripts/`)
- GHC 9.8+ / Cabal (or use `nix-shell`)
- .NET 8 SDK
- Python 3 (for `seed.py`)

### Running the Benchmarks

1. **Start Redis** (standalone):
   ```bash
   docker run -d --name redis-bench -p 6379:6379 redis:latest
   ```

2. **Seed the SQLite database** (10,000 users):
   ```bash
   python3 benchmarks/shared/seed.py
   ```

3. **Build both apps**:
   ```bash
   # Haskell
   nix-shell --run "cabal build haskell-rest-benchmark"

   # .NET
   cd benchmarks/dotnet-rest && dotnet build
   ```

4. **Run the full benchmark suite**:
   ```bash
   cd benchmarks/scripts
   ./run-benchmarks.sh
   ```
   This runs all 4 scenarios (GET single, GET list, POST, Mixed) against both apps, reseeding SQLite between targets. Results are saved as JSON to `benchmarks/results/standalone/`.

5. **View results**:
   ```bash
   cat benchmarks/results/COMPARISON.md
   ```

### Benchmark Scenarios

| Scenario   | Connections | Pipelining | Duration | Notes                        |
|------------|-------------|------------|----------|------------------------------|
| GET single | 100         | 10         | 30s      | Cache-aside pattern          |
| GET list   | 100         | 10         | 30s      | Paginated list (no caching)  |
| POST       | 10          | 1          | 30s      | SQLite single-writer limited |
| Mixed      | 20          | 1          | 30s      | 70/10/10/5/5 distribution    |

### Standalone Results Summary

| Scenario   | Haskell (req/s) | .NET (req/s) | Ratio (.NET/Haskell) |
|------------|-----------------|--------------|----------------------|
| GET single | 95,624          | 132,563      | 1.39×                |
| GET list   | 8,800           | 12,400       | 1.42×                |
| POST       | 123             | 183          | 1.49×                |
| Mixed      | 595             | 737          | 1.24×                |

All scenarios within the 3× fairness threshold. The gap is distributed across the full stack (HTTP framework, GC, serialization) rather than caused by a single bottleneck.

## Technical Notes

- **Multiplexer usage**: Standalone mode creates a `Multiplexer` via `createMultiplexer client (receive client)` and sends commands with `submitCommand mux (encodeCommandBuilder ["CMD", ...])`. The `RedisCommands` typeclass cannot be used directly with `Multiplexer` — commands must be manually RESP-encoded.
- **autocannon programmatic API**: POST and mixed benchmarks use Node.js scripts (`post-bench.js`, `mixed-bench.js`) with `setupRequest` callbacks for per-request dynamic data. The CLI `-b` flag only supports static bodies.
- **SQLite constraints**: Write benchmarks are limited by SQLite's single-writer architecture. WAL mode and `busy_timeout` are essential for concurrent access. The seed script uses `DELETE` + `INSERT OR REPLACE` (not `DROP TABLE`) so it works while apps hold open connections.
- **autocannon reports p97.5** (not p95) — the JSON key is `p97_5`.
- **Mixed scenario 404s are expected**: DELETE removes users that subsequent GET requests can't find.
- **No new library dependencies** were added to `redis-client`.

## Files Changed

### Benchmark App (Haskell)
- `benchmarks/haskell-rest/src/Main.hs` — Standalone mode now uses `Multiplexer`; added WAL mode + busy_timeout for SQLite
- `benchmarks/haskell-rest/haskell-rest-benchmark.cabal` — Removed unused `mtl` dependency

### Benchmark App (.NET)
- `benchmarks/dotnet-rest/RedisBenchmark/Program.cs` — Added WAL mode + busy_timeout for SQLite

### Benchmark Scripts
- `benchmarks/scripts/run-benchmarks.sh` — Tuned connections per scenario, added reseeding between targets
- `benchmarks/scripts/post-bench.js` — New: programmatic autocannon for POST with unique emails
- `benchmarks/scripts/mixed-bench.js` — Fixed all request types to use per-request dynamic data
- `benchmarks/shared/seed.py` — WAL mode, robust DELETE+INSERT seeding

### Results
- `benchmarks/results/standalone/*.json` — 8 result files (4 scenarios × 2 apps)
- `benchmarks/results/COMPARISON.md` — Full comparison document with actual data and analysis

### Build / Test Fixes
- `cabal.project` — Added `benchmarks/haskell-rest` package
- `.gitignore` — Added `node_modules`
- `test/ClusterE2E/Utils.hs` — Fixed trailing comma parse error
- `test/ClusterE2E/TopologyRefresh.hs` — Fixed trailing comma parse error
