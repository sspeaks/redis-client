# Final Cluster Benchmark Results
**Date:** 2026-02-12
**After:** All optimizations (US-001 through US-007)
**Config:** 16 connections, 4 mux per node, 512B keys/values, 5 master nodes, 10s duration

## Direct Benchmark Results (Non-Profiled)

| Operation | Baseline (ops/sec) | Final (ops/sec) | Improvement |
|-----------|-------------------|-----------------|-------------|
| GET       | 34,671            | 238,867         | **6.89x**   |
| SET       | —                 | 204,260         | —           |
| Mixed     | —                 | 223,009         | —           |

## Direct Benchmark Results (Profiled)

| Operation | Baseline (ops/sec) | Final (ops/sec) | Improvement |
|-----------|-------------------|-----------------|-------------|
| GET       | 33,811            | 209,697         | **6.20x**   |
| SET       | —                 | 209,684         | —           |
| Mixed     | —                 | 210,218         | —           |

## REST Benchmark Comparison (Baseline, from autocannon)

These numbers are from the pre-optimization REST (HTTP) benchmark, measuring end-to-end throughput through the web server layer.

| Scenario   | .NET (req/s)  | Haskell (req/s) | Gap     |
|------------|---------------|-----------------|---------|
| GET single | 121,726       | 35,202          | 3.46x   |
| GET list   | 11,688        | 8,255           | 1.42x   |
| POST       | 183           | 122             | 1.50x   |
| Mixed      | 704           | 562             | 1.25x   |

**Note:** The REST benchmark measures HTTP server + Redis client combined throughput. The direct bench mode isolates the Redis client library performance.

## Throughput Improvement Summary

```
Baseline (US-001):    34,671 ops/sec (non-profiled GET)
Final (US-008):      238,867 ops/sec (non-profiled GET)
────────────────────────────────────────────────────────
Total improvement:    6.89x (589% increase)
```

The original 3.51x gap vs .NET (REST benchmark) has been addressed at the Redis client library level. The direct benchmark shows the Haskell client now achieves **238k ops/sec** compared to .NET's REST benchmark of **122k req/s**, though these measure different things (direct client vs HTTP endpoint).

## Final Profile (GET, Profiled)

| Rank | Cost Center | Module | Time% | Alloc% | Notes |
|------|------------|--------|-------|--------|-------|
| 1 | createMultiplexer | Multiplexer | 38.1% | 72.6% | Writer/reader loops (socket I/O) |
| 2 | benchWorker | Main | 28.9% | 4.5% | All library functions inlined here |
| 3 | throwSocketErrorWaitWrite | Network.Socket.Internal | 13.4% | 0.1% | writev syscall |
| 4 | benchKey | Main | 3.9% | 7.1% | Key generation (harness) |
| 5 | throwSocketErrorWaitRead | Network.Socket.Internal | 1.9% | 0.0% | recv syscall |
| 6 | throwSocketErrorIfMinus1RetryMayBlock | Network.Socket.Internal | 1.8% | 0.6% | Socket error handling |
| 7 | endOfLine | Data.Attoparsec | 1.8% | 1.8% | RESP parser (internal) |
| 8 | recv | Network.Socket.ByteString.IO | 1.4% | 6.7% | Buffer allocation |
| 9 | sendMany | Network.Socket.ByteString.IO | 1.2% | 0.5% | Vectored I/O |

## Profile Comparison: Baseline vs Final

| Cost Center | Baseline Time% | Final Time% | Change |
|-------------|---------------|-------------|--------|
| createMultiplexer | 40.3% | 38.1% | -2.2pp (multiplexer overhead reduced) |
| submitToNodeAsync | 33.8% | 0% | **Eliminated** (fully inlined) |
| submitCommandPooled | 1.8% | 0% | **Eliminated** (fully inlined) |
| crc16 | 1.3% | 0% | **Eliminated** (pure + inlined) |
| benchWorker | 0% | 28.9% | Appears (all inlined functions attributed here) |
| Socket write | 8.3% | 13.4% | +5.1pp (larger share since overhead removed) |
| Socket read | 1.9% | 1.9% | Unchanged |
| sendMany | 0% | 1.2% | New (vectored I/O) |

## Key Optimizations by Impact

1. **US-004: Per-node round-robin** — 6.6x improvement (eliminated cross-node CAS contention)
2. **US-002: Pure CRC16 + O(1) slot lookup** — 5% improvement
3. **US-007: Redirection fast path** — 3% improvement (profiled)
4. **US-006: Reader loop INLINE** — 2.8% improvement (profiled)
5. **US-003: Submit path INLINE** — 2-5% improvement
6. **US-005: Writer vectored I/O** — Stable (reduced syscalls, no regression)

## Remaining Bottlenecks

The profile is now dominated by irreducible costs:
- **Socket I/O (15.3%)** — writev + recv syscalls, can't reduce without io_uring
- **createMultiplexer (38.1%)** — Writer/reader loops doing actual network work
- **benchWorker (28.9%)** — All library hot-path functions inlined into the benchmark driver
- **Attoparsec internals (1.8%)** — RESP parser internals, can't inline further

Further gains would require architectural changes (io_uring, zero-copy networking, custom RESP parser bypassing Attoparsec).
