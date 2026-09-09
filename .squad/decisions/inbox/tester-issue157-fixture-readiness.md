### 2026-09-09: Refresh failover fixture topology until a usable pair is visible
**By:** Tester
**What:** The failover E2E test refreshes and snapshots cluster topology up to 50 times at 200ms intervals, choosing only a master whose advertised replica is present and has the replica role.
**Why:** `cluster_state:ok` can precede replica relationship visibility in the test client's initial `CLUSTER SLOTS` snapshot. This prevents an unrelated precondition failure before the MOVED/LPUSH assertion while preserving a bounded, diagnostic failure when convergence never occurs.
