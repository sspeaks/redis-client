### 2026-09-15: Replace global RTS defaults with explicit fill profiles
**By:** Performance
**What:** Removed the shared high-memory `-with-rtsopts` defaults from executable and test stanzas, and standardized on explicit `fill-throughput` and `fill-bounded` wrapper profiles for workloads that actually need RTS tuning.
**Why:** CLI, tunnels, and tests inherit the shared stanzas but do not all benefit from `-N -H1024M -A128m -n8m -qb`. The fill path already has substantial application-level memory pressure from the 128 MiB noise buffer and the default 8192-command pipeline, so tuning is safer and easier to measure when it is opt-in and workload-specific.
