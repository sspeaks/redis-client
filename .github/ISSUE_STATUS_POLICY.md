# Issue status policy

Issue lifecycle automation treats `status:ready`, `status:in-progress`, and
`status:needs-review` as active workflow statuses.

- Closing an issue removes every active workflow status and `needs-triage`. This
  applies whether the issue is closed directly or automatically when a linked
  pull request is merged. Closed-issue reconciliation does the same.
- Reopening an issue removes stale active statuses and every other triage state
  (`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), and ensures
  `needs-triage` is present. A triage state added after the reopen event is kept
  instead, without adding `needs-triage`. An issue that is closed again before
  the job runs is left unchanged.
- Other labels, including priority, type, wave, retrospective, and
  `status:blocked`, are not changed by closed-issue reconciliation.

The `Issue status state` workflow exposes closed-issue reconciliation through
manual dispatch. Every dispatch runs and logs a dry-run first. Live application
also requires `apply_reconciliation` and an exact `owner/repository` value in
`confirm_repository`; normal close and reopen events only update their
triggering issue.
