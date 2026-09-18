### 2026-09-18: Bound the Azure cluster preset by primary count
**By:** Lead
**What:** The Azure helper starts clustered fills with one process and one connection per primary, producing one worker per primary and remaining within the normal 32-worker limit through 32-primary topologies.
**Why:** A fixed two connections per primary fails client validation on supported 24-primary Enterprise deployments; the helper must not generate a default command that its own fill concurrency plan rejects.
