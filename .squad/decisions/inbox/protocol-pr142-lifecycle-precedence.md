### 2026-09-05: Preserve primary worker failures while exposing cleanup failures
**By:** Protocol
**What:** Cluster fill workers own direct transports with `bracket`; a body failure remains primary, same-resource close failure follows `bracket` precedence, and non-cancellation sibling cleanup failures are retained in `ConcurrentFailure`. Fill parents wait for all child exits and propagate the first non-zero exit by child index.
**Why:** This keeps resource ownership exact without hiding close failures, while retaining the failure that caused sibling cancellation as the actionable root cause.
