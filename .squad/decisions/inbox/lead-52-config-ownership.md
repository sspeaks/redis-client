### 2026-09-18: Assign each client configuration policy one owner
**By:** Lead
**What:** Standalone and cluster multiplexer counts are implemented as validated client-level settings; retry policy remains only in `ClusterConfig`; `PoolConfig` owns only per-node capacity and setup timeout; TLS is selected by connector choice.
**Why:** Public settings must have observable behavior, and duplicated or connector-independent policy knobs allow accepted configurations to be silently ignored or misinterpreted.
