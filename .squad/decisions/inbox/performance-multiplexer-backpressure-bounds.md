### 2026-09-15: Multiplexer admission and writer-drain bounds
**By:** Performance
**What:** The multiplexer now enforces a 4,096-command admission ceiling across queued plus in-flight work and limits each writer drain to 512 commands.
**Why:** The overload benchmark cut peak stalled-server residency from 93.0 MiB to 60.0 MiB and capped peak outstanding commands at 4,096. A 512-command writer limit kept the synthetic slot-pool regression to low single-digit throughput loss while still preventing unbounded batch growth.
