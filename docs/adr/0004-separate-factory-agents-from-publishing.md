# Separate factory agents from publishing

The factory acts under the maintainer's GitHub identity, so GitHub cannot tell the maintainer's actions from the factory's. Agents therefore never hold a GitHub token: they run in a sandbox and emit a patch plus structured text, which non-agent jobs validate and publish with a restricted token. Human approval happens through GitHub Environments that the factory token cannot approve.

## Considered Options

- **A dedicated GitHub App:** gives the factory a separate identity, but the maintainer chose to use their own.
- **Giving agents the maintainer's token:** simpler, but every checkpoint would depend on the agent choosing to obey it.

## Consequences

- The maintainer's always-on ruleset bypass must be removed.
- Tag rules cannot distinguish the maintainer from the factory, so the publishing jobs themselves require approval.
- The factory cannot change workflows.
- Model usage draws on the maintainer's Claude subscription. The Claude Code documentation checked at the time neither prohibits nor addresses scheduled use, but describes limits in terms of "ordinary, individual usage".
