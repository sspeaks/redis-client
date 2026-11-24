# Software factory policy

**Status: agreed, not yet implemented.** This document defines the target behavior. Items under [Launch checks](#launch-checks) must pass before `FACTORY_ENABLED` is set. Implementation is tracked in [#181](https://github.com/sspeaks/redis-client/issues/181).

## Purpose

Keep this repository an actively maintained Haskell Redis library with a good API and strong performance. A day with no changes is a success. Every self-filed ticket needs evidence: a reproducible bug, a measured regression, a failing check, or a specific maintenance cost.

## Triggers and limits

| Trigger | Action |
| --- | --- |
| Daily, 02:00 Pacific | Audit, then work tickets |
| Weekly | Retro and digest |
| Revert or repeated failure | Immediate retro |

- One implementation at a time. At most 3 new tickets a day, 3 open factory PRs, and 5 merges a day.
- No audit while 10 or more eligible tickets are open. Audits rotate through API, performance, correctness, tests, and docs.
- Order: maintainer tickets, then priority, then age.
- At most 12 agent runs a day, 100 turns and 60 minutes each. The first usage-limit error stops work until the next day.
- Usage credits stay off. `ANTHROPIC_API_KEY` must not be set in factory jobs.

## Intake

- Tickets from the maintainer or the factory are eligible automatically. Outside issues, comments, and PRs are ignored until admitted.
- The maintainer admits an outside ticket with `factory-approved`. It counts only when the event shows the maintainer applied it; publishing jobs refuse to set it. It freezes the title, body, and comments at that moment, and a later author edit revokes it. The ticket is rewritten as a clean brief before work starts.
- The factory may set `ready-for-agent` on its own tickets for bug fixes with a reproduction, tests, docs, behavior-preserving refactors, backward-compatible API additions, and small features.
- Work in a human-reviewed class below, or that contradicts an ADR, goes to `ready-for-human`.
- Retros may propose changes to factory instructions or gates. Those always go to `ready-for-human`.

## Merge policy

A script decides from changed paths and an API diff. Mixed or unrecognized changes take the strictest class.

| Class | Evidence | Merge |
| --- | --- | --- |
| Tests, docs, internal code | Green CI, one independent review | Automatic |
| Backward-compatible API, protocol, cluster, lockfiles | Above, plus full E2E, API diff, and a second review that tries to break the change | Automatic |
| Breaking API; authentication, TLS, credentials; new dependencies; factory controls; releases | Same as the row above | Maintainer |

Factory controls are workflows, scripts, the Makefile, hooks, agent instructions, this policy, and ADRs.

All automatic classes are enabled at launch. There is no staged rollout.

### Review

Reviewers are fresh agents that see the ticket, diff, and repository, never the implementer's reasoning. They check both standards and spec. After two fix rounds the ticket moves to `ready-for-human`.

### Performance

Performance claims and regression checks run base and head interleaved on one runner, five times each. A throughput, p99, or allocation regression over 10% that repeats on a second run blocks the merge. A ticket claiming a gain must show it the same way.

## Human checkpoints

Merges in the maintainer class, resuming after a pause, and publishing a release each wait on a GitHub Environment with the maintainer as required reviewer and admin bypass disabled. Unanswered approvals are repeated weekly and never approved by default.

## Sandbox and publishing

- Agents run on ephemeral GitHub-hosted runners, in a container with no GitHub token and no host Docker socket.
- A proxy outside the container holds the Claude subscription token. If this cannot work, launch stops and returns to the maintainer; the token is not exposed instead.
- Network access is limited to the model proxy, package mirrors, the Nix cache, and read-only GitHub content.
- Docker E2E runs only in separate jobs without secrets.
- Agents output one patch and structured issue or PR text. The publisher rejects symlinks, binaries, workflow changes, secret-like strings, and more than 800 changed lines excluding generated files. Oversized work is split.
- Publishing uses a fine-grained token for this repository only, without Administration, Workflows, or Deployments permission.

## Failure and stopping

- **Red `main` after a merge:** rerun once. If still red, open a revert PR, which merges on green CI only if it exactly inverts a factory merge. Then pause.
- **Pause** also on 2 reverts in 7 days or 3 consecutive ticket failures. A `factory-paused` issue blocks work, and only an environment approval resumes it.
- **Kill switch:** the `FACTORY_ENABLED` repository variable, off by default and set only by the maintainer, is checked before every job and again immediately before every publish or merge.
- **Invented work:** the weekly retro reports self-filed tickets closed unmerged, reverted, or re-fixed within 30 days. Above 25%, with at least 8 tickets, audits stop and only maintainer tickets are worked until the maintainer re-enables them.
- Rejected ideas are recorded in `.out-of-scope/` through a normal PR.

## Notifications

One updated issue holds the weekly digest: merged PRs, reverts, open decisions, and usage. Immediate notices are only for approvals, pauses, and usage limits.

## Releases

At most one proposal per package every 14 days, when all of these hold:

- there are unreleased user-visible changes and `main` is green;
- no open `priority:p0` or `priority:p1` correctness or security bug;
- the API diff matches the PVP version bump;
- benchmarks pass against the last release, or the first recorded baseline if there is none.

The maintainer approves the release PR, then approves publishing. Hackage upload stays manual. See [the release process](release-process.md).

## Launch checks

These verify the boundary itself; they are not a rollout stage.

- [ ] The factory token cannot approve an environment, change workflows, or bypass the ruleset.
- [ ] The always-on admin ruleset bypass is removed.
- [ ] Publishing jobs require approval, so a pushed tag alone publishes nothing.
- [ ] How long an approval can wait is known, and expiry leaves the change unmerged.
- [ ] The proxy works with the subscription token, which is unreachable from the agent container.
- [ ] Usage credits are off.
- [ ] The kill switch and pause stop an in-flight publish.
- [ ] Squad labels, the specialist reviewers row, and `status:*` automation are retired.
