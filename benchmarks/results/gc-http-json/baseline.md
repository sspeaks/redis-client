# GC/HTTP/JSON Optimization — Pre-Optimization Baseline

Captured: 2026-02-12 (cluster mode, 5-node Redis cluster on ports 7000–7004)

This document records the **pre-optimization baseline** for the GC/HTTP/JSON
gap analysis. All measurements are from the existing cluster benchmark results
(`benchmarks/results/cluster/`) and are consistent with COMPARISON.md.

---

## Test Configuration

| Setting | Value |
|---------|-------|
| Redis Mode | Cluster (5 masters, ports 7000–7004, host networking) |
| Duration | 30 seconds per scenario |
| Haskell HTTP | Scotty (warp), port 3000 |
| .NET HTTP | ASP.NET Core Minimal API (Kestrel), port 5000 |
| Haskell RTS | `-N` only (default, no GC tuning) |
| Haskell GHC | 9.8.4, `-O2 -threaded -rtsopts` |
| .NET | 8.0, Release build |

### Autocannon Settings by Scenario

| Scenario | Connections | Pipelining |
|----------|:-----------:|:----------:|
| GET single | 100 | 10 |
| GET list | 100 | 10 |
| POST | 10 | 1 |
| Mixed | 20 | 1 |

---

## Throughput (requests/second)

| Scenario | Haskell | .NET | Ratio (.NET / Haskell) |
|----------|--------:|-----:|:----------------------:|
| GET single | 87,492 | 138,479 | **1.58×** |
| GET list | 8,549 | 12,192 | **1.43×** |
| POST | 131 | 186 | **1.42×** |
| Mixed | 598 | 774 | **1.29×** |

---

## Latency — Haskell (milliseconds)

| Scenario | p50 | p97.5 | p99 | p99.9 |
|----------|----:|------:|----:|------:|
| GET single | 11 | 15 | 16 | 20 |
| GET list | 116 | 153 | 161 | 184 |
| POST | 9 | 1,035 | 1,736 | 4,549 |
| Mixed | <1 | 188 | 1,035 | 3,542 |

## Latency — .NET (milliseconds)

| Scenario | p50 | p97.5 | p99 | p99.9 |
|----------|----:|------:|----:|------:|
| GET single | 6 | 13 | 15 | 24 |
| GET list | 84 | 115 | 124 | 200 |
| POST | 5 | 312 | 463 | 1,222 |
| Mixed | <1 | 309 | 466 | 1,071 |

---

## Response Status Codes

| Scenario | Target | Total | 2xx | 404 | 500 | 2xx % |
|----------|--------|------:|----:|----:|----:|------:|
| GET single | Haskell | 2,624,686 | 2,624,686 | 0 | 0 | 100.0% |
| GET single | .NET | 4,154,030 | 4,154,030 | 0 | 0 | 100.0% |
| GET list | Haskell | 256,464 | 256,464 | 0 | 0 | 100.0% |
| GET list | .NET | 365,734 | 365,734 | 0 | 0 | 100.0% |
| POST | Haskell | 3,922 | 3,919 | 0 | 3 | 99.9% |
| POST | .NET | 5,587 | 5,587 | 0 | 0 | 100.0% |
| Mixed | Haskell | 17,946 | 17,380 | 560 | 6 | 96.9% |
| Mixed | .NET | 23,227 | 22,193 | 1,034 | 0 | 95.6% |

---

## Consistency Check vs COMPARISON.md

The baseline numbers match the cluster results in COMPARISON.md exactly:

| Scenario | COMPARISON.md Haskell | Baseline Haskell | Δ |
|----------|----------------------:|------------------:|:-:|
| GET single | 87,492 | 87,492 | 0% |
| GET list | 8,549 | 8,549 | 0% |
| POST | 131 | 131 | 0% |
| Mixed | 598 | 598 | 0% |

| Scenario | COMPARISON.md .NET | Baseline .NET | Δ |
|----------|-------------------:|---------------:|:-:|
| GET single | 138,479 | 138,479 | 0% |
| GET list | 12,192 | 12,192 | 0% |
| POST | 186 | 186 | 0% |
| Mixed | 774 | 774 | 0% |

All values are identical (within 0% variance). These are the same benchmark
run results documented in COMPARISON.md, confirming consistency.

---

## Key Observations

1. **GET single has the largest gap (1.58×)** — this is the purest
   HTTP→Redis→HTTP path (cache hits) and represents the gap this optimization
   effort aims to narrow.

2. **The gap is consistent across scenarios** (1.29×–1.58×), suggesting
   systemic overhead from GC, HTTP framework, and/or JSON serialization.

3. **POST and Mixed are SQLite-bottlenecked** — both implementations achieve
   only ~130–780 req/s due to SQLite's single-writer constraint. Redis client
   performance is not the limiting factor here.

4. **Tail latency gap is significant** — Haskell's p99.9 is notably worse
   than .NET's for POST (4,549ms vs 1,222ms = 3.7×), likely due to GHC's
   stop-the-world GC pauses compounding with SQLite busy-wait retries.

---

*Data source: `benchmarks/results/cluster/{haskell,dotnet}_{get_single,get_list,post,mixed}.json`
from benchmark run on 2026-02-12.*
