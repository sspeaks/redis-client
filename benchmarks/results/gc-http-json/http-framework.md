# HTTP Framework Overhead: Scotty vs Raw Warp

**Date:** 2026-02-13  
**Test:** GET single user (`/users/:id`) in cluster mode  
**RTS flags:** `-H1024M -A128m -n8m -qb -N` (best from US-002)  
**Duration:** 30s per variant | Connections: 100 | Pipelining: 10  

## Hypothesis

Scotty's routing and middleware layer adds measurable overhead compared to raw Warp,
contributing to the remaining 1.33× gap vs .NET (after GC tuning in US-002).

## Approach

- **Scotty variant:** Existing `Main.hs` — full Scotty framework with routing, WAI middleware, `ActionM` monad
- **Warp-only variant:** New `WarpOnly.hs` — raw `Warp.Application` type, manual path parsing, direct `responseLBS`

Both variants implement identical cache-aside logic:
1. Check Redis cache → return cached JSON on hit
2. Fall back to SQLite → serialize with Aeson → populate cache → return JSON

The Warp-only variant eliminates:
- Scotty's routing dispatch
- `ActionM` monad transformer overhead
- Scotty's WAI middleware chain
- `captureParam` / `queryParamMaybe` parsing

## Results

| Variant    | Req/s      | p50 (ms) | p97.5 (ms) | p99 (ms) | p99.9 (ms) |
|------------|------------|----------|------------|----------|------------|
| Scotty     | 102,931    | 9        | 13         | 16       | 28         |
| Warp-only  | 104,403    | 9        | 12         | 14       | 26         |
| **Δ**      | **+1.4%**  | **0**    | **−1**     | **−2**   | **−2**     |

## Analysis

**Scotty adds ~1.4% overhead** compared to raw Warp on the GET single endpoint.

This is a negligible contribution to the throughput gap:
- The gap vs .NET is currently 1.33× (~34,000 req/s difference after GC tuning)
- Scotty's overhead accounts for ~1,472 req/s — about **4.3% of the remaining gap**
- At p50, there is no measurable latency difference
- At p99/p99.9, Warp-only shows ~2ms improvement (14 vs 16ms, 26 vs 28ms)

### Why Scotty overhead is small

Scotty is a thin wrapper around Warp/WAI. Its main cost is:
1. **Route matching** — simple prefix-based dispatch, O(n) where n = number of routes
2. **ActionM monad** — `ReaderT` over `IO`, minimal overhead per request
3. **Middleware chain** — very short in this benchmark (no logging, no CORS, etc.)

The dominant costs in the request pipeline are:
- Redis cluster command routing and network I/O
- SQLite query execution (on cache miss)
- Aeson JSON serialization (on cache miss)

Scotty's routing is dwarfed by these I/O-bound operations.

## Conclusion

**Scotty is NOT a significant contributor to the .NET gap.** The HTTP framework
accounts for only ~1.4% throughput overhead and ~2ms at p99 tail latency.
Replacing Scotty with raw Warp would not be worth the loss in developer ergonomics.

The remaining gap must be explained by other factors (JSON serialization, Redis
client overhead, runtime differences).
