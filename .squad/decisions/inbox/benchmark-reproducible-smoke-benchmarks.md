### 2026-09-15: Reproducible smoke benchmarks cover standalone, cluster, and slow-server
**By:** Benchmark
**What:** Added a dedicated `redis-client-benchmark` executable with JSON output and made the bounded smoke benchmark run three short scenarios: standalone, cluster, and slow/stalled-server.
**Why:** The CI smoke path now exercises the same latency/allocation reporting surface that larger opt-in performance runs use, while keeping deeper parameter sweeps optional.
