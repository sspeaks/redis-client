### 2026-09-05: Resolve terminal repeated grammar by complete-frame progression
**By:** Parser
**What:** Terminal repeated arguments advance only active, bounded parse states and retain completed states; they no longer accumulate every prefix. General repeated parsing also retains at most 4,096 ordered states incrementally.
**Why:** A complete frame can use only a terminal state, so retaining prefixes creates quadratic list allocation without adding valid parses. This preserves generated metadata semantics while accepting up to the 65,536-frame-argument cap for deterministic repeated scalar forms.
