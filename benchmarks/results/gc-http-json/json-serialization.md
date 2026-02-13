# US-004: JSON Serialization Overhead Analysis

## Summary

Measured the overhead of Aeson's JSON encoding vs a hand-optimized ByteString Builder encoder
for the User type. Tested both cache-hit (JSON bypassed) and cache-miss (JSON on hot path) scenarios.

**Key finding**: JSON serialization contributes a small but measurable overhead (~5%) only in
cache-miss scenarios. In the normal cache-hit path, JSON encoding is completely bypassed —
cached bytes from Redis are returned directly.

## Methodology

- **Aeson variant**: Uses `Data.Aeson.encode` which builds an intermediate `Value` tree, then serializes
- **Builder variant**: Uses `Data.ByteString.Builder` directly — no intermediate `Value`, no Aeson dependency
- Both produce byte-identical JSON output (verified)
- Both use raw Warp (no Scotty) to isolate JSON impact from HTTP framework
- RTS flags: `-H1024M -A128m -n8m -qb -N` (best from US-002)
- Cluster mode, 100 connections, 10 pipelining, 30s duration

### Cache-Hit Scenario
Single user ID, warmed cache (10s), all requests served from Redis cache.
JSON encoding is **never invoked** — raw bytes from Redis are returned directly.

### Cache-Miss Scenario
Single user ID with continuous Redis FLUSHALL every 500ms, forcing most requests through the
full path: SQLite query → JSON encoding → Redis PSETEX → HTTP response.

## Results

### Cache-Hit (JSON Encoding Bypassed)

| Variant  | Req/s      | p50  | p97.5 | p99  | p99.9 |
|----------|------------|------|-------|------|-------|
| Aeson    | 106,291    | 9ms  | 12ms  | 13ms | 26ms  |
| Builder  | 106,522    | 9ms  | 12ms  | 13ms | 24ms  |
| **Diff** | **+0.2%**  | —    | —     | —    | -2ms  |

As expected, no meaningful difference when JSON encoding is bypassed.

### Cache-Miss (JSON Encoding on Hot Path)

| Variant  | Req/s      | p50  | p97.5 | p99  | p99.9 |
|----------|------------|------|-------|------|-------|
| Aeson    | 96,806     | 9ms  | 18ms  | 23ms | 38ms  |
| Builder  | 101,621    | 9ms  | 15ms  | 21ms | 30ms  |
| **Diff** | **+5.0%**  | —    | -3ms  | -2ms | -8ms  |

The manual Builder encoder shows a ~5% throughput improvement and significantly better
tail latency (8ms less at p99.9) in the cache-miss scenario.

## Analysis

### Why Cache-Hit Bypasses JSON Entirely

In the GET /users/:id handler, when Redis returns a cache hit (`RespBulkString val`), the raw
bytes are returned directly as the HTTP response body:

```haskell
Right (RespBulkString val) ->
  respond $ responseLBS status200 jsonContentType (LBS.fromStrict val)
```

No JSON encoding occurs. The bytes stored in Redis are the previously-encoded JSON from the
initial cache-miss. This means JSON encoding performance only affects the cache-miss path.

### Where Aeson's Overhead Comes From

Aeson's `encode` function:
1. Constructs an intermediate `Value` (HashMap-based JSON AST) via `toJSON`
2. Converts the `Value` to a `Builder` via internal encoding
3. Materializes the `Builder` to `ByteString`

The manual Builder skips step 1 entirely, going directly from Haskell data to `Builder`.
For a small type like `User` (5 fields), this intermediate allocation is modest but measurable
under high concurrency.

### Impact on .NET Gap

- **Cache-hit scenario** (normal operation): JSON encoding has **zero** impact on the .NET gap
  since both variants perform identically
- **Cache-miss scenario**: The 5% Builder advantage narrows the gap slightly, but cache misses
  are transient (only on first access or after cache expiry)
- **Practical impact**: Negligible — the benchmark's steady state is cache-hit, where JSON
  encoding is not invoked

## Conclusion

Aeson's JSON encoding adds ~5% overhead vs hand-optimized Builder encoding, but only on the
cache-miss path. Since the GET single benchmark reaches steady-state cache-hit within seconds,
JSON serialization does **not** meaningfully contribute to the 1.58× throughput gap vs .NET.

The .NET gap is primarily attributable to GC behavior (proven in US-002, closing gap to 1.33×),
not JSON serialization.
