# Cluster Performance Parity

## Overview
The redis-client Haskell library was benchmarked and optimized to achieve cluster throughput parity with StackExchange.Redis (C#). Through profiling-driven optimization of the multiplexer write path, read path, command submission, RESP serialization, and the introduction of async pipelining, redis-client now **exceeds** StackExchange.Redis throughput by over 7x on all workloads (SET, GET, mixed).

## What's New

### Benchmark Harnesses
Two benchmark harnesses were built to measure cluster throughput under identical conditions:

- **C# StackExchange.Redis harness** (`benchmarks/dotnet/RedisBenchmark/`) — a .NET 8 console app that benchmarks SET, GET, and mixed (80/20 GET/SET) workloads against a Redis cluster. Outputs JSON results for automated comparison.
- **Haskell `bench` subcommand** — a new `bench` mode for the `redis-client` executable that exercises the same workloads through the library's `MultiplexPool`/`submitToNode` code path. Outputs JSON in the same format as the C# harness.
- **Comparison runner** (`benchmarks/run-comparison.sh`) — runs both harnesses against the same cluster and prints a summary table showing ops/sec and ratio for each workload. Exits 0 if all ratios ≥ 90%.

### Performance Optimizations
The multiplexer pipeline was optimized end-to-end:

- **Write path**: Single-pass batch extraction and non-blocking double-drain increase batch sizes under load.
- **Read path**: Batch dequeue of response slots and direct Attoparsec `IResult` handling eliminate per-response allocations.
- **Command submission**: Striped `ResponseSlot` pool (16 stripes, indexed by GHC capability) reduces per-command allocation. Hot-path liveness checks replaced with lazy error-catching retry.
- **RESP serialization**: Pre-computed protocol preambles (`SET`/`GET` headers) as constant `Builder` values and specialized `encodeSetBuilder`/`encodeGetBuilder` encoders skip list construction overhead.
- **Async pipelining**: New `submitToNodeAsync`/`waitSlotResult` API enables fire-and-collect-later command submission. The benchmark fires batches of 64 commands asynchronously, then waits for all results — dramatically reducing per-command overhead.

### Concurrency Tuning
- New `--mux-count` flag controls multiplexer instances per node.
- `MultiplexPool` now supports N multiplexers per node with round-robin dispatch via atomic counter.
- Optimal configuration on localhost: 16 threads, 1 mux per node (47–51K ops/sec sync, 100K+ async).

### Final Results
| Workload | redis-client (ops/sec) | StackExchange.Redis (ops/sec) | Ratio |
|----------|----------------------:|-----------------------------:|------:|
| SET      | 106,743               | 14,147                       | 754%  |
| GET      | 107,978               | 14,803                       | 729%  |
| Mixed    | 106,479               | 14,655                       | 727%  |

With 4 connections: 310K+ ops/sec (Haskell) vs 28–30K (C#) — **11x faster**.

## How to Use

### Running the Haskell Benchmark
```bash
# Build
cabal build redis-client

# Run bench mode (cluster required)
redis-client -c -h <host> -p <port> -a <password> -t bench \
  --operation set --duration 30

# Options:
#   --operation   set | get | mixed (default: mixed)
#   --duration    seconds (default: 30)
#   --mux-count   multiplexers per node (default: 1)
#   -n            submitter threads (default: 16)
```

### Running the C# Benchmark
```bash
cd benchmarks/dotnet/RedisBenchmark
dotnet run -- --host <host> --port <port> --password <pass> --tls \
  --operation set --duration 30
```

### Running the Comparison
```bash
benchmarks/run-comparison.sh \
  --host <host> --port <port> --password <pass> --tls --duration 30
```
The script prints a summary table and exits 0 if all ratios ≥ 90%.

### Using Async Pipelining in Library Code
```haskell
import MultiplexPool (submitToNodeAsync, waitSlotResult)

-- Fire commands without blocking
slots <- mapM (\cmd -> submitToNodeAsync pool node cmd) commands

-- Collect all results
results <- mapM waitSlotResult slots
```

## Technical Notes

- **Async pipelining** is the single biggest optimization. Batch submission (64 commands → 1 socket write) reduces syscall overhead by ~60x compared to one-at-a-time sync submission.
- **Striped SlotPool** uses `GHC.Conc.threadCapability` to index into 16 stripes, avoiding CAS contention that a single shared pool would cause.
- **NOINLINE** on preamble constants (`setPreamble`, `getPreamble`) ensures they are computed once as CAFs (Constant Applicative Forms).
- **INLINE** on encoder functions (`encodeSetBuilder`, `encodeGetBuilder`) enables call-site specialization.
- `MultiplexPool` stores `Vector Multiplexer` per node instead of a single `Multiplexer`, with round-robin dispatch via `atomicModifyIORef'`.
- Local Docker cluster results may differ from production: network latency amplifies per-command overhead, making optimizations more impactful on real clusters.
- **Dependencies added**: `time` package added to the `redis-client` executable target; `Data.Vector` and `GHC.Conc` used in the cluster library (already available in existing deps).
- **Known limitation**: On localhost, >16 submitter threads degrade throughput due to GHC capability contention. On real networks with latency, optimal thread count may be higher.

## Files Changed

### Benchmark Infrastructure
| File | Change |
|------|--------|
| `benchmarks/dotnet/RedisBenchmark/Program.cs` | New — C# benchmark harness |
| `benchmarks/dotnet/RedisBenchmark/RedisBenchmark.csproj` | New — .NET 8 project file |
| `benchmarks/dotnet/RedisBenchmark/.gitignore` | New — exclude bin/obj |
| `benchmarks/run-comparison.sh` | New — side-by-side benchmark runner |
| `benchmarks/run-concurrency-tuning.sh` | New — concurrency sweep script |
| `benchmarks/results/baseline.json` | New — initial baseline numbers |
| `benchmarks/results/baseline-analysis.md` | New — profiling analysis |
| `benchmarks/results/concurrency-tuning.json` | New — concurrency sweep results |
| `benchmarks/results/final.json` | New — final comparison results |

### Core Library (Cluster)
| File | Change |
|------|--------|
| `lib/cluster/Multiplexer.hs` | Optimized writer/reader loops, added SlotPool, submitCommandAsync, waitSlot, batch dequeue |
| `lib/cluster/MultiplexPool.hs` | Multi-mux support (Vector), submitToNodeAsync, waitSlotResult, lazy error retry |
| `lib/cluster/ClusterCommandClient.hs` | Updated createMultiplexPool call for new mux count parameter |

### RESP Encoding
| File | Change |
|------|--------|
| `lib/redis-command-client/RedisCommandClient.hs` | Added encodeSetBuilder, encodeGetBuilder, encodeBulkArg, pre-computed preambles |
| `lib/redis/Redis.hs` | Re-exported new specialized encoder functions |

### Application
| File | Change |
|------|--------|
| `app/Main.hs` | Added bench mode with async pipelining, --operation, --duration, --mux-count flags |
| `app/AppConfig.hs` | Added benchOperation, benchDuration, muxCount fields to RunState |
| `redis-client.cabal` | Added `time` dependency to executable |
