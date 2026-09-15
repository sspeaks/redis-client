### 2026-09-14: Cap response-slot retention at 256
**By:** Performance
**What:** A multiplexer pool now retains at most 256 idle response slots distributed across 16 capability stripes. Each slot returns to its acquisition stripe, including asynchronous cancellation reapers; excess burst slots are discarded after completion.
**Why:** The controlled 4,096-command burst retained exactly 256 slots, allocated 15,312,576 bytes, peaked at 8,388,608 bytes residency, and settled at 590,440 bytes live after GC. The 1,024-command cancellation burst also retained 256 slots and settled at 206,896 bytes. Preserving acquisition-stripe affinity avoids cross-capability cache displacement while enforcing finite post-burst retention.
