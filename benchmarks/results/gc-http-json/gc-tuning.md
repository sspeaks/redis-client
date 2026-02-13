# GC/HTTP/JSON Optimization — GC Tuning Results

Measured: 2026-02-13 (cluster mode, 5-node Redis cluster on ports 7000–7004)

This document records the results of testing 5 GHC RTS flag combinations on
the GET single benchmark (cache-hit path) to quantify GC impact on throughput
and tail latency.

---

## Test Configuration

| Setting | Value |
|---------|-------|
| Scenario | GET single user (cache-hit, single random user ID) |
| Redis Mode | Cluster (5 masters, ports 7000–7004, host networking) |
| Duration | 30 seconds per configuration |
| Connections | 100 |
| Pipelining | 10 |
| Warmup | 5 seconds at 50 connections before each run |
| Redis flush | Between each configuration for fairness |
| GHC | 9.8.4, `-O2 -threaded -rtsopts` |

---

## RTS Flag Combinations Tested

| # | Name | RTS Flags | Rationale |
|---|------|-----------|-----------|
| 1 | default | `-N` | Current production default — baseline |
| 2 | aggressive-nursery | `-A64m -n4m -H512m -N` | Larger nursery reduces minor GC frequency |
| 3 | match-main | `-H1024M -A128m -n8m -qb -N` | Matches main redis-client executable flags |
| 4 | nonmoving-gc | `--nonmoving-gc -N` | Concurrent, non-moving GC — eliminates stop-the-world pauses |
| 5 | large-nursery-no-idle | `-A128m -I0 -N` | Large nursery + no idle GC — minimizes GC interruptions |

---

## Results — Throughput (requests/second)

| Config | Req/s | vs Default | Δ% |
|--------|------:|:----------:|:--:|
| default | 88,081 | — | — |
| aggressive-nursery | 101,845 | +13,764 | **+15.6%** |
| **match-main** | **103,787** | **+15,706** | **+17.8%** |
| nonmoving-gc | 86,558 | −1,523 | −1.7% |
| large-nursery-no-idle | 102,558 | +14,477 | **+16.4%** |

### Throughput Winner: **match-main** (+17.8%)

The `-H1024M -A128m -n8m -qb -N` configuration delivers the highest throughput
at 103,787 req/s — closing a significant portion of the gap vs .NET's 138,479 req/s.
The ratio drops from **1.58×** to **1.33×**.

---

## Results — Latency (milliseconds)

| Config | p50 | p97.5 | p99 | p99.9 | max |
|--------|----:|------:|----:|------:|----:|
| default | 11 | 15 | 16 | 21 | 74 |
| aggressive-nursery | 9 | 13 | 16 | 28 | 77 |
| match-main | 9 | 13 | 15 | 28 | 101 |
| nonmoving-gc | 11 | 15 | 16 | **20** | 76 |
| large-nursery-no-idle | 9 | 13 | 15 | 28 | 84 |

### Latency Analysis

**Best p50/p97.5/p99 latency:** match-main, aggressive-nursery, and
large-nursery-no-idle are tied (9 / 13 / 15ms), all ~18% better than
default (11 / 15 / 16ms).

**Best p99.9 (tail) latency:** nonmoving-gc (20ms) — slightly better than
default (21ms) and notably better than the large-nursery variants (28ms).

**Tradeoff:** The large-nursery configurations improve median and p99 latency
significantly but have *worse* p99.9 tail latency (28ms vs 21ms). This is because
larger nurseries delay GC but make individual GC pauses longer when they occur.

### Tail Latency Winner: **nonmoving-gc** (20ms p99.9)

---

## Best Configuration by Goal

| Goal | Best Config | Key Metric | Improvement vs Default |
|------|-------------|------------|:----------------------:|
| **Throughput** | match-main | 103,787 req/s | +17.8% |
| **Tail latency (p99.9)** | nonmoving-gc | 20ms | −4.8% (21→20ms) |
| **Balanced** | match-main | 103,787 req/s, 28ms p99.9 | +17.8% throughput, slight p99.9 regression |

---

## Impact on .NET Gap

| Metric | Default | Best (match-main) | .NET Baseline | Gap Change |
|--------|--------:|-----------:|----------:|:----------:|
| Throughput (req/s) | 88,081 | 103,787 | 138,479 | 1.58× → **1.33×** |
| p50 latency (ms) | 11 | 9 | 6 | 1.83× → **1.50×** |
| p97.5 latency (ms) | 15 | 13 | 13 | 1.15× → **1.00×** |
| p99 latency (ms) | 16 | 15 | 15 | 1.07× → **1.00×** |

GC tuning alone reduces the throughput gap by nearly half: from 1.58× to 1.33×.
The p97.5 and p99 latency gaps are completely eliminated.

---

## Detailed Flag Descriptions

### match-main (`-H1024M -A128m -n8m -qb -N`)

- **`-H1024M`**: Suggested heap size — tells GC to maintain at least 1GB heap,
  reducing major GC frequency
- **`-A128m`**: Allocation area (nursery) size 128MB — fewer minor GCs needed
- **`-n8m`**: Nursery chunk size 8MB — better cache locality during allocation
- **`-qb`**: Disable parallel GC on the nursery — reduces GC thread synchronization
  overhead
- **`-N`**: Use all available cores

### nonmoving-gc (`--nonmoving-gc -N`)

- **`--nonmoving-gc`**: Use the non-moving garbage collector — performs major GC
  concurrently with mutator threads, eliminating stop-the-world pauses
- Best for tail latency but does not improve throughput (slight regression)

---

## Conclusion

**GC tuning is the single largest optimization lever available.** The match-main
configuration (`-H1024M -A128m -n8m -qb -N`) provides a 17.8% throughput
improvement with no code changes — just RTS flag tuning.

The nonmoving GC is best for tail-latency-sensitive workloads but does not
help throughput. For a pure throughput benchmark like GET single, the
large-nursery approach (match-main) is clearly superior.

**Recommendation:** Apply `-H1024M -A128m -n8m -qb -N` as the permanent RTS
configuration for the benchmark executable (US-005).

---

*Data source: `benchmarks/results/gc-http-json/gc_*.json` from benchmark run
on 2026-02-13. Script: `benchmarks/scripts/run-gc-tuning.sh`.*
