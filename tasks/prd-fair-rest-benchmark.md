# PRD: Fair REST Benchmark — Haskell redis-client (with Multiplexing) vs C# StackExchange.Redis

## 1. Introduction / Overview

The previous REST+Redis benchmark (`ralph/rest-cache-benchmark` branch) produced results showing a **71× throughput gap** (Haskell 1,668 req/s vs C# 119,034 req/s on GET single). However, the benchmark was fundamentally unfair:

1. **Haskell had no multiplexing** — it used a single `PlainTextClient` connection, serializing all Redis commands sequentially. C#'s StackExchange.Redis multiplexes many concurrent operations over its connections, allowing true concurrent pipelining.

2. **POST scenarios were broken** — the benchmark used a hardcoded email address, causing SQLite UNIQUE constraint violations. Both apps produced massive 500 error rates (C# = 181,985/181,985 500s, Haskell = 8,530/8,531 500s).

3. **Mixed workload was broken** — both apps produced ~7-46 req/s (effectively non-functional), likely due to cascading failures from the POST errors.

4. **The redis-client library now HAS multiplexing** — the `ralph/cluster-performance-parity` branch added `Multiplexer` and `MultiplexPool` modules that provide true multiplexed pipelining (multiple threads submit commands concurrently, FIFO ordering guarantees correct response demultiplexing).

This PRD covers rebasing the benchmark onto the multiplexing branch, fixing the broken test scenarios, re-running all benchmarks fairly, and producing a trustworthy comparison document with detailed analysis.

## 2. Goals

- Re-run benchmarks with the Haskell app using multiplexed connections so both apps have equivalent connection models.
- Fix all broken benchmark scenarios (POST duplicate emails, mixed workload failures) so every scenario produces valid 2xx results.
- Produce a trustworthy comparison document with actual data, not placeholders.
- Explain architectural differences and their performance impacts with extra scrutiny if large gaps persist.
- Ensure both apps are doing exactly the same work (same endpoints, same cache pattern, same Redis commands, same SQLite queries).

## 3. User Stories

### US-001: Rebase Benchmark Branch onto Multiplexing Branch

**Description:** As a developer, I want the benchmark code rebased onto `ralph/cluster-performance-parity` so that the Haskell app can use the library's multiplexing features.

**Acceptance Criteria:**
- [ ] New branch created from `ralph/cluster-performance-parity` containing all benchmark code
- [ ] All benchmark files from `ralph/rest-cache-benchmark` are present (benchmarks/, scripts, dotnet-rest, haskell-rest, etc.)
- [ ] `cabal build haskell-rest-benchmark` succeeds on the new branch
- [ ] `dotnet build` succeeds for the C# app
- [ ] The `Multiplexer` and `MultiplexPool` modules are available for import
- [ ] Typecheck passes

### US-002: Update Haskell App to Use Multiplexing

**Description:** As a developer, I want the Haskell REST app to use the `Multiplexer` for standalone mode (and `MultiplexPool` via `ClusterClient` for cluster mode) so that Redis commands are pipelined and multiplexed across concurrent requests, matching StackExchange.Redis's architecture.

**Acceptance Criteria:**
- [ ] Standalone mode: creates a `Multiplexer` wrapping the `PlainTextClient` connection, all Redis commands go through `submitCommand` instead of `evalStateT`
- [ ] Multiple concurrent HTTP requests can execute Redis commands simultaneously without serialization
- [ ] The same cache-aside logic is preserved (GET checks cache, populates on miss with 60s TTL, writes invalidate)
- [ ] Redis key format remains `user:{id}` (identical to C# app)
- [ ] Cluster mode still works via `ClusterClient` (which already uses `MultiplexPool`)
- [ ] App starts and serves requests correctly on both standalone and cluster Redis
- [ ] `cabal build` succeeds
- [ ] Typecheck passes

### US-003: Fix POST Benchmark Scenario (Unique Emails)

**Description:** As a developer, I want the POST benchmark to generate unique email addresses per request so that SQLite UNIQUE constraint violations don't cause 500 errors.

**Acceptance Criteria:**
- [ ] The autocannon POST scenario in `run-benchmarks.sh` generates unique emails (e.g., using a counter or timestamp-based approach)
- [ ] If autocannon CLI doesn't support dynamic bodies, the scenario uses the Node.js programmatic API (like mixed-bench.js) to generate unique emails per request
- [ ] Running the POST benchmark produces 0 non-2xx responses (excluding expected 404s for non-existent users)
- [ ] Both apps receive identical request patterns
- [ ] Typecheck passes

### US-004: Fix Mixed Benchmark Scenario

**Description:** As a developer, I want the mixed workload benchmark to produce valid results with realistic throughput so that we can compare mixed-workload performance.

**Acceptance Criteria:**
- [ ] The mixed workload script (`mixed-bench.js`) generates unique emails for POST requests
- [ ] PUT and DELETE operations target valid user IDs (within the seeded 1-10000 range)
- [ ] Running the mixed benchmark produces throughput in the thousands of req/s range (not 7-46 req/s)
- [ ] Both apps receive identical request distribution (70% GET single, 10% GET list, 10% POST, 5% PUT, 5% DELETE)
- [ ] Non-2xx response rate is < 1% for both apps
- [ ] Typecheck passes

### US-005: Run Fair Standalone Benchmarks

**Description:** As a developer, I want to run the full benchmark suite against standalone Redis with both apps using multiplexed connections so that I get trustworthy, fair numbers.

**Acceptance Criteria:**
- [ ] Redis is running via Docker (standalone mode)
- [ ] SQLite database is freshly seeded with 10,000 users
- [ ] Haskell app is running with multiplexing enabled
- [ ] C# app is running with StackExchange.Redis (default multiplexing)
- [ ] All 4 scenarios run successfully: GET single, GET list, POST, Mixed
- [ ] All scenarios produce >95% 2xx responses
- [ ] Results saved to `benchmarks/results/standalone/`
- [ ] If throughput difference exceeds 3×, document investigation of what's different (connection count, SQLite access pattern, GC, etc.)
- [ ] Typecheck passes

### US-006: Produce Fair Comparison Document

**Description:** As a developer, I want a comparison document with actual benchmark data and thorough analysis explaining why the numbers differ, with extra scrutiny on large gaps.

**Acceptance Criteria:**
- [ ] Markdown document at `benchmarks/results/COMPARISON.md` (updated, not placeholder)
- [ ] Includes test setup: hardware info (CPU, RAM), Redis version, Docker config, app config, Haskell RTS flags, .NET runtime version
- [ ] Results tables for standalone showing requests/sec and latency p50/p95/p99 for all 4 scenarios
- [ ] Analysis section explaining WHY numbers differ — covering: multiplexing implementation differences, serialization, GHC RTS vs .NET CLR, GC behavior, HTTP framework (Scotty/Warp vs Kestrel), SQLite connection patterns
- [ ] If any scenario shows >3× difference: includes a "Fairness Audit" subsection checking that both apps are doing identical work (same SQL queries, same Redis commands, same serialization)
- [ ] Conclusions and recommendations for redis-client library improvements
- [ ] All data sourced from actual benchmark JSON files (no placeholders)
- [ ] Typecheck passes

## 4. Functional Requirements

- **FR-1:** The Haskell app MUST use the `Multiplexer` module for standalone Redis to achieve multiplexed command pipelining.
- **FR-2:** Both apps must use identical endpoint paths, request/response JSON shapes, SQL queries, and Redis cache patterns.
- **FR-3:** Cache key format must be identical: `user:{id}`.
- **FR-4:** Cache TTL must be identical: 60 seconds.
- **FR-5:** Both apps must use the same Redis instance.
- **FR-6:** Autocannon must hit both apps with the same concurrency, duration, and pipelining settings.
- **FR-7:** POST requests must generate unique email addresses to avoid constraint violations.
- **FR-8:** All benchmark scenarios must produce >95% success rate (2xx responses).
- **FR-9:** The comparison document must include analysis of WHY differences exist, not just raw numbers.
- **FR-10:** If a >3× throughput gap exists in any scenario, the document must include a fairness audit proving both apps do identical work.

## 5. Non-Goals (Out of Scope)

- **Not** optimizing the redis-client library itself (that's the cluster-performance-parity branch's job).
- **Not** testing TLS connections.
- **Not** testing against Azure Managed Redis — local Docker only.
- **Not** running cluster benchmarks (standalone only for this round — cluster can come later).
- **Not** implementing connection pooling for SQLite (both apps open/close per request — unfair equally).
- **Not** building a UI or dashboard for results.

## 6. Design Considerations

### Haskell Multiplexing Architecture

The standalone Haskell app should:
1. Create a `PlainTextClient` connection
2. Wrap it in a `Multiplexer` (from the cluster-performance-parity branch)
3. Use `submitCommand` to send pre-encoded RESP commands
4. This allows multiple Warp threads to submit Redis commands concurrently

```haskell
-- Before (serialized):
runRedis (StandaloneConn client) (redisGet cacheKey)
-- evalStateT → one command at a time

-- After (multiplexed):
submitCommand mux (encodeCommandBuilder ["GET", cacheKey])
-- concurrent pipelining via writer/reader threads
```

### POST Scenario Fix

Replace hardcoded email with counter-based unique emails:
```javascript
// Before:
body: '{"name":"Bench User","email":"bench_RAND@test.com","bio":"..."}'

// After: use autocannon's programmatic API with a counter
let counter = 0;
setupClient: (client) => { client.setBody(JSON.stringify({
  name: "Bench User",
  email: `bench_${Date.now()}_${counter++}@test.com`,
  bio: "created by benchmark"
})) }
```

### Fairness Checklist

Before running benchmarks, verify:
- [ ] Both apps use WAL mode for SQLite
- [ ] Both apps open/close SQLite connections per request (or both use a pool)
- [ ] Both apps use multiplexed Redis connections
- [ ] Both apps use JSON serialization for cache values
- [ ] Both apps run with optimized build flags (-O2 for Haskell, Release for C#)
- [ ] Both apps use all available CPU cores (-N for GHC RTS)
- [ ] Autocannon settings are identical for both targets

## 7. Technical Considerations

- **Branch dependency:** This work requires the `Multiplexer` and `MultiplexPool` modules from `ralph/cluster-performance-parity`. The benchmark branch must be rebased or merged on top of that branch.
- **Haskell `Multiplexer` API:** The Multiplexer works at the raw RESP level (`Builder.Builder` input, `RespData` output). The Haskell app will need to encode commands using `encodeCommandBuilder` and parse `RespData` responses directly, rather than using the `RedisCommands` monad.
- **Scotty/Warp threading:** Warp uses GHC green threads. With `-N` RTS flag, multiple capabilities run in parallel. The `Multiplexer` is thread-safe — multiple green threads can call `submitCommand` concurrently.
- **SQLite concurrency:** Both apps use `PRAGMA journal_mode=WAL` (or should). Under heavy concurrent writes, SQLite's file lock becomes a shared bottleneck — this is acceptable since it affects both apps equally.
- **Warm-up:** The first few seconds of each autocannon run serve as warm-up (JIT compilation for .NET, GHC RTS initialization). Use at least 30-second run duration to amortize startup costs.

## 8. Success Metrics

- All 4 benchmark scenarios produce >95% 2xx responses for both apps.
- The comparison document contains actual numbers (no "Fill in" placeholders).
- The comparison document includes ≥3 substantive explanations for observed performance differences.
- If any scenario shows >3× gap, the fairness audit section proves both apps do identical work or identifies the specific architectural reason.
- The benchmark is reproducible — running `run-standalone.sh` again produces similar numbers (within 15% variance).

## 9. Open Questions

- Should the Haskell app create a single `Multiplexer` or a pool of multiplexers (via `MultiplexPool`) for standalone mode? StackExchange.Redis uses 1-2 multiplexed connections by default.
- Should we add a warm-up phase (short autocannon run that's discarded) before the measured run?
- Should the Haskell app use `submitCommand` (blocking, allocates MVar per call) or `submitCommandPooled` (reuses response slots from a pool) for better throughput?
- Is there a meaningful difference between the Haskell app encoding commands via `encodeCommandBuilder` vs using the `RedisCommands` monad and then submitting the raw bytes?
