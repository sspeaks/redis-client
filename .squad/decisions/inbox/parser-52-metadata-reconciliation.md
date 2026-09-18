### 2026-09-18: Preserve lifecycle semantics around descriptor-driven dispatch
**By:** Parser
**What:** Rebased PR #175 onto the command-metadata changes from PR #173, retaining descriptor-driven command construction and cluster metadata routing while preserving effective multiplexer counts, atomic standalone close, resumable aggregate cleanup, and asynchronous-exception propagation.
**Why:** Configuration and lifecycle behavior must remain independent of how command frames and routing metadata are constructed, and empty required-key commands must continue to fail locally before transport selection.
