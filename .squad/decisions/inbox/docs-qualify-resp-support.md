### 2026-09-14: Qualify advertised RESP support
**By:** Docs
**What:** Public package metadata, READMEs, Haddock, changelog, and CLI help now describe the exact RESP2-first `RespData` subset and separately identify pinned-tunnel opaque RESP3 forwarding.
**Why:** The parser/encoder supports simple strings, errors, integers, bulk strings (including null bulk strings), non-null arrays, and map/set aggregates; it does not provide general RESP3 scalar or session semantics.
