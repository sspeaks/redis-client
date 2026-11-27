#!/usr/bin/env python3
"""Decide whether factory work may proceed right now.

Every factory job calls this gate first, and calls it again immediately before
each publish or merge. Nothing is cached: each call reads GitHub live. Any
missing input, failed lookup, redirect, or unexpected response refuses.

Shell:   python3 -I scripts/factory/gate.py KIND  exit 0 allowed, nonzero refused
Python:  gate.require(KIND)                       returns, or raises gate.Refused
         gate.check(KIND, repo, get, now=, run_id=) -> Decision(allowed, reason)
         get(path) -> (parsed JSON, next path or None)

Run it from a trusted checkout of main, never from a pull request's files, and
keep its token out of the agent container.

KIND            Checks
job             switch, pause, usage limit. Start of a job with no agent.
agent           same, plus the daily agent-run limit. Start of an agent job.
implementation  same as agent, plus no other implementation running.
publish         switch and pause (including failed pauses) only, so run limits do not strand finished
                work. Start of a publishing job, and before each write.
merge           same as publish. Before each merge or update from main.

Environment:
  GITHUB_REPOSITORY, GITHUB_RUN_ID   set by Actions
  FACTORY_GATE_TOKEN                 fine-grained token for this repository with
                                     Variables, Actions, Issues and Contents READ only.
                                     GITHUB_TOKEN cannot read variables, and the
                                     `vars` context is fixed when a job starts,
                                     so it cannot stop an in-flight publish.

Workflow conventions (GitHub's own job records are the ledger; there are no
counters for an agent or publisher to alter):
  * Agent jobs live in .github/workflows/factory-*.yml, and the job's display
    name starts with `factory-agent`. Implementation jobs start with
    `factory-agent-implementation`. Also set a `concurrency` group: without one,
    two implementations that start together refuse each other.
  * An agent job runs at most one agent, in a step named exactly
    `factory-agent-run`, after its gate step. If the gate refuses, that step is
    skipped and the job does not count.
  * On a usage-limit error the agent job runs a succeeding step named exactly
    `factory-usage-limit`, e.g. `if: always() && steps.agent.outputs.usage_limit
    == 'true'`. New work then stops until the next day.
  * A job that opens a pause issue is named exactly `factory-pause`, alone or
    after a caller prefix (`caller / factory-pause`). A step that records that a
    pause could not be made is named exactly `factory-pause-failed`. Both must
    fail their run: no `continue-on-error`. Do not name a job that calls a
    reusable workflow `factory-pause`; put its condition on the calling job.
  * No step that runs an agent or writes may survive a refused gate through
    `always()`, `failure()`, or `continue-on-error`.

Days are Pacific calendar days. FACTORY_ENABLED is on only as exactly `true`.

Pause: open an issue labeled `factory-paused`. Every application of that label
is a pause until cleared, even if the issue is then closed or unlabeled.
Resume: dispatch factory-resume.yml on main AFTER the pause; the maintainer
approves the `factory-resume` environment. The gate verifies that approval in
GitHub's records, that the run's commit is on main, and that no tag named `main`
exists, and also requires that no `factory-paused` issue is open. The label
itself must exist, or everything is refused.

Failed pause: since the last approved resume (or ever, if none), every kind is
refused if a factory-*.yml run holds a `factory-pause` job that is unfinished or
finished as anything but success, or a `factory-pause-failed` step that ran.
Re-running it does not clear it; only a resume does. Skipped jobs are told apart
by their records:
  * `caller / factory-pause` skipped: the pause was called, so it counts.
  * `factory-pause` skipped in a run of factory-pause.yml itself: it counts, as
    does such a run without that job.
  * `factory-pause` skipped in any other run: a normal condition, ignored. This
    cannot be told from a pause skipped because a job it needs failed, so a
    pause that must not be lost belongs in a called workflow.
Checked for jobs: runs that are unfinished, did not succeed, were re-run, ran
factory-pause.yml, or were updated today. At most 300 such runs since the
resume; beyond that, refused until the next resume. Runs created since the resume
must also have their predecessors, as below.

Outsiders: runs they can start are not checked for jobs and refuse nothing. These
are a fork's pull_request runs, and the exact workflow path and event pairs in
OUTSIDER_RUNS. test_workflow_rules.py requires every factory-*.yml trigger to be
one only a writer or GitHub can fire, or to be listed there, and a listed workflow
to match its reviewed text, which holds no agent, pause, secret or reusable
workflow. It also forbids other workflows from using or imitating factory ones.

Missing runs: a run number absent below a run created in the last 30 days (and
since the last resume; `job` and the agent kinds also always include today) is
refused if the nearest listed run below it is also under 30 days old, or none is
listed. GitHub documents purging runs that await approval after 30 days, and
other runs later, so a wider gap may be innocent and is ignored.

Residual risks. The gate trusts GitHub's records, and cannot detect someone with
write access editing them. Agents hold no GitHub token, so this is about
whoever holds a write token (the publisher, or the maintainer's own account).
Permission names are from GitHub's documentation and were not tested here.
  * Issues write: renaming the `factory-paused` label and creating a new one of
    the same name may hide an earlier pause, if GitHub reports past label events
    under the new name. Transferring a paused issue out of the repository (needs
    write there too) may remove its events. The publisher must expose neither.
  * Repository admin: deleting a paused issue may remove its events; changing
    FACTORY_ENABLED or the environment's protection defeats the gate by design.
  * Actions write: deleting a workflow's newest runs, every run of a workflow,
    an older run that was re-run since, or a run in a gap ignored above, lowers
    today's counts or hides a usage limit or failed pause. It cannot forge an
    approval. An innocent deletion refuses work until the next resume or until
    the runs around it are 30 days old.
  * A failed pause is forgotten when GitHub purges its run (documented as 400
    days), or 30 days after someone deletes it.
  * Failed pauses that leave no such record are missed: a run cancelled before
    its pause was called; a called workflow that never started, or whose first
    job failed if GitHub then records no skipped `factory-pause` job; a pause
    that began after the run list was read; and, after the day it happened, a
    skipped or `continue-on-error` pause in a run that succeeded first time.
    Whether GitHub lists jobs still waiting on `needs`, and how it names skipped
    called jobs, was not verified. If it lists them, a run with a bare
    `factory-pause` job refuses its own gate.
  * Truncated answers: lists of runs and jobs are checked against total_count,
    and a run list truncated along with its total is caught only as above; a job
    list truncated along with its total is not. Event and issue lists have no
    total: they are read until an empty page, and a short page before the last
    is refused, but an empty first page, or missing items at the end of the last
    non-empty page, cannot be told from a short history.
  * If every earlier run of a workflow has been purged, its next run above
    number 1 refuses everything until a newer resume, or for 30 days. Outsiders
    could cause this once per workflow, by a fork pull request that runs it
    before its first real run and is never approved.
  * Outsiders can still slow the gate, by adding workflow runs and issue events
    to the lists it reads; past 100,000 of either it refuses.
  * Workflows write: a pull_request_target run uses the base branch's file, so a
    branch whose copy of a listed workflow held an agent or pause would hide it.
  * Workflows write: renaming a workflow outside factory-*.yml, or its job or
    step names, drops it from the counts. Runs of removed files still count.
  * A write token that can push tags could create a tag named main, dispatch a
    resume there and delete the tag; the commit must still be on main and the
    maintainer must still approve.
  * No check is atomic with the write after it: a stop that lands between the
    last lookup and the write is missed, as is any delay in GitHub's records.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

# `python3 -I` leaves the script directory off the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from github_http import API, api_request, open_api  # noqa: E402

KINDS = ("job", "agent", "implementation", "publish", "merge")
MAX_AGENT_RUNS = 12
PAUSE_LABEL = "factory-paused"
RESUME_ENVIRONMENT = "factory-resume"
RESUME_WORKFLOW = "factory-resume.yml"
WORKFLOW_PREFIX = ".github/workflows/factory-"
PAUSE_PATH = ".github/workflows/factory-pause.yml"
PAUSE_JOB = "factory-pause"
PAUSE_FAILED_STEP = "factory-pause-failed"
MAX_PAUSE_LOOKUPS = 300
# Workflow path and event of runs outsiders can start. See Outsiders above.
OUTSIDER_RUNS = frozenset({(".github/workflows/factory-classify.yml", "pull_request_target")})
AGENT_JOB = "factory-agent"
IMPLEMENTATION_JOB = "factory-agent-implementation"
AGENT_STEP = "factory-agent-run"
USAGE_STEP = "factory-usage-limit"

MAX_PAGES = 1000
PAGE_SIZE = 100
# GitHub re-runs a workflow for 30 days after creation and stops a run at 35.
RUN_LOOKBACK = timedelta(days=66)
# The soonest GitHub documents purging a run, one that awaits approval.
RETENTION = timedelta(days=30)
_BEGINNING = datetime.min.replace(tzinfo=timezone.utc)


class Refused(Exception):
    """Work must not proceed; the message says why."""


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: str


def check(kind, repo, get, *, now, run_id):
    try:
        if kind not in KINDS:
            raise Refused(f"unknown check kind {kind!r}")
        _require_switch(repo, get)
        _require_no_open_pause(repo, get)
        resumed = _last_resume(repo, get)
        newest_event = _require_pauses_resumed(repo, get, resumed)
        today = _day_start(now)
        starts_work = kind in ("job", "agent", "implementation")
        oldest = min(resumed or _BEGINNING, today)
        runs = _factory_runs(repo, get, oldest, now)
        gaps_since = oldest if starts_work or not resumed else resumed
        _require_no_missing_run(repo, runs, gaps_since, now)
        trusted = [run for run in runs if not _from_outsider(repo, run)]
        jobs = _job_reader(repo, get)
        if starts_work:
            _require_within_limits(kind, trusted, jobs, today, run_id)
        _require_no_failed_pause(trusted, jobs, resumed or _BEGINNING, today)
        # The lookups above can take a minute; stops during them still count.
        _require_no_open_pause(repo, get)
        _require_pauses_resumed(repo, get, resumed, since=newest_event)
        _require_switch(repo, get)
    except Refused as error:
        return Decision(False, str(error))
    except Exception as error:  # Anything unexpected must refuse.
        return Decision(False, f"lookup failed ({type(error).__name__}: {error})")
    return Decision(True, f"{kind} allowed")


def require(kind):
    environment = {}
    for name in ("GITHUB_REPOSITORY", "FACTORY_GATE_TOKEN", "GITHUB_RUN_ID"):
        environment[name] = os.environ.get(name, "")
        if not environment[name]:
            raise Refused(f"{name} is not set")
    if not environment["GITHUB_RUN_ID"].isdecimal():
        raise Refused("GITHUB_RUN_ID is not a number")
    decision = check(
        kind,
        environment["GITHUB_REPOSITORY"],
        _github(environment["FACTORY_GATE_TOKEN"]),
        now=datetime.now(timezone.utc),
        run_id=int(environment["GITHUB_RUN_ID"]),
    )
    if not decision.allowed:
        raise Refused(decision.reason)


def _require_switch(repo, get):
    try:
        variable, _ = get(f"/repos/{repo}/actions/variables/FACTORY_ENABLED")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise Refused("FACTORY_ENABLED is unset") from error
        raise
    if variable["value"] != "true":
        raise Refused("FACTORY_ENABLED is off")


def pause_label_exists(repo, get):
    """Whether the pause label exists, in any case. Any failure but a 404 raises.

    The publisher shares this: opening a pause issue would create a missing label.
    """
    try:
        label, _ = get(f"/repos/{repo}/labels/{PAUSE_LABEL}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    return _is_pause(label)


def _require_no_open_pause(repo, get):
    if not pause_label_exists(repo, get):
        raise Refused(f"the {PAUSE_LABEL} label is missing, so a pause could be hidden")
    path = f"/repos/{repo}/issues?labels={PAUSE_LABEL}&state=open&per_page={PAGE_SIZE}"
    for issue in _items(get, path):
        raise Refused(f"paused by open {PAUSE_LABEL} issue #{issue['number']}")


def _is_pause(label):
    return label["name"].casefold() == PAUSE_LABEL


def _require_pauses_resumed(repo, get, resumed, since=None):
    """Return the newest event time. `since` skips events an earlier call read."""
    newest = since
    for page in _pages(get, f"/repos/{repo}/issues/events?per_page={PAGE_SIZE}"):
        times = []
        for event in page:
            at = _timestamp(event["created_at"])
            times.append(at)
            if (
                event["event"] == "labeled"
                and _is_pause(event["label"])
                and (resumed is None or at >= resumed)
            ):
                raise Refused(
                    f"pause at {event['created_at']} has not been resumed by a "
                    f"maintainer approval of {RESUME_ENVIRONMENT}"
                )
        newest = max([*times, *([newest] if newest else [])], default=None)
        # Events are newest first, so later pages are older still.
        if times and resumed and max(times) < resumed:
            break
        if times and since and min(times) < since:
            break
    return newest


def _last_resume(repo, get):
    """When the newest approved resume was requested. Later pauses stay in force."""
    maintainer = repo.split("/")[0]
    path = f"/repos/{repo}/actions/workflows/{RESUME_WORKFLOW}/runs?per_page={PAGE_SIZE}"
    for run in _items(get, path, "workflow_runs"):
        if (
            run["path"] != f".github/workflows/{RESUME_WORKFLOW}"
            or run["event"] != "workflow_dispatch"
            or run["head_branch"] != "main"
            or run["status"] != "completed"
            or run["conclusion"] != "success"
        ):
            continue
        # With no protection on the environment there is no approval record.
        approvals, _ = get(f"/repos/{repo}/actions/runs/{run['id']}/approvals")
        approved = any(
            approval["state"] == "approved"
            and approval["user"]["login"] == maintainer
            and any(e["name"] == RESUME_ENVIRONMENT for e in approval["environments"])
            for approval in approvals
        )
        if approved and _is_on_main(repo, get, run["head_sha"]):
            return _timestamp(run["created_at"])
    return None


def _is_on_main(repo, get, commit):
    # A run's head_branch is only a name, which a tag can share.
    # This endpoint is not paginated.
    tags, _ = get(f"/repos/{repo}/git/matching-refs/tags/main")
    if not isinstance(tags, list) or len(tags) >= PAGE_SIZE:
        raise ValueError("expected a short list of tags")
    if any(ref["ref"] == "refs/tags/main" for ref in tags):
        raise Refused("a tag named main exists, so a resume cannot be trusted")
    if not isinstance(commit, str) or not commit:
        raise ValueError("run has no head_sha")
    main, _ = get(f"/repos/{repo}/git/ref/heads/main")
    comparison, _ = get(f"/repos/{repo}/compare/{commit}...{main['object']['sha']}")
    return (
        comparison["status"] in ("ahead", "identical")
        and comparison["merge_base_commit"]["sha"] == commit
    )


def _require_no_failed_pause(runs, jobs, since, today):
    lookups = 0
    for run in runs:
        finished = run["status"] == "completed"
        updated = _timestamp(run["updated_at"])
        if finished and updated < since:
            continue
        itself = run["path"] == PAUSE_PATH
        succeeded = run["conclusion"] == "success" and run["run_attempt"] == 1
        if finished and succeeded and not itself and updated < today:
            continue
        lookups += 1
        if lookups > MAX_PAUSE_LOOKUPS:
            raise Refused(f"too many runs to check for a failed pause; run {RESUME_WORKFLOW}")
        found = False
        for job in jobs(run["id"]):
            prefix, _, name = job["name"].rpartition(" / ")
            if name == PAUSE_JOB:
                found = True
                ignorable = job["conclusion"] == "skipped" and not prefix and not itself
                if job["status"] != "completed":
                    raise Refused(f"a factory-pause job in run {run['id']} is unfinished")
                if job["conclusion"] != "success" and not ignorable:
                    if _timestamp(job["completed_at"]) >= since:
                        raise Refused(
                            f"a factory-pause job in run {run['id']} did not succeed "
                            "and has not been resumed"
                        )
            for step in job["steps"]:
                if step["name"] == PAUSE_FAILED_STEP and _step_ran(step):
                    if job["status"] != "completed" or _timestamp(job["completed_at"]) >= since:
                        raise Refused(
                            f"a {PAUSE_FAILED_STEP} step ran in run {run['id']} "
                            "and has not been resumed"
                        )
        if itself and not found:
            raise Refused(f"run {run['id']} has no factory-pause job")


def _step_ran(step):
    if step["conclusion"] is None:
        return step.get("status") not in ("queued", "pending")
    return step["conclusion"] != "skipped"


def _day_start(now):
    pacific = ZoneInfo("America/Los_Angeles")
    return datetime.combine(now.astimezone(pacific).date(), time(), pacific)


def _require_within_limits(kind, runs, jobs, today, run_id):
    agent_runs = 0
    implementations = 0
    inside = False
    own_prefix = IMPLEMENTATION_JOB if kind == "implementation" else AGENT_JOB

    for job_run, job in _agent_jobs(runs, jobs, today):
        name = _job_name(job)
        if job["status"] == "in_progress":
            agent_runs += 1
            implementations += name.startswith(IMPLEMENTATION_JOB)
            inside |= job_run == run_id and name.startswith(own_prefix)
        elif job["status"] == "completed":
            agent_runs += _ran_agent(job) and _timestamp(job["started_at"]) >= today
        for step in job.get("steps") or []:
            if step["name"] == USAGE_STEP and step["conclusion"] == "success":
                ended = step.get("completed_at") or job.get("completed_at") or job["started_at"]
                if _timestamp(ended) >= today:
                    raise Refused("a usage limit was reached today")

    if kind == "job":
        return
    if not inside:
        raise Refused(f"run {run_id} is not inside a running {own_prefix} job")
    # The calling job is in progress, so both counts already include it.
    if agent_runs > MAX_AGENT_RUNS:
        raise Refused(f"all {MAX_AGENT_RUNS} agent runs for today are used or reserved")
    if kind == "implementation" and implementations > 1:
        raise Refused("another implementation is running")


def _ran_agent(job):
    if job["conclusion"] == "skipped":
        return False
    return not any(
        step["name"] == AGENT_STEP and step["conclusion"] == "skipped"
        for step in job.get("steps") or []
    )


def _job_name(job):
    """Drop the caller prefix GitHub adds to reusable-workflow jobs."""
    return job["name"].rsplit(" / ", 1)[-1]


def _agent_jobs(runs, jobs, today):
    """Agent jobs that may be running or have run today."""
    for run in runs:
        if run["status"] != "completed" or _timestamp(run["updated_at"]) >= today:
            for job in jobs(run["id"]):
                if _job_name(job).startswith(AGENT_JOB):
                    yield run["id"], job


def _job_reader(repo, get):
    """jobs(run id) -> every attempt's jobs, read once per check."""
    read = {}

    def jobs(run_id):
        if run_id not in read:
            path = f"/repos/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page={PAGE_SIZE}"
            read[run_id] = list(_items(get, path, "jobs"))
        return read[run_id]

    return jobs


def _factory_runs(repo, get, oldest, now):
    """Runs of factory workflows that may have been active since `oldest`."""
    runs = {}
    # Newest first, and across all workflows, since runs outlive their files. No
    # filters: GitHub truncates filtered lists at 1,000.
    path = f"/repos/{repo}/actions/runs?per_page={PAGE_SIZE}"
    for page in _pages(get, path, "workflow_runs"):
        for run in page:
            listed = (run["path"], run["event"]) in OUTSIDER_RUNS
            if run["path"].startswith(WORKFLOW_PREFIX) and not listed:
                runs[run["id"]] = run
        old = page and all(_timestamp(run["created_at"]) + RUN_LOOKBACK < oldest for run in page)
        if old and not _missing_run(repo, runs.values(), oldest, now):
            break
    return list(runs.values())


def _from_outsider(repo, run):
    # A fork's pull_request run has no secrets and its own workflow files, so it
    # cannot run an agent or pause but could imitate one.
    fork = (run["head_repository"] or {}).get("full_name") != repo
    return run["event"] == "pull_request" and fork


def _require_no_missing_run(repo, runs, since, now):
    missing = _missing_run(repo, runs, since, now)
    if missing:
        raise Refused(
            f"run {missing['run_number'] - 1} of {missing['path']} is missing, "
            "so its records are unreliable"
        )


def _missing_run(repo, runs, since, now):
    """A run whose missing predecessor cannot be ordinary retention, or None."""
    horizon = now - RETENTION
    since = max(since, horizon)
    trusted = {run["workflow_id"] for run in runs if not _from_outsider(repo, run)}
    newest_first = sorted(
        (run for run in runs if run["workflow_id"] in trusted),
        key=lambda run: (run["workflow_id"], run["run_number"]),
        reverse=True,
    )
    for run, below in zip(newest_first, [*newest_first[1:], None]):
        if below and below["workflow_id"] != run["workflow_id"]:
            below = None
        number = below["run_number"] if below else 0
        if (
            run["run_number"] - number > 1
            and _timestamp(run["created_at"]) >= since
            # A purged run was older than RETENTION, and so is any run below it.
            and (below is None or _timestamp(below["created_at"]) > horizon)
        ):
            return run
    return None


def _items(get, path, key=None):
    for page in _pages(get, path, key):
        yield from page


def _pages(get, path, key=None):
    """Yield each page of a paginated list, refusing one found incomplete.

    Lists with a `key` carry total_count. It may grow between pages: an insertion
    repeats an item on the next page, so the count read still equals it. Lists
    without one end only at an empty page, whatever the Link header says.
    """
    seen = total = 0
    short = False
    number = 1
    for _ in range(MAX_PAGES):
        body, following = get(path)
        page = body[key] if key else body
        if not isinstance(page, list):
            raise ValueError("expected a list")
        seen += len(page)
        if key:
            previous, total = total, body["total_count"]
            if type(total) is not int or total < previous:
                raise ValueError("total_count is missing, invalid, or shrinking")
            if following is None and seen != total:
                raise ValueError(f"incomplete list: {seen} of {total}")
            if following is not None and len(page) < PAGE_SIZE:
                raise ValueError("incomplete page")
        elif page and short:
            raise ValueError("incomplete page")
        elif page and following is None:
            parts = urllib.parse.urlsplit(path)
            query = dict(urllib.parse.parse_qsl(parts.query))
            if number > 1 and query.get("page") != str(number):
                raise ValueError("cannot tell whether the list continues")
            query["page"] = str(number + 1)
            following = f"{parts.path}?{urllib.parse.urlencode(query)}"
        yield page
        if following is None:
            return
        short = len(page) < PAGE_SIZE
        path = following
        number += 1
    raise ValueError("too many pages")


def _timestamp(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def _github(token):
    def get(path):
        request = api_request(path, token, "factory-gate", headers={"Cache-Control": "no-cache"})
        with open_api(request) as response:
            links = response.headers.get_all("Link")
            following = None if links is None else _next_path(", ".join(links))
            return json.load(response), following

    return get


_LINK_PARAMETER = r';\s*([\w-]+)\s*=\s*(?:"([^"]*)"|([^\s",;<>]+))\s*'
_LINK = re.compile(rf"\s*<([^<>\s]+)>\s*((?:{_LINK_PARAMETER})+)(?:,|$)")


def _next_path(header):
    """The API path of rel=next, or None. Anything unparseable raises."""
    targets = []
    position = 0
    while position < len(header) or not position:
        link = _LINK.match(header, position)
        if not link:
            raise ValueError("unparseable Link header")
        relations = [
            (quoted or plain).lower().split()
            for name, quoted, plain in re.findall(_LINK_PARAMETER, link[2])
            if name.lower() == "rel"
        ]
        if len(relations) != 1 or not relations[0]:
            raise ValueError("Link header has no single relation")
        if "next" in relations[0]:
            targets.append(link[1])
        position = link.end()
    if header.rstrip().endswith(",") or len(targets) > 1:
        raise ValueError("unparseable Link header")
    if not targets:
        return None
    if not targets[0].startswith(API + "/"):
        raise ValueError("next page is not on the GitHub API")
    return targets[0].removeprefix(API)


def main(arguments=None):
    parser = argparse.ArgumentParser(description="Check whether factory work may proceed.")
    parser.add_argument("kind", choices=KINDS)
    kind = parser.parse_args(arguments).kind
    try:
        require(kind)
    except Refused as error:
        print(f"Factory gate refused {kind}: {error}", file=sys.stderr)
        return 1
    print(f"Factory gate: {kind} allowed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
