### 2026-09-18: Compile public examples from their documentation source
**By:** Tester
**What:** `make test` extracts and compiles every Haskell fence in both READMEs and every Haddock code block in the stable facade, standalone lifecycle, and connector modules.
**Why:** Source-level extraction prevents documentation and mirrored test fixtures from drifting independently while covering standalone, cluster, bracket lifecycle, authentication, and timeout connector paths.
