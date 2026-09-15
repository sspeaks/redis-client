### 2026-09-15: Scope bounded RTS settings to the 1GB fill accuracy E2E cases
**By:** Performance
**What:** Kept the branch's global `-threaded -rtsopts` defaults, and updated the standalone E2E cases that assert exact 1GB fill counts to invoke `redis-client` with `GHCRTS=-N2 -A16m -n4m -qb` plus `--pipeline 1024`.
**Why:** Those tests were the one place still implicitly depending on the old baked-in fill-friendly RTS behavior. Making the bounded profile explicit in the test harness preserves the PR's goal of removing blanket RTS tuning while keeping the CI-only 1GB fill validations stable on constrained runners.
