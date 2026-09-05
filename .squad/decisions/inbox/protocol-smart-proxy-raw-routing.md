### 2026-09-05T09:05:48-07:00: Smart proxy routes validated frames through the raw executor
**By:** Protocol
**What:** The smart proxy validates bulk-string command frames with the metadata grammar, then passes the original `RespData` and either its extracted routing key or keyless route to `RawCommand`. The `cluster` sublibrary is public solely so the executable can consume this existing internal protocol-adapter API; root and client facades remain unchanged.
**Why:** Reconstructing command arguments would alter frames and bypass the raw executor's proven retry/redirect semantics. The grammar rejects malformed, dynamic, unknown, and cross-slot inputs before the raw executor can acquire a connection.
