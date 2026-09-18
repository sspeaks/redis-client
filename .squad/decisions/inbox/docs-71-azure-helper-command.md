### 2026-09-18: Canonicalize the Azure helper command
**By:** Docs
**What:** Nix and flake installs provide `azure-redis-connect` as the canonical helper command and retain `redis-connect` as a compatibility alias. Cabal documentation uses the explicit source-tree form `python3 scripts/azure-redis-connect.py` because Cabal installs only the Haskell executable.
**Why:** `azure-redis-connect` was already the public documented name, while the Nix package installed only `redis-connect` and source examples referenced a nonexistent root-level script.
