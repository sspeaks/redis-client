# Baseline Measurement and Profiling Analysis

**Date:** 2026-02-11
**Cluster:** Local Docker cluster (5 masters, ports 7000-7004, plaintext)
**Config:** duration=15s, connections=4, key-size=16, value-size=256

## Baseline Results (non-profiled)

| Workload | ops/sec | total_ops |
|----------|---------|-----------|
| SET      | 17,779  | 266,696   |
| GET      | 18,893  | 283,406   |
| MIXED    | 17,031  | 255,467   |

## Profiling Summary

Profiling was performed with `+RTS -p` for each workload (15-second runs).

### Top 3 Cost Centers (by time)

All three workloads show the same pattern. Numbers below are from the SET workload profile
(GET and MIXED are nearly identical):

| # | Cost Center | Module | %time | %alloc | Notes |
|---|-------------|--------|-------|--------|-------|
| 1 | `createMultiplexer` | Multiplexer | 35.7% | 18.0% | Inherited: 68.3% time, 60.4% alloc. This is the parent scope for `writerLoop` and `readerLoop` (forked within `createMultiplexer`). The writer/reader loops account for the majority of time: batching commands via `Builder.toLazyByteString`, sending bytes, receiving bytes, and RESP parsing. |
| 2 | Socket I/O (`throwSocketErrorWait{Read,Write}`) | Network.Socket.Internal | 20.8% | 0.3% | Combined read+write socket wait time. This is kernel-level I/O wait — largely irreducible for a network-bound workload, but could be reduced via better batching (fewer syscalls per op). |
| 3 | `submitCommand` | Multiplexer | 10.5% | 0.8% | Per-command overhead: allocates a fresh `IORef` + `MVar` for each `ResponseSlot`, enqueues to the command queue, then blocks on `takeMVar`. 265K entries for 265K ops means ~1 allocation pair per operation. |

### Inherited Cost Breakdown (SET workload)

The full call chain for the hot path:

```
benchWorker           (7.4% self, 93.1% inherited)
  └─ submitToNode     (0.7% self, 79.5% inherited)
       ├─ submitCommand   (10.5% self) — per-op IORef/MVar alloc + enqueue + wait
       └─ createMultiplexer (35.7% self, 68.3% inherited) — writer/reader loops
            ├─ writerLoop → send      (14.0% inherited for send)
            ├─ readerLoop → recv      (14.6% inherited for recv)
            └─ readerLoop → parseOneResp (RESP parsing)
```

### Allocation Hotspots

| Source | %alloc | Notes |
|--------|--------|-------|
| `recv` (socket receive buffer) | 34.1% | Each recv allocates a new ByteString — expected for network I/O |
| `createMultiplexer` (loops) | 18.0% | Writer loop Builder materialization, reader loop parsing |
| `parseClusterSlots` | 21.4% | One-time cluster topology parsing — not in hot path |
| `benchKey` / `benchValue` | 7.9% | Benchmark harness overhead — not library code |
| `encodeCommandBuilder` | 4.4% | RESP command serialization |

### Key Observations

1. **Writer loop batching works well**: `Builder.toLazyByteString` with `foldMap pcBuilder batch` batches
   multiple commands into a single send. The ~14% time in `send` is reasonable for the data volume.

2. **Per-command `submitCommand` overhead is significant at 10.5%**: Each command creates a new
   `IORef Nothing` and `newEmptyMVar` as a response slot. With 265K ops in 15s, that's ~17.7K
   allocations/sec of IORef+MVar pairs. Object pooling for `ResponseSlot` could reduce this.

3. **`createMultiplexer` dominates because it contains the reader/writer event loops**: The 35.7%
   "self" time is misleading — it's accumulated by the forked threads. The actual bottleneck is
   the combination of socket I/O, RESP parsing, and command queue management within these loops.

4. **`parseClusterSlots` is 21.4% of allocations but <2% of time**: This is one-time topology
   parsing at startup — not a hot-path concern.

5. **Socket I/O is ~25% of total time**: This is the floor for network-bound work. Reducing syscall
   count (via larger batches or vectored I/O) could help, but diminishing returns apply.

### Recommended Optimization Priorities

1. **Reduce `submitCommand` per-op overhead** (US-007): Pool `ResponseSlot` objects (IORef + MVar)
   instead of allocating fresh ones per command. This is the easiest win at 10.5% of time.

2. **Optimize writer loop batching** (US-005): Ensure `Builder.toLazyByteString` doesn't create
   intermediate strict copies. Consider using `sendMany` or vectored I/O to avoid materializing
   the full lazy ByteString.

3. **Optimize reader loop parsing** (US-006): The reader loop processes one response at a time
   (`pendingDequeue` → `parseOneResp` → fill slot → loop). If the recv buffer contains multiple
   complete responses, parsing them in a tighter loop without per-response `pendingDequeue` could
   reduce overhead.

4. **RESP serialization** (US-008): `encodeCommandBuilder` is only 3-4% of time — relatively low
   priority, but pre-computing fixed protocol prefixes for SET/GET could still help.
