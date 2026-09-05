### 2026-09-04: Generate cluster routing from immutable Redis 7.2 metadata
**By:** Docs
**What:** Replaced hand-maintained cluster command routing with a generated Redis 7.2.6 command-form artifact and added semantic audit tooling that fails on drift or deliberate mutation.
**Why:** This keeps proxy routing and grammar validation aligned with authoritative upstream command metadata while preserving deterministic regeneration and reviewable contributor workflow.
