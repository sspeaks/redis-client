# GC/HTTP/JSON Gap Analysis & Optimization

## Overview

This feature investigates and addresses the remaining 1.58× throughput gap between the Haskell redis-client REST benchmark and its .NET equivalent. The hypothesis was that GC behavior, HTTP framework overhead (Scotty), and JSON serialization (Aeson) were the primary contributors. Through systematic measurement, GC tuning was confirmed as the dominant factor, closing the gap to 1.31×, while HTTP framework and JSON serialization were ruled out as significant contributors.

## What's New

### GC-Tuned Benchmark Performance (+21% throughput)

The Haskell REST benchmark now ships with optimized GHC runtime flags (`-H1024M -A128m -n8m -qb -N`) baked into the cabal file. These flags dramatically improve throughput for Redis-bound workloads:

| Scenario   | Before (req/s) | After (req/s) | Improvement | Gap vs .NET |
|------------|-----------------|----------------|-------------|-------------|
| GET single | 87,492          | 105,901        | +21.0%      | 1.31× (was 1.58×) |
| GET list   | 8,549           | 10,132         | +18.5%      | 1.20× (was 1.43×) |
| POST       | 131             | 126            | ~0% (SQLite-bound) | — |
| Mixed      | 598             | 578            | ~0% (SQLite-bound) | — |

### Gap Analysis Results

The investigation tested three hypothesized bottlenecks:

- **GC behavior — confirmed.** Large nursery and reduced GC frequency account for the vast majority of the gap. Tuning RTS flags closed 76% of the achievable throughput gap on GET single.
- **HTTP framework (Scotty) — ruled out.** Scotty adds only ~1.4% overhead vs raw Warp. Not worth replacing.
- **JSON serialization (Aeson) — ruled out.** In steady-state (cache-hit), JSON encoding is completely bypassed. Even on cache-miss, manual Builder encoding only gains ~5%. No impact on the .NET gap.

The remaining 1.31× gap is attributed to fundamental runtime differences between GHC and .NET's CLR.

### Reusable Benchmark Tooling

New scripts for targeted performance analysis:
- **GC tuning script** — test arbitrary RTS flag combinations against the REST benchmark
- **HTTP framework comparison** — benchmark Scotty vs raw Warp under identical conditions
- **JSON serialization comparison** — measure Aeson vs manual Builder with cache-hit and cache-miss scenarios

## How to Use

### Running Benchmarks with Optimized GC

The optimized RTS flags are already embedded in the cabal file. Just build and run normally:

```bash
# Build the benchmark
nix-shell --run "cabal build exe:haskell-rest-benchmark"

# Run cluster benchmarks (starts Redis cluster, seeds data, runs all scenarios)
cd benchmarks/scripts
./run-cluster.sh
```

### Testing Custom RTS Flag Combinations

Use the GC tuning script to experiment with different RTS configurations:

```bash
# Build the benchmark binary
BINARY=$(nix-shell --run "cabal list-bin exe:haskell-rest-benchmark")

# Run with a custom RTS flag set
cd benchmarks/scripts
./run-gc-tuning.sh "$BINARY"
```

### Running HTTP Framework Comparison

```bash
cd benchmarks/scripts
./run-http-framework.sh
```

This builds both the Scotty-based and Warp-only variants, then benchmarks them under identical conditions.

### Running JSON Serialization Comparison

```bash
cd benchmarks/scripts
./run-json-serialization.sh
```

Tests Aeson vs manual ByteString Builder encoding under cache-hit and cache-miss scenarios (uses background `FLUSHALL` to force cache misses).

### Viewing Results

All benchmark results are in `benchmarks/results/gc-http-json/`:
- `baseline.md` — pre-optimization baseline numbers
- `gc-tuning.md` — RTS flag comparison table
- `gc-applied.md` — all 4 scenarios with optimized flags
- `http-framework.md` — Scotty vs Warp analysis
- `json-serialization.md` — Aeson vs Builder analysis
- `optimization-decisions.md` — why HTTP/JSON changes were not applied
- `summary.md` — final per-factor contribution breakdown

The overall comparison is also updated in `benchmarks/results/COMPARISON.md`.

## Technical Notes

### RTS Flags Applied

The following GHC RTS flags were added to `benchmarks/haskell-rest/haskell-rest-benchmark.cabal` via `-with-rtsopts`:

| Flag | Purpose |
|------|---------|
| `-H1024M` | Suggested heap size — reduces major GC frequency |
| `-A128m` | Nursery size — reduces minor GC frequency (biggest single lever) |
| `-n8m` | Nursery chunk size — improves allocation locality |
| `-qb` | Disable parallel nursery GC — reduces GC thread sync overhead |
| `-N` | Use all available cores |

### Key Implementation Details

- **Cache-hit path bypasses JSON entirely** — raw Redis bytes are returned directly to the client, so JSON encoding performance only matters on cache misses
- **POST and Mixed benchmarks are SQLite-bound** (~130 and ~600 req/s) — GC/HTTP/JSON optimizations have no effect on these
- **Large nursery increases p99.9 latency** — individual GC pauses are longer (26ms vs 21ms), but throughput gains outweigh this for most use cases
- **Nonmoving GC** (`--nonmoving-gc`) provides the best tail latency (20ms p99.9) at the cost of ~2% throughput — useful when consistent latency matters more than throughput
- **Warp-only variant** (`WarpOnly.hs`) and **manual JSON encoder** (`ManualJson.hs`) remain in the codebase as reference implementations, but are not used by the main benchmark

### Dependencies

No new library dependencies were added. The manual JSON encoder uses only `bytestring` (Builder API) which is already a dependency.

### Known Limitations

- The remaining 1.31× gap vs .NET is attributed to GHC runtime overhead and is unlikely to be closed through application-level tuning
- p99.9 tail latency is slightly worse with the large nursery configuration (26ms vs 21ms with default)
- Benchmark results vary ~5-8% run-to-run for SQLite-bound scenarios (POST, Mixed)

## Files Changed

### Benchmark Application
- `benchmarks/haskell-rest/haskell-rest-benchmark.cabal` — added optimized RTS flags, added warp-only and manual-json executables
- `benchmarks/haskell-rest/src/WarpOnly.hs` — raw Warp benchmark variant (reference only)
- `benchmarks/haskell-rest/src/ManualJson.hs` — manual ByteString Builder JSON encoder (reference only)

### Benchmark Scripts
- `benchmarks/scripts/run-gc-tuning.sh` — RTS flag comparison script
- `benchmarks/scripts/run-http-framework.sh` — Scotty vs Warp comparison script
- `benchmarks/scripts/run-json-serialization.sh` — Aeson vs Builder comparison script

### Results & Documentation
- `benchmarks/results/gc-http-json/baseline.md` — pre-optimization baseline
- `benchmarks/results/gc-http-json/gc-tuning.md` — RTS flag comparison results
- `benchmarks/results/gc-http-json/gc-applied.md` — post-optimization results (all scenarios)
- `benchmarks/results/gc-http-json/http-framework.md` — HTTP framework analysis
- `benchmarks/results/gc-http-json/json-serialization.md` — JSON serialization analysis
- `benchmarks/results/gc-http-json/optimization-decisions.md` — decision rationale
- `benchmarks/results/gc-http-json/summary.md` — final per-factor breakdown
- `benchmarks/results/COMPARISON.md` — updated with GC/HTTP/JSON optimization section
- `benchmarks/results/gc-http-json/gc-optimized/` — raw JSON results (6 files)
- `benchmarks/results/gc-http-json/gc_*.json` — GC tuning raw results (5 files)
- `benchmarks/results/gc-http-json/http_*.json` — HTTP framework raw results (2 files)
- `benchmarks/results/gc-http-json/json_*.json` — JSON serialization raw results (4 files)
