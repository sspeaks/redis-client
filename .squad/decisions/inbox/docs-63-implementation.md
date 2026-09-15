### 2026-09-15: Package-scoped release metadata and tagging
**By:** Docs
**What:** Split the repository's release policy by package, corrected each package changelog to track its own Cabal version, added a release-metadata validation script plus CI gate, and changed CLI Docker publication to push immutable version and commit-SHA tags while reserving `latest` for explicit CLI release tags.
**Why:** The repo publishes an executable and a reusable library from one tree, so a single mutable `latest` image tag and drifting changelog headings made releases non-reproducible. Package-scoped tags and checks make every published artifact traceable back to the versioned source commit.
