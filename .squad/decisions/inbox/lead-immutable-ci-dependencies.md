### 2026-09-14: Pin CI actions and Redis test images
**By:** Lead
**What:** GitHub Actions use immutable commit SHAs with version comments, external Compose and Redis CLI images use explicit tags plus multi-architecture digests, and Renovate is limited to reviewed digest proposals for these two dependency managers.
**Why:** This preserves reproducible CI and E2E inputs while allowing explicit, narrowly scoped maintenance updates.
