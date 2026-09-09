# Issue status policy

Issue lifecycle automation treats `status:ready`, `status:in-progress`, and
`status:needs-review` as active workflow statuses.

- Closing an issue removes every active workflow status. This applies whether
  the issue is closed directly or automatically when a linked pull request is
  merged.
- Reopening an issue with a `squad:<member>` owner removes stale active statuses
  and assigns `status:ready`.
- Reopening an issue without a member owner removes stale active statuses and
  ensures the `squad` triage-inbox label is present.
- Other labels, including ownership, priority, type, wave, retrospective, and
  `status:blocked`, are not changed by closed-issue reconciliation.

The `Issue status state` workflow exposes closed-issue reconciliation through
manual dispatch. Every dispatch runs and logs a dry-run first. Live application
also requires `apply_reconciliation` and an exact `owner/repository` value in
`confirm_repository`; normal close and reopen events only update their
triggering issue.
