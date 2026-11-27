# Run the agent loop as scheduled routines

Supersedes [0004](0004-separate-factory-agents-from-publishing.md) and [0005](0005-merge-factory-changes-by-risk.md).

The factory designed in 0004 and 0005 kept agents away from any GitHub token and decided merges from a classifier, which needed a sandbox, a publisher, intake filtering and merge-class code larger than much of the library itself. The maintainer chose a loop instead: two daily Claude Code routines driven by repository skills, working only the maintainer's own issues, with GitHub merging what the reviewer approves.

## Considered Options

- **The factory in 0004 and 0005:** strongest isolation and accepted outside work, at the cost of about 12,000 lines of factory code to maintain.
- **Routines with the maintainer merging every pull request:** simplest, but no unattended merges.

## Consequences

- Runs act as the maintainer's GitHub account. Protection comes from GitHub: a `main` ruleset with no bypass, required checks, the tag ruleset, and an auto-merge workflow that runs from `main` and refuses protected paths.
- Outside issues are not worked directly; the maintainer re-files ideas worth doing as their own issues.
- Selection, review and routing depend on the model following its skill.
