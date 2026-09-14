### 2026-09-14: Qualify pinned map and set forwarding
**By:** Tunnel
**What:** The public tunnel contract now limits byte preservation to complete opaque fallback RESP3 frames outside `RespData`; parsed RESP3-shaped maps and sets are explicitly documented as re-encoded with no ordering-preservation guarantee.
**Why:** Pinned response handling parses `%` and `~` frames through `Resp.parseRespData` and then serializes them after topology rewriting, which can canonicalize `Data.Map` and `Data.Set` ordering.
