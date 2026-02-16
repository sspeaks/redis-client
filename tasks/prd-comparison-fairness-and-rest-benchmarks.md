# PRD: Fix Benchmark Fairness & Add REST Benchmarks

## Overview

Audit and fix fairness issues in the hask-redis-mux vs StackExchange.Redis comparison benchmarks, and add live REST cache-aside benchmarks with results rendered in the HTML comparison page.

## Problem Statement

The current benchmark comparison between hask-redis-mux and StackExchange.Redis contains several methodological flaws that skew results unfairly. Additionally, the comparison document references REST cache-aside benchmarks (Section 6b) but no runnable REST servers or benchmarks actually exist. This undermines the credibility of the comparison.

### Identified Fairness Issues

1. **Concurrency mismatch**: Haskell benchmark uses `forConcurrently_` with N threads (from `getNumCapabilities`), while C# benchmark runs entirely single-threaded sequential loops. This inflates Haskell throughput numbers relative to C#.

2. **Key distribution mismatch**: Haskell distributes unique keys across cluster slots (`mkKey "bench:set:" i`), while C# uses a single fixed key (`bench:key`) for SET/GET. This means C# always hits one cluster node while Haskell exercises the full cluster topology.

3. **Throughput formula mismatch**: Haskell computes throughput from wall-clock time (concurrent), while C# sums individual latencies (sequential). These measure fundamentally different things.

4. **Pipeline semantics difference**: C# uses `CreateBatch` (true client-side pipelining), while Haskell does sequential `mapM_` through the cluster client (individual round-trips). This is not apples-to-apples, but both libraries' native pipelining mechanisms should be used and the difference documented.

5. **DEL key reuse**: C# reuses the same key `bench:delkey` every iteration (contention on one node), while Haskell generates unique keys per iteration.

6. **Pre-population mismatch**: Haskell pre-populates a 10,000-key read pool distributed across cluster slots. C# pre-populates 1,000 keys for batch tests and a single key for basic GET.

7. **REST benchmarks missing**: Section 6 template docstring mentions "REST Cache-Aside Benchmarks" but no runnable Scotty or ASP.NET servers exist for benchmarking.

## Goals

- Fix all identified fairness issues so benchmarks are apples-to-apples
- Make C# benchmark multi-threaded to match Haskell's concurrent execution model
- Use distributed unique keys in C# to match Haskell's cluster key distribution pattern
- Document methodology differences where libraries use fundamentally different mechanisms (e.g., pipelining)
- Build runnable REST servers (Scotty + ASP.NET Core) implementing the cache-aside pattern
- Benchmark REST cache-aside performance (latency and throughput) for both
- Add REST benchmark results to the HTML comparison page with Chart.js charts
- Regenerate all output from scratch after fixes

## Non-Goals

- Changing the Haskell benchmark structure (it's the reference; C# should match it)
- Adding new Redis operations beyond what's already benchmarked
- Changing the document structure (sections 1-5, 7-8 remain as-is)
- Supporting standalone Redis mode in benchmarks

## Target Audience

Software engineers evaluating Redis client libraries across Haskell and .NET ecosystems who need trustworthy, fair benchmark data.

---

## Functional Requirements

### FR-1: Fix C# Benchmark Concurrency (Program.cs)

- Add multi-threaded benchmark execution using `Parallel.For` or `Task.WhenAll` to match Haskell's `forConcurrently_` pattern
- Accept thread count from CLI args or use `Environment.ProcessorCount`
- Each thread should have its own latency collection list (avoid contention on shared list)
- Compute throughput from wall-clock time (matching Haskell's approach)
- Include warm-up phase per thread (matching Haskell's 10% warm-up)

### FR-2: Fix C# Key Distribution (Program.cs)

- Replace single fixed keys (`bench:key`, `bench:delkey`) with distributed unique keys per iteration, matching Haskell's `mkKey` pattern
- Pre-populate a 10,000-key read pool (matching Haskell's `readKeyPool`) distributed across cluster slots
- Use the same key naming conventions: `bench:set:{i}`, `bench:r:{i}`, `bench:del:{i}`, etc.
- Read benchmarks should index into the pool using `i % readKeyPool` (matching Haskell)
- Clean up all benchmark keys after completion

### FR-3: Fix C# Throughput Calculation (Program.cs)

- Measure wall-clock elapsed time for the entire measured phase (excluding warm-up)
- Compute `ops_per_sec = totalIterations / wallClockSeconds`
- This matches Haskell's throughput formula exactly

### FR-4: Document Pipeline Methodology (06_benchmarks.md.tmpl)

- Add a methodology note to Section 6 explaining that each library uses its native pipelining mechanism
- C# uses `CreateBatch` (client-side pipelining with deferred execution)
- Haskell uses multiplexed command submission through the cluster mux pool
- Note that these test different architectural approaches and results reflect real-world usage patterns

### FR-5: Build Haskell REST Server (Scotty + hask-redis-mux)

- Create `comparison/benchmarks/haskell/RestServer.hs` implementing the cache-aside pattern from Section 4
- `GET /item/:id` endpoint: check cache → on miss fetch mock data → populate cache with 60s TTL → return
- `GET /health` endpoint for readiness checking
- Accept port and Redis connection string from CLI args
- Must be buildable with cabal (add scotty dependency to benchmark.cabal)

### FR-6: Build C# REST Server (ASP.NET Core + StackExchange.Redis)

- Create `comparison/benchmarks/csharp/RestServer/` project implementing the same cache-aside pattern
- `GET /item/{id}` endpoint with identical logic to the Haskell version
- `GET /health` endpoint for readiness checking
- Accept port and Redis connection string from CLI args
- Must be buildable with `dotnet build`

### FR-7: REST Benchmark Runner (benchmark_runner.py)

- Add `run_haskell_rest_benchmarks(connection_string)` and `run_csharp_rest_benchmarks(connection_string)` functions
- Each function: builds the REST server, starts it in background, waits for health check, runs load test, collects results, stops server
- Use Python's `subprocess` + `concurrent.futures` for load generation (or `wrk`/`hey` if available)
- Measure: cache-hit latency (p50/p95/p99), cache-miss latency (p50/p95/p99), throughput (req/sec)
- Handle server startup failures gracefully

### FR-8: Add REST Benchmarks to HTML Page (06_benchmarks.md.tmpl)

- Add new Section 6d: REST Cache-Aside Benchmarks
- Include tables for cache-hit and cache-miss latency comparison
- Include throughput comparison table
- Add Chart.js charts: REST latency bar chart, REST throughput comparison chart
- Handle missing REST benchmark data gracefully (show skip message)

### FR-9: Regenerate All Output

- Delete existing `comparison/output/comparison.md` and `comparison/output/comparison.html`
- Re-run `generate_comparison.py` after all fixes are applied
- Verify the HTML page renders correctly with all benchmark sections including REST

---

## Technical Requirements

### TR-1: C# Benchmark Changes

- Use `System.Threading.Tasks.Parallel` or `Task.Run` with `ConcurrentBag<double>` for thread-safe latency collection
- Thread count should default to `Environment.ProcessorCount` (matching Haskell's `getNumCapabilities`)
- Connection string parsing should handle cluster format (comma-separated host:port pairs)

### TR-2: REST Server Dependencies

**Haskell**:
- `scotty` web framework
- `warp` (pulled in by scotty)
- `hask-redis-mux` from this repository
- Add to `benchmark.cabal` or create separate cabal file

**C#**:
- ASP.NET Core 8.0 (included in .NET 8 SDK)
- StackExchange.Redis NuGet package
- Separate `.csproj` in `RestServer/` subdirectory

### TR-3: Load Testing

- Use Python's built-in `concurrent.futures.ThreadPoolExecutor` for HTTP load generation
- Alternatively detect and use `wrk` or `hey` if available on PATH
- Default: 1000 requests, 10 concurrent connections
- Measure both cache-hit (pre-populated key) and cache-miss (new key) scenarios

### TR-4: Chart.js Integration

- Add REST-specific chart canvas IDs: `restLatencyChart`, `restThroughputChart`
- Follow existing chart style (hask-redis-mux purple `rgba(94,80,134,0.7)`, SE.Redis green `rgba(23,134,0,0.7)`)
- Charts should be responsive and match existing design

---

## Success Criteria

1. C# benchmark runs with the same thread count as Haskell and uses distributed keys
2. Throughput numbers for both libraries are computed from wall-clock time
3. Running the benchmarks side-by-side produces comparable results (no systematic bias from methodology)
4. REST servers for both Haskell and C# build and serve the cache-aside endpoint
5. REST benchmark data appears in Section 6d of the HTML output with interactive charts
6. Pipeline benchmark section includes methodology notes explaining the different mechanisms
7. `python3 generate_comparison.py` produces updated output with all fixes applied
8. No temporary build artifacts left after generation
