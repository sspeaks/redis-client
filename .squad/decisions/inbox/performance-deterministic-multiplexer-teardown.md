### 2026-09-04: Synchronize teardown cancellation at transport-close start
**By:** Performance
**What:** The multiplexer teardown regression test blocks its test transport's close action and cancels the destroy caller only after that barrier is reached; it no longer infers teardown progress from `muxAlive`.
**Why:** `muxAlive` changes at admission closure, before the destroy owner has necessarily reached an interruptible teardown operation. The close barrier makes cancellation and resumed teardown deterministic while preserving assertions that active, pending, and queued slots fail exactly once.
