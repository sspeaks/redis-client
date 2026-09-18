### 2026-09-18: Reconcile public examples with effective client configuration
**By:** Tester
**What:** Public cluster examples now derive from `defaultClusterConfig` and update `defaultPoolConfig`, including explicit `clusterMultiplexerCount` only where the example demonstrates multi-mux behavior.
**Why:** Current main compile-tests these examples, while #52 removes inert `PoolConfig.maxRetries` and `PoolConfig.useTLS`; using validated defaults preserves the example gate and the intended configuration ownership.
