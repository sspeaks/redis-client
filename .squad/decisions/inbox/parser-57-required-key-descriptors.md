### 2026-09-18: Route empty required-key descriptors through generated metadata
**By:** Parser
**What:** Shared command descriptors retain explicit-key routing for valid required-key lists, but empty required-key lists use metadata routing so generated Redis arity validation rejects them before cluster master selection.
**Why:** This preserves centralized frame construction and fast valid routing while preventing invalid UNLINK, PFCOUNT, SDIFF, SINTER, and SUNION calls from being misclassified as keyless commands.
