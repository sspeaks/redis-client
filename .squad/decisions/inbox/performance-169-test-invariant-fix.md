### 2026-09-15: Relax Multiplexer batch-packing test to the real safety invariant
**By:** Performance
**What:** Updated the writer-batch-limit test to assert that every recorded batch stays at or below the configured limit and that the total number of recorded commands matches the number submitted, instead of requiring one exact batch-size ordering.
**Why:** Under aggressive scheduling, the multiplexer can legally emit `[1,2,2]` instead of `[2,2,1]` without ever exceeding the configured cap or losing commands. The previous assertion encoded scheduler-dependent greedy packing that is not part of the production safety contract; keeping it would preserve a flaky failure mode without improving coverage of the real backpressure guarantee.
