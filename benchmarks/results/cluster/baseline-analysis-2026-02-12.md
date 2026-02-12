# Cluster Baseline Profile Analysis
**Date:** 2026-02-12
**Operation:** GET single (cluster mode)
**Config:** 16 connections, 4 mux per node, 512B keys/values, 5 master nodes

## Throughput
| Metric | Value |
|--------|-------|
| Non-profiled ops/sec | 34,671 |
| Profiled ops/sec | 33,811 |
| .NET comparison (REST) | 121,726 req/s |
| Gap ratio | 3.51x |

## Top Cost Centers (by time%)

| Rank | Cost Center | Module | Time% | Alloc% |
|------|-------------|--------|-------|--------|
| 1 | createMultiplexer | Multiplexer | 40.3% | 24.8% |
| 2 | submitToNodeAsync | MultiplexPool | 33.8% | 1.6% |
| 3 | throwSocketErrorWaitWrite | Network.Socket.Internal | 8.3% | 0.2% |
| 4 | MAIN | MAIN | 3.3% | 2.2% |
| 5 | throwSocketErrorWaitRead | Network.Socket.Internal | 1.9% | 0.1% |
| 6 | submitCommandPooled | Multiplexer | 1.8% | 0.5% |
| 7 | throwSocketErrorIfMinus1RetryMayBlock | Network.Socket.Internal | 1.5% | 1.6% |
| 8 | crc16 | Crc16 | 1.3% | 2.1% |
| 9 | benchKey | Main | 1.2% | 8.0% |

## Top Allocators (by alloc%)

| Rank | Cost Center | Module | Alloc% | Alloc Bytes (est) |
|------|-------------|--------|--------|-------------------|
| 1 | recv | Network.Socket.ByteString.IO | 33.5% | ~4.26 GB |
| 2 | createMultiplexer | Multiplexer | 24.8% | ~3.16 GB |
| 3 | parseClusterSlots | Cluster | 16.9% | ~2.15 GB |
| 4 | benchKey | Main | 8.0% | ~1.02 GB |
| 5 | crc16 | Crc16 | 2.1% | ~267 MB |

## Total
- Total time: 21.12 secs (59561 ticks @ 1000us, 20 processors)
- Total alloc: 12,727,533,776 bytes

## Analysis

### Key bottlenecks:
1. **createMultiplexer (40.3% time)** - The multiplexer writer/reader loops are attributed here. This includes MVar blocking, MPSC queue draining, Builder materialization, and socket send. Optimizing the writer's batching and the reader's parse loop would directly impact this.

2. **submitToNodeAsync (33.8% time)** - Node selection in the MultiplexPool. This includes IORef reads for the node map and round-robin counter. Despite being lock-free, the sheer call volume (338k+ ops) makes this significant.

3. **Socket I/O (10.2% time combined)** - throwSocketErrorWaitWrite (8.3%) + throwSocketErrorWaitRead (1.9%). These are unavoidable network I/O costs but could be reduced with vectored I/O (sendMany) to reduce syscall count.

4. **recv allocation (33.5% alloc)** - The recv buffer allocations dominate memory. This is expected for network I/O but could be reduced with buffer reuse.

5. **parseClusterSlots (16.9% alloc)** - Cluster topology parsing allocates heavily, but this is not on the hot path (called once during setup and on refresh).
