### 2026-09-18: Preserve pool cancellation and classify multiplexer protocol failures
**By:** Parser
**What:** Dead-multiplexer replacement rethrows asynchronous exceptions before liveness checks or retries, and cluster execution maps multiplexer parse failures and EOF to the public protocol-error layer across keyed, redirected, and raw paths.
**Why:** Cancellation must never become an implicit reconnect, and RESP framing/stream termination must retain the same typed meaning in cluster clients that they already have in standalone clients.
