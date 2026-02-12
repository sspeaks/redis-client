# PRD: Cluster Mode Performance Optimization

## 1. Introduction/Overview

The Haskell `redis-client` library's cluster mode (`ClusterClient` + `MultiplexPool`) suffers a **63% throughput drop** when moving from standalone to cluster Redis, compared to only 8% for .NET's StackExchange.Redis. In the REST benchmark's GET single user scenario (pure cache-hit path), Haskell achieves 35,202 req/s in cluster mode vs 95,625 in standalone — a 3.46× gap compared to .NET's 121,726 cluster req/s.

The goal is to iteratively optimize the cluster hot path — reducing per-command overhead in routing, slot lookup, and multiplexer pool access — then validate each change against the REST benchmark running on a Docker cluster.

## 2. Goals

- Reduce the cluster GET single throughput gap (currently 3.46× vs .NET) as much as possible
- Minimize per-command overhead in the cluster routing path (slot calculation, topology lookup, node selection)
- Keep benchmark methodology fair between Haskell and .NET implementations
- Maintain correctness: unit tests and cluster e2e tests must pass after each change
- Profile before/after each change to quantify improvement and catch regressions

## 3. User Stories

### US-001: Profile Baseline Cluster Performance

**Description:** As a developer, I want to capture a profiling baseline of the current cluster GET single path so that I can measure the impact of each subsequent optimization.

**Acceptance Criteria:**
- [ ] Run REST cluster benchmark (GET single scenario) and record baseline req/s and latency
- [ ] Run `+RTS -p` profiling on the benchmark harness to capture cost center breakdown
- [ ] Save baseline results to `benchmarks/results/cluster/` with a timestamped filename
- [ ] Document the top 5 cost centers by time% in the cluster hot path
- [ ] Typecheck passes

### US-002: Optimize Cluster Slot Lookup

**Description:** As a developer, I want to reduce the per-command overhead of slot calculation and topology lookup so that cluster routing adds minimal latency per command.

**Acceptance Criteria:**
- [ ] Topology read (`readTVarIO clusterTopology`) is verified as lock-free and zero-allocation on the hot path
- [ ] CRC16 slot calculation (`calculateSlot`) is benchmarked; if >1µs per call, optimize with unboxed/strict implementation
- [ ] Slot-to-node mapping uses O(1) vector indexing (no Map lookups on hot path)
- [ ] Profile shows reduced time% in slot lookup vs baseline
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-003: Reduce Per-Command Allocation in submitCommand

**Description:** As a developer, I want to reduce allocations in the `submitCommand` path so that each Redis command doesn't require fresh `IORef` + `MVar` allocation.

**Acceptance Criteria:**
- [ ] `submitCommandPooled` (using `SlotPool`) is the default path for cluster commands
- [ ] Profile shows reduced alloc% in `submitCommand` vs baseline
- [ ] No functional change to command semantics (responses still correctly matched)
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-004: Optimize MultiplexPool Node Selection

**Description:** As a developer, I want the `MultiplexPool` node selection to be as fast as possible so that picking the right multiplexer for a slot adds near-zero overhead.

**Acceptance Criteria:**
- [ ] `getMultiplexer` hot path (node already exists) avoids MVar contention — uses lock-free read
- [ ] Round-robin counter uses `atomicModifyIORef'` or `fetchAddInt` for minimal overhead
- [ ] Profile shows reduced time% in `submitToNode` / `getMultiplexer` vs baseline
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-005: Optimize Writer Loop Batching

**Description:** As a developer, I want the multiplexer writer loop to minimize syscalls and intermediate allocations when sending batched commands.

**Acceptance Criteria:**
- [ ] Writer loop uses `sendMany` or vectored I/O instead of materializing full lazy ByteString
- [ ] `Builder.toLazyByteString` intermediate copies are eliminated or reduced
- [ ] Profile shows reduced time% in writer loop / send path vs baseline
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-006: Optimize Reader Loop Parsing

**Description:** As a developer, I want the multiplexer reader loop to parse multiple responses from a single recv buffer in a tight loop, reducing per-response overhead.

**Acceptance Criteria:**
- [ ] When recv buffer contains multiple complete RESP responses, they are parsed in a tight inner loop without per-response queue operations
- [ ] Batch slot dequeue is used (existing `pendingDequeue` up to 64)
- [ ] Profile shows reduced time% in reader loop / recv path vs baseline
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-007: Reduce Redirection Detection Overhead

**Description:** As a developer, I want MOVED/ASK redirection detection to be as cheap as possible in the common case (no redirect).

**Acceptance Criteria:**
- [ ] Common case (no redirect) is a single byte check (e.g., check first byte is not `-`) rather than full pattern match
- [ ] No allocation in the no-redirect path
- [ ] MOVED/ASK redirects still handled correctly when they occur
- [ ] Unit tests pass
- [ ] Cluster e2e tests pass
- [ ] Typecheck passes

### US-008: Run Final Benchmark Comparison

**Description:** As a developer, I want to run the full REST cluster benchmark suite after all optimizations to measure the total improvement.

**Acceptance Criteria:**
- [ ] Run full REST cluster benchmark (all 4 scenarios: GET single, GET list, POST, Mixed)
- [ ] Compare results against baseline from US-001
- [ ] Document improvement in req/s and latency for each scenario
- [ ] Run .NET benchmark for comparison (same methodology)
- [ ] Save final results to `benchmarks/results/cluster/`
- [ ] Typecheck passes

## 4. Functional Requirements

- FR-1: All changes must be to the `redis-client` library code (under `lib/`) and/or the benchmark harness (under `benchmarks/`). No changes to the .NET benchmark app unless required for fairness.
- FR-2: Each optimization must be profiled with `+RTS -p` before and after to verify it reduces the targeted cost center.
- FR-3: Cluster slot routing must remain correct: commands must be sent to the correct node based on key hash slot, and MOVED/ASK redirects must be handled.
- FR-4: The multiplexer's command pipelining behavior must be preserved: concurrent commands from different threads must be batched into single TCP writes.
- FR-5: The `SlotPool` response slot pooling must correctly recycle slots without data races (slots must be fully reset before reuse).
- FR-6: Benchmark fairness must be maintained: both Haskell and .NET apps use multiplexed connections, identical SQLite pragmas, same cache-aside logic, same autocannon settings.
- FR-7: Unit tests (`cabal test`) and cluster e2e tests must pass after each change.

## 5. Non-Goals (Out of Scope)

- Optimizing standalone (non-cluster) Redis performance — already within 1.5× of .NET
- Optimizing SQLite access patterns (connection pooling, statement caching) — that's a separate concern
- Optimizing the Scotty/warp HTTP framework — out of scope for this library
- Optimizing JSON serialization (aeson) — out of scope for this library
- Achieving exact parity with .NET — some gap is expected due to runtime differences
- Changing the benchmark methodology (scenarios, duration, connection counts) — keep existing methodology
- Implementing Redis Cluster features like read replicas or multi-key commands

## 6. Design Considerations

### Code Areas to Modify
- `lib/cluster/Multiplexer.hs` — writer loop, reader loop, submitCommand
- `lib/cluster/MultiplexPool.hs` — node selection, round-robin
- `lib/cluster/ClusterCommandClient.hs` — slot calculation, topology lookup, redirection detection
- `lib/cluster/ClusterSlotMapping.hs` — slot-to-node mapping data structure

### Profiling Approach
- Use `cabal run --enable-profiling redis-client -- +RTS -p` for cost center profiling
- Compare `.prof` files between iterations
- Focus on time% reduction in: `submitCommand`, `submitToNode`, `getMultiplexer`, `writerLoop`, `readerLoop`

## 7. Technical Considerations

- **GHC RTS flags**: Current flags are `-N -H1024M -A128m -n8m -qb`. These may need tuning per iteration.
- **Lock-free data structures**: Use `IORef` with `atomicModifyIORef'` or `atomicWriteIORef` instead of `MVar` on hot paths.
- **Strictness**: Ensure strict evaluation on hot paths to avoid thunk accumulation (use `BangPatterns`, strict `IORef`).
- **Inline pragmas**: Critical hot-path functions should have `{-# INLINE #-}` or `{-# INLINABLE #-}` pragmas.
- **Docker cluster**: 5-node cluster on ports 7000–7004 with host networking. Must be running for cluster benchmarks and e2e tests.
- **Profiling overhead**: Profiling itself adds ~2-5× overhead. Compare profiled runs against other profiled runs, not against non-profiled baselines.

## 8. Success Metrics

- **Primary**: Cluster GET single req/s improvement (baseline: 35,202 req/s)
- **Secondary**: Reduced standalone-to-cluster throughput drop ratio (baseline: 63% drop)
- **Secondary**: Reduced p50/p99 latency in cluster GET single scenario
- **Guard rail**: No regression in standalone performance
- **Guard rail**: Unit tests and cluster e2e tests pass
- **Guard rail**: Profile shows no new cost center hotspots

## 9. Open Questions

- Should the `SlotPool` size (currently 256 slots, 16 stripes) be tuned for higher concurrency? The concurrency tuning data shows 16 threads × 1 mux is optimal (~51k ops/s).
- Is the topology refresh interval (10 minutes) too conservative? Could a shorter interval help in dynamic cluster environments?
- Would using `UnliftedArray` or `SmallArray` for the slot mapping vector provide measurable benefit over `Data.Vector`?
- Should we consider a per-thread topology cache (via `ThreadLocal` pattern) to avoid even the TVar read on every command?
