### 2026-09-18: Make the helper package the default Nix derivation
**By:** Lead
**What:** `default.nix` returns `fullPackageWithScripts` as its derivation while attaching the existing package set as selectable attributes, so plain `nix-build` and flake installs expose the same canonical package without removing auxiliary `-A` targets.
**Why:** Returning the package attrset caused unqualified `nix-build` to build multiple outputs and leave `result` pointing at an unrelated artifact, contradicting the documented helper workflow.
