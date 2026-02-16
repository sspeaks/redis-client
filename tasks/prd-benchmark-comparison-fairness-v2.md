# PRD: Benchmark Comparison Fairness Overhaul (v2)

## Overview

A ground-up rethink of the hask-redis-mux vs StackExchange.Redis benchmark comparison to ensure methodological fairness, eliminate systematic bias, and produce credible results — even where StackExchange.Redis outperforms.

## Problem Statement

The current comparison documentation produces results where hask-redis-mux appears to win nearly every metric against StackExchange.Redis. This is implausible — StackExchange.Redis is a decade-old, battle-tested library optimized at Stack Overflow scale. The results undermine the comparison's credibility.

### Root Causes

After auditing both benchmark programs, the following systematic biases were identified:

#### 1. C# Uses Synchronous API (Most Impactful)

The C# benchmark calls `db.StringGet()`, `db.StringSet()`, `db.Ping()` — **synchronous** methods. StackExchange.Redis is architected for async/await. Its sync methods internally perform an async operation and block the calling thread, which:
- Causes thread pool starvation under `Parallel.For` concurrency
- Prevents the ConnectionMultiplexer from batching commands optimally
- Is **not** how any production .NET application uses the library

The Haskell benchmark uses the library idiomatically (green threads + multiplexer). The C# benchmark should do the same (async/await + multiplexer).

#### 2. Haskell PING Bypasses the Cluster Client

The Haskell benchmark sends PING via `submitToNode muxPool addr pingCmd` — raw multiplexer access that skips cluster routing, topology lookup, MOVED/ASK handling, and all high-level abstractions. Meanwhile C# uses `db.Ping()` which goes through the full ConnectionMultiplexer path. This gives Haskell an artificial ~3x latency advantage on PING.

#### 3. Pipeline Benchmark Is Apples-to-Oranges

- **C#**: Uses `CreateBatch` — true client-side pipelining (100 commands sent at once, responses collected). Result: 1,035 μs.
- **Haskell**: Uses `mapM_` with 100 sequential `get` calls — **not pipelining at all**. Each call waits for a response before sending the next. Result: 6,604 μs.

C# rightfully wins 6x here, but the comparison implies both are doing "pipelining" when they aren't.

#### 4. C# REST Server Uses Sync Redis in Async Framework

The ASP.NET Core REST server (`RestServer/Program.cs`) calls `db.StringGet()` and `db.StringSet()` synchronously inside async request handlers. This causes thread pool starvation under load, explaining:
- Cache-hit data completely missing (`-` in tables)
- Cache-miss throughput of **11 req/sec** (vs Haskell's 1,314)

#### 5. Memory Metrics Are Not Comparable

- **Haskell**: Reports `max_residency_bytes` (4.9 MB) — only live heap objects
- **C#**: Reports `peak_working_set_bytes` (81 MB) — all process memory (code, stack, GC regions, runtime, etc.)

These measure fundamentally different things. Displaying them side-by-side implies Haskell uses 16x less memory, which is misleading.

#### 6. Missing Data Rendered as Dashes

When a benchmark fails to produce data (e.g., C# REST cache-hit), the template renders `-` in the table. This looks like the library can't do it, rather than a benchmark infrastructure failure. The template should either skip the section or show an explicit "benchmark failed" note.

## Goals

- Make **both** benchmarks use their respective library's idiomatic, production-recommended patterns
- Use async/await in C# benchmarks (the way StackExchange.Redis is designed to be used)
- Route Haskell PING through the same cluster client abstraction as all other operations
- Clearly label pipeline benchmarks as testing different mechanisms, or add equivalent pipeline support to Haskell's benchmark
- Fix C# REST server to use async Redis calls
- Compare equivalent memory metrics or clearly document the differences
- Handle missing benchmark data gracefully in templates (no bare `-` dashes)
- Show honest data with architectural context explaining **why** each library excels in certain areas
- Regenerate all output after fixes

## Non-Goals

- Adding new Redis operations beyond what's already benchmarked
- Changing the comparison document structure (sections 1-5, 7-8 stay as-is)
- Supporting standalone Redis mode in benchmarks
- Optimizing hask-redis-mux to beat StackExchange.Redis — the goal is a **fair** comparison
- Changing Chart.js chart types or visual design

## Target Audience

Software engineers evaluating Redis client libraries across Haskell and .NET ecosystems who need trustworthy, fair benchmark data to inform technology decisions.

---

## Functional Requirements

### FR-1: Convert C# Raw Benchmark to Async (Program.cs)

- Replace all sync Redis calls with async equivalents:
  - `db.Ping()` → `await db.PingAsync()`
  - `db.StringGet()` → `await db.StringGetAsync()`
  - `db.StringSet()` → `await db.StringSetAsync()`
  - `db.KeyDelete()` → `await db.KeyDeleteAsync()`
- Convert `RunBenchmark` to async: use `Task.Run` with async lambdas instead of `Parallel.For`
- Each concurrent task should use `await` for Redis calls (not `.Result` or `.GetAwaiter().GetResult()`)
- Keep the same thread count (`Environment.ProcessorCount`), warmup (10%), wall-clock throughput, and per-op latency measurement
- Pre-population should also use async (`StringSetAsync`)

### FR-2: Fix Haskell PING Benchmark (Main.hs)

- Route PING through the cluster client (`run`) instead of raw `submitToNode`
- Use the same `run` abstraction as SET, GET, DEL, etc.
- Remove the `masterNodes`/`muxPool`/`pingCmd` special-case code
- The benchmark should call `run (ping :: ClusterCommandClient PlainTextClient ByteString)` or equivalent cluster-client PING command

### FR-3: Fix Pipeline Benchmark Labeling and Methodology

- **Option A (Preferred)**: Rename the benchmark to clearly indicate different mechanisms:
  - Haskell: `sequential_100_gets` (or similar — since it's sequential, not pipelined)
  - C#: `pipeline_100_gets` (keeps the name since it IS pipelining)
- **Option B**: Add actual pipelining support to the Haskell benchmark if the library supports it, so both benchmark true pipelining
- Add a methodology note in the template explaining exactly what each library does in this benchmark
- The rendered comparison table should make the mechanism clear (column headers or footnotes)

### FR-4: Fix C# REST Server (RestServer/Program.cs)

- Convert all Redis calls to async:
  - `db.StringGet(cacheKey)` → `await db.StringGetAsync(cacheKey)`
  - `db.StringSet(cacheKey, jsonData, ...)` → `await db.StringSetAsync(cacheKey, jsonData, ...)`
- Make the endpoint handler properly async (it already returns `IResult`, just needs `async` lambda)
- Verify the REST server can handle concurrent load without thread starvation

### FR-5: Fix Memory/GC Comparison (06_benchmarks.md.tmpl)

- Add context to the memory comparison section explaining what each metric measures:
  - Haskell `max_residency_bytes`: maximum live heap data at any GC point (does not include stack, code, or GC working memory)
  - C# `peak_working_set_bytes`: total process memory including runtime, JIT-compiled code, GC regions, thread stacks
- Consider adding Haskell's total process memory (from `/proc/self/status` or RTS stats `total_elapsed_s` context) for a fairer comparison
- Alternatively, report C#'s `GC.GetTotalMemory(true)` (managed heap only) alongside `peak_working_set_bytes` so there's a like-for-like metric

### FR-6: Handle Missing Benchmark Data Gracefully (06_benchmarks.md.tmpl)

- When a benchmark produces no data for one library, do NOT render `-` in the table
- Instead: either omit the row, show `N/A (benchmark failed)`, or add a footnote explaining the data is missing and why
- For the REST section: if only one library has REST data, show a single-library table with a note that the other library's benchmark did not complete
- The `_fmt()` function's default should produce a meaningful placeholder, not a bare dash

### FR-7: Add Architectural Context Narrative (06_benchmarks.md.tmpl)

- After the benchmark data tables, add a "Results Analysis" subsection that:
  - Calls out where each library excels and provides architectural reasoning
  - Example: "StackExchange.Redis excels at pipelining due to its dedicated `CreateBatch` API..."
  - Example: "hask-redis-mux benefits from GHC's lightweight green threads for high-concurrency single-op workloads..."
- This should be templated text that adapts based on which library has better numbers in each category
- Keep it factual and balanced — no marketing language

### FR-8: Update Benchmark Runner for Async C# (benchmark_runner.py)

- No structural changes needed to the runner itself — it just calls `dotnet run` and parses JSON
- Verify the runner still correctly captures output after the C# benchmark changes
- Ensure the REST benchmark runner properly waits for the async C# REST server to be ready

### FR-9: Regenerate All Output

- Delete existing `comparison/output/comparison.md` and `comparison/output/comparison.html`
- Re-run `python3 generate_comparison.py` after all fixes are applied
- Verify: no `-` dashes in tables, REST data present for both libraries, architectural context rendered
- Verify the HTML page renders correctly with all charts populated

---

## Technical Requirements

### TR-1: C# Async Benchmark Pattern

```csharp
// Instead of:
Parallel.For(0, NumThreads, ..., t => {
    db.StringGet(...);  // BLOCKS thread
});

// Use:
var tasks = Enumerable.Range(0, NumThreads).Select(t => Task.Run(async () => {
    await db.StringGetAsync(...);  // non-blocking
}));
await Task.WhenAll(tasks);
```

- Use `Stopwatch` for per-op timing (still valid with async — measure around each await)
- Wall-clock throughput calculation remains the same
- Thread-local latency lists should use `List<double>` per task (no shared state)

### TR-2: C# REST Server Async Pattern

```csharp
// Instead of:
app.MapGet("/item/{id}", (string id, HttpContext ctx) => {
    var cached = db.StringGet(cacheKey);  // BLOCKS request thread
    ...
});

// Use:
app.MapGet("/item/{id}", async (string id, HttpContext ctx) => {
    var cached = await db.StringGetAsync(cacheKey);
    ...
});
```

### TR-3: Haskell PING via Cluster Client

The Haskell benchmark should use whatever PING command is available through the `ClusterCommandClient` / `RedisCommands` typeclass. If `ping` is not exposed as a typed command, add it or use `executeCommand ["PING"]` through the cluster client.

### TR-4: Memory Metric Equivalence

For a fair memory comparison, report these side-by-side:

| Metric | Haskell Source | C# Source |
|--------|---------------|-----------|
| Live heap | `max_residency_bytes` (RTS -s) | `GC.GetTotalMemory(true)` |
| Total process | `peak_working_set_bytes` from /proc | `Process.PeakWorkingSet64` |

This gives readers two data points that are actually comparable.

---

## Success Criteria

1. C# benchmark uses `async/await` for all Redis operations — no sync `StringGet`/`StringSet` calls remain
2. Haskell PING goes through the cluster client, not raw multiplexer access
3. Pipeline benchmark clearly indicates the different mechanisms used by each library
4. C# REST server uses async Redis calls and produces valid cache-hit AND cache-miss data
5. No bare `-` dashes appear in any benchmark table
6. Memory section includes explanatory context about what each metric measures
7. An architectural context section explains where each library excels and why
8. After regeneration, StackExchange.Redis shows competitive or better numbers where expected (especially pipelining, single-op async throughput)
9. `python3 generate_comparison.py` produces complete output with no missing sections
