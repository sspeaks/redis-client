# US-006: HTTP and JSON Optimization Decisions

**Date:** 2026-02-13  
**Decision:** Neither HTTP framework nor JSON serialization optimizations are warranted.

## Decision Criteria

Per the acceptance criteria, optimizations should only be applied if they showed **>5%** improvement
in the relevant benchmark scenarios.

## HTTP Framework: Scotty vs Raw Warp (US-003)

| Metric        | Scotty    | Warp-only | Difference |
|---------------|-----------|-----------|------------|
| Throughput    | 102,931   | 104,403   | **+1.4%**  |
| p99 latency   | 16ms      | 14ms      | −2ms       |
| p99.9 latency | 28ms      | 26ms      | −2ms       |

**Decision: Do NOT replace Scotty with raw Warp.**

- The +1.4% throughput improvement is well below the 5% threshold
- Scotty is a thin WAI wrapper; its routing and `ActionM` monad add negligible overhead
- Replacing Scotty would sacrifice developer ergonomics (routing DSL, middleware composition)
  for an unmeasurable real-world gain
- The ~2ms tail latency improvement at p99/p99.9 is within run-to-run variance

## JSON Serialization: Aeson vs Manual Builder (US-004)

| Scenario   | Aeson     | Builder   | Difference |
|------------|-----------|-----------|------------|
| Cache-hit  | 106,291   | 106,522   | **+0.2%**  |
| Cache-miss | 96,806    | 101,621   | **+5.0%**  |

**Decision: Do NOT replace Aeson with manual Builder encoding.**

- **Cache-hit (steady state):** +0.2% — no meaningful difference. In normal operation,
  Redis returns cached bytes directly; JSON encoding is never invoked.
- **Cache-miss:** +5.0% — at the threshold but not exceeding it (criteria is >5%).
  Cache misses are transient (only on first access or cache expiry).
- The manual Builder encoder adds maintenance burden (must be kept in sync with the
  User type manually) for a benefit that only manifests on a transient code path.
- Aeson provides type-safe, auto-derived encoding that stays in sync with data types.

## Summary

| Factor           | Improvement | Threshold | Applied? |
|------------------|-------------|-----------|----------|
| HTTP (Scotty→Warp) | +1.4%     | >5%       | ❌ No    |
| JSON (Aeson→Builder) | +0.2% (hit) / +5.0% (miss) | >5% | ❌ No |

The remaining throughput gap vs .NET (1.31× after GC tuning) is not attributable to
HTTP framework or JSON serialization overhead. The gap likely stems from fundamental
runtime differences (GHC vs CoreCLR), Redis client implementation differences, and
async I/O model differences.

## Impact on Gap

The .NET gap remains at **1.31×** on GET single after GC optimization (US-005).
Neither HTTP nor JSON optimization would meaningfully close this further:
- Scotty→Warp would save ~1,472 req/s (1.4% of 105,901) → gap becomes ~1.30×
- Aeson→Builder saves nothing in steady-state (cache-hit path bypasses JSON entirely)
