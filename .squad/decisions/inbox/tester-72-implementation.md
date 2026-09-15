### 2026-09-15: Fix Copilot setup workflow path filters
**By:** Tester
**What:** Updated `.github/workflows/copilot-setup-steps.yml` to watch the actual workflow file plus the Nix and bootstrap inputs that can break `nix-build`, and renamed the workflow/job text to clearly describe Copilot setup validation while fixing the bootstrap step typo.
**Why:** The previous filters pointed at a different workflow filename, so edits to the setup workflow did not trigger validation. Watching the concrete bootstrap inputs keeps this workflow focused on setup regressions without broadening it to every source change.
