### 2026-09-18: Compile public examples as isolated consumers
**By:** Docs
**What:** Public examples compile in temporary Cabal components whose direct dependencies match the documentation: root README examples use `base` and `hask-redis-mux`, while library README and Haddock examples additionally use the documented `text` dependency. The documented library bound includes the repository's unreleased 0.2 release.
**Why:** Repository-wide `cabal exec` exposed transitive project dependencies, allowing examples with undeclared direct imports to pass, while the former `< 0.2` bound excluded the version whose examples the page documents.
