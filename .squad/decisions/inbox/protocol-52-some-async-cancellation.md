### 2026-09-18: Classify aggregate close cancellation as SomeAsyncException
**By:** Protocol
**What:** Standalone aggregate multiplexer cleanup rethrows every `SomeAsyncException`, including `AsyncCancelled`, after attempting teardown of every multiplexer.
**Why:** `async` cancellation is not necessarily an `AsyncException`; swallowing `AsyncCancelled` could mark the aggregate client closed while one multiplexer remained resumably destroying.
