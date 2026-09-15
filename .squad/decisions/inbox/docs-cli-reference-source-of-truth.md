# Docs decision: canonical CLI reference source of truth

- **Date:** 2026-09-15
- **Owner:** Docs
- **Decision:** The executable help text and the README CLI reference now render
  from the same `app/CommandHelp.hs` metadata.
- **Why:** Issue #82 was caused by the README and `app/Main.hs` drifting
  independently. Shared metadata keeps mode names, defaults, ranges, and
  applicability aligned, while `CliHelpParitySpec` makes drift fail in CI.
- **Follow-up:** When a public mode, option, default, or example changes, update
  `app/CommandHelp.hs` and refresh the generated README block in `README.md`.
