### 2026-09-15: Targeted admission wakeups for multiplexer backpressure
**By:** Performance
**What:** Replaced the bounded multiplexer's shared-STM admission `retry` gate with an `MVar`-protected FIFO waiter queue that grants capacity directly to only the waiters satisfied by each release.
**Why:** A single shared `TVar` woke every blocked submitter on each one-slot release under overload, creating a thundering herd. Direct wakeups preserve the admission bound and release accounting while removing that broadcast CPU cost.
