import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from email.message import Message
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

import gate

# 12:00 Pacific; the Pacific day began at 2026-11-24T08:00:00Z.
NOW = datetime(2026, 11, 24, 20, 0, tzinfo=timezone.utc)
TODAY = "2026-11-24T18:00:00Z"
YESTERDAY = "2026-11-24T07:59:59Z"
REPO = "octo/repo"
OWN_RUN = 1000


def job(name="factory-agent-review", status="completed", conclusion="success",
        started=TODAY, run_step="success", usage=None):
    steps = [{"name": "factory-agent-run", "conclusion": run_step}]
    if usage:
        steps.append({"name": "factory-usage-limit", "conclusion": usage})
    return {"name": name, "status": status, "conclusion": conclusion,
            "started_at": started, "steps": steps}


def running(name="factory-agent-review", started=TODAY):
    return job(name, "in_progress", None, started, run_step=None)


def run(run_id, updated=TODAY, created=TODAY, **extra):
    return {"id": run_id, "status": "completed", "created_at": created,
            "updated_at": updated, "event": "schedule",
            "conclusion": "success", "run_attempt": 1, "workflow_id": 5, "path": ".github/workflows/factory-work.yml",
            "head_repository": {"full_name": REPO}, **extra}


class FakeGitHub:
    """The GitHub REST boundary: get(path) -> (body, next path or None)."""

    def __init__(self):
        self.variable = {"name": "FACTORY_ENABLED", "value": "true"}
        self.open_pauses = []
        self.events = []
        self.resumes = []
        self.approvals = {}
        self.runs = []
        self.jobs = {}
        self.fail = None
        self.label = {"name": "factory-paused"}
        self.tags = []

    def add(self, run_id, *jobs, **extra):
        self.runs.append(run(run_id, **extra))
        self.jobs[run_id] = list(jobs)

    def resume(self, created, **extra):
        self.resumes.append({
            "id": 77, "created_at": created, "head_branch": "main",
            "event": "workflow_dispatch", "status": "completed",
            "conclusion": "success", "head_sha": "onmain",
            "path": ".github/workflows/factory-resume.yml", **extra})
        self.approvals[77] = [{"state": "approved", "user": {"login": "octo"},
                               "environments": [{"name": "factory-resume"}]}]

    def get(self, path):
        if self.fail and self.fail in path:
            raise urllib.error.HTTPError(path, 503, "unavailable", {}, None)
        route, _, query = path.partition("?")
        route = route.removeprefix(f"/repos/{REPO}")
        if route == "/actions/variables/FACTORY_ENABLED":
            if self.variable is None:
                raise urllib.error.HTTPError(path, 404, "missing", {}, None)
            return self.variable, None
        if route == "/labels/factory-paused":
            if self.label is None:
                raise urllib.error.HTTPError(path, 404, "missing", {}, None)
            return self.label, None
        if route == "/git/ref/heads/main":
            return {"object": {"sha": "maintip"}}, None
        if route == "/compare/onmain...maintip":
            return {"status": "ahead", "merge_base_commit": {"sha": "onmain"}}, None
        if route.startswith("/compare/"):
            return {"status": "diverged", "merge_base_commit": {"sha": "onmain"}}, None
        key = None
        if route == "/issues":
            items = self.open_pauses
        elif route == "/issues/events":
            items = self.events
        elif route == "/git/matching-refs/tags/main":
            # Not paginated on GitHub: it ignores per_page and page.
            return [{"ref": f"refs/tags/{tag}"} for tag in self.tags], None
        elif route == "/actions/workflows/factory-resume.yml/runs":
            key, items = "workflow_runs", self.resumes
        elif route == "/actions/runs":
            # Newest first, numbered within each workflow in order of creation.
            ordered = sorted(self.runs, key=lambda item: item["created_at"], reverse=True)
            workflows = [item["workflow_id"] for item in ordered]
            key, items = "workflow_runs", [
                {"run_number": workflows[index:].count(item["workflow_id"]), **item}
                for index, item in enumerate(ordered)]
        elif route.endswith("/approvals"):
            items = self.approvals[int(route.split("/")[3])]
        elif route.endswith("/jobs"):
            key, items = "jobs", self.jobs[int(route.split("/")[3])]
        else:
            raise AssertionError(path)
        query = dict(part.split("=") for part in query.split("&") if part)
        size, number = int(query.get("per_page", 30)), int(query.get("page", 1))
        page = items[(number - 1) * size:number * size]
        query["page"] = number + 1
        following = path.split("?")[0] + "?" + "&".join(f"{k}={v}" for k, v in query.items())
        if number * size >= len(items):
            following = None
        return ({key: page, "total_count": len(items)} if key else page), following


def pause_event(at=YESTERDAY):
    return {"event": "labeled", "created_at": at, "label": {"name": "factory-paused"}}


class GateCase(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()

    def check(self, kind="publish"):
        return gate.check(kind, REPO, self.github.get, now=NOW, run_id=OWN_RUN)

    def assertRefused(self, reason, kind="publish"):
        decision = self.check(kind)
        self.assertFalse(decision.allowed, decision.reason)
        self.assertIn(reason, decision.reason)

    def assertAllowed(self, kind="publish"):
        decision = self.check(kind)
        self.assertTrue(decision.allowed, decision.reason)


class SwitchTests(GateCase):
    def test_on_allows_publish_merge_and_job(self):
        for kind in ("publish", "merge", "job"):
            self.assertAllowed(kind)

    def test_unset_refuses(self):
        self.github.variable = None
        self.assertRefused("FACTORY_ENABLED is unset")

    def test_anything_but_true_is_off(self):
        for value in ("false", "", "off", "True", " true", None, True):
            with self.subTest(value=value):
                self.github.variable = {"value": value}
                self.assertRefused("FACTORY_ENABLED is off")

    def test_every_kind_rereads_the_live_switch(self):
        self.assertAllowed("publish")
        self.github.variable = {"value": "false"}
        for kind in gate.KINDS:
            self.assertRefused("FACTORY_ENABLED is off", kind)

    def test_switching_off_or_pausing_during_a_slow_check_refuses(self):
        for change, reason in (
                (lambda: setattr(self.github, "variable", {"value": "false"}), "is off"),
                (lambda: setattr(self.github, "open_pauses", [{"number": 9}]), "issue #9")):
            self.github = FakeGitHub()
            read = self.github.get

            def get(path):
                answer = read(path)
                if "/issues/events" in path:
                    change()
                return answer

            self.github.get = get
            self.assertRefused(reason)

    def test_unknown_kind_refuses(self):
        self.assertRefused("unknown check kind", "deploy")


class PauseTests(GateCase):
    def test_open_issue_refuses_every_kind(self):
        self.github.open_pauses = [{"number": 9}]
        for kind in gate.KINDS:
            self.assertRefused("open factory-paused issue #9", kind)

    def test_closing_or_unlabelling_the_issue_does_not_resume(self):
        self.github.events = [pause_event()]
        self.assertRefused("not been resumed")

    def test_approved_resume_after_the_pause_resumes(self):
        self.github.events = [pause_event()]
        self.github.resume(TODAY)
        self.assertAllowed()

    def test_approved_resume_does_not_override_an_open_issue(self):
        self.github.resume(TODAY)
        self.github.open_pauses = [{"number": 9}]
        self.assertRefused("open factory-paused issue")

    def test_resume_requested_before_or_with_the_pause_does_not_clear_it(self):
        self.github.resume(YESTERDAY)
        for at in (TODAY, YESTERDAY):
            self.github.events = [pause_event(at)]
            self.assertRefused("not been resumed")

    def test_unresumed_pause_on_a_later_page_refuses(self):
        self.github.resume("2026-11-24T12:00:00Z")
        self.github.events = [{"event": "closed", "created_at": TODAY}] * 100 + [
            pause_event(TODAY), pause_event(YESTERDAY)]
        self.assertRefused("not been resumed")

    def test_full_event_page_without_a_next_link_is_not_the_end(self):
        self.github.events = [{"event": "closed", "created_at": TODAY}] * 100 + [pause_event()]
        read = self.github.get
        self.github.get = lambda path: (read(path)[0], None)
        self.assertRefused("not been resumed")

    def test_short_event_page_with_a_lost_next_link_refuses(self):
        for kept in (1, 50, 99):
            for hidden in (kept, 100):
                with self.subTest(kept=kept, hidden=hidden):
                    self.github = FakeGitHub()
                    self.github.events = [{"event": "closed", "created_at": TODAY}] * 101
                    self.github.events[hidden] = pause_event()
                    read = self.github.get

                    def get(path):
                        body, _ = read(path)
                        short = "/issues/events" in path and "page=2" not in path
                        return (body[:kept] if short else body), None

                    self.github.get = get
                    self.assertFalse(self.check().allowed)

    def test_short_event_page_followed_by_more_events_refuses(self):
        # Even with no visible pause: the missing middle could hold one.
        self.github.events = [{"event": "closed", "created_at": TODAY}] * 101
        read = self.github.get

        def get(path):
            body, following = read(path)
            if "/issues/events" in path and "page=2" not in path:
                body = body[:50]
            return body, following

        self.github.get = get
        self.assertRefused("incomplete page")

    def test_final_short_event_page_is_accepted(self):
        for count in (1, 99, 100, 101, 200):
            self.github.events = [{"event": "closed", "created_at": TODAY}] * count
            self.assertAllowed()

    def test_label_case_does_not_hide_a_pause(self):
        self.github.events = [{**pause_event(), "label": {"name": "Factory-Paused"}}]
        self.assertRefused("not been resumed")

    def test_missing_or_renamed_label_refuses(self):
        for label in (None, {"name": "renamed"}):
            self.github.label = label
            self.assertRefused("label is missing")

    def test_pause_label_lookup_is_shared_with_the_publisher(self):
        get = self.github.get
        self.assertTrue(gate.pause_label_exists(REPO, get))
        self.github.label = {"name": "Factory-Paused"}
        self.assertTrue(gate.pause_label_exists(REPO, get))
        for label in (None, {"name": "renamed"}):
            self.github.label = label
            self.assertFalse(gate.pause_label_exists(REPO, get))
        self.github.fail = "/labels/"
        with self.assertRaises(urllib.error.HTTPError):
            gate.pause_label_exists(REPO, get)

    def test_pause_applied_and_removed_during_a_check_refuses(self):
        for resumed, old in ((False, 0), (True, 250)):
            self.github = FakeGitHub()
            if resumed:
                self.github.resume("2026-11-24T12:00:00Z")
            self.github.events = [{"event": "closed", "created_at": YESTERDAY}] * old
            read = self.github.get

            def get(path):
                answer = read(path)
                if "/issues/events" in path:
                    self.github.events = [
                        {"event": "unlabeled", "created_at": TODAY,
                         "label": {"name": "factory-paused"}},
                        pause_event(TODAY)] + self.github.events[-old:]
                return answer

            self.github.get = get
            self.assertRefused("not been resumed")

    def test_resume_from_a_commit_off_main_does_not_resume(self):
        self.github.events = [pause_event()]
        self.github.resume(TODAY, head_sha="other")
        self.assertRefused("not been resumed")

    def test_unprovable_resume_commit_refuses(self):
        self.github.events = [pause_event()]
        self.github.resume(TODAY, head_sha=None)
        self.assertRefused("lookup failed")
        for part in ("/compare/", "/git/ref/heads/main", "/matching-refs/"):
            self.github = FakeGitHub()
            self.github.resume(TODAY)
            self.github.fail = part
            self.assertRefused("lookup failed")

    def test_compare_status_and_merge_base_must_both_prove_ancestry(self):
        for answer in ({"status": "ahead", "merge_base_commit": {"sha": "x"}},
                       {"status": "behind", "merge_base_commit": {"sha": "onmain"}}):
            self.github = FakeGitHub()
            self.github.events = [pause_event()]
            self.github.resume(TODAY)
            read = self.github.get
            self.github.get = lambda path: (
                (answer, None) if "/compare/" in path else read(path))
            self.assertRefused("not been resumed")

    def test_tag_named_main_refuses_a_resume(self):
        self.github.resume(TODAY)
        self.github.tags = ["main-old"]
        self.assertAllowed()
        self.github.tags = ["main-old", "main"]
        self.assertRefused("tag named main")

    def test_later_failed_request_keeps_an_earlier_valid_resume(self):
        self.github.events = [pause_event()]
        self.github.resume("2026-11-24T12:00:00Z")
        self.github.resumes.insert(0, {**self.github.resumes[0], "id": 78,
                                       "created_at": TODAY, "conclusion": "failure"})
        self.assertAllowed()

    def test_invalid_resume_runs_do_not_resume(self):
        for extra in ({"head_branch": "evil"}, {"event": "pull_request"},
                      {"conclusion": "failure"}, {"status": "in_progress"},
                      {"path": ".github/workflows/other.yml"}):
            with self.subTest(extra=extra):
                self.github = FakeGitHub()
                self.github.events = [pause_event()]
                self.github.resume(TODAY, **extra)
                self.assertRefused("not been resumed")

    def test_resume_needs_the_maintainers_approval_of_that_environment(self):
        good = {"state": "approved", "user": {"login": "octo"},
                "environments": [{"name": "factory-resume"}]}
        for approvals in ([], [{**good, "state": "rejected"}],
                          [{**good, "user": {"login": "mallory"}}],
                          [{**good, "environments": [{"name": "other"}]}]):
            with self.subTest(approvals=approvals):
                self.github = FakeGitHub()
                self.github.events = [pause_event()]
                self.github.resume(TODAY)
                self.github.approvals[77] = approvals
                self.assertRefused("not been resumed")


BEFORE = "2026-11-24T09:00:00Z"
RESUME = "2026-11-24T10:00:00Z"
AFTER = "2026-11-24T11:00:00Z"


class FailedPauseTests(GateCase):
    def setUp(self):
        super().setUp()
        self.github.resume(RESUME)
        self.github.add(OWN_RUN, running("factory-agent-implementation"))

    def pause_job(self, conclusion="failure", name="pause / factory-pause", at=AFTER,
                  status="completed", steps=()):
        return {"name": name, "status": status, "conclusion": conclusion,
                "started_at": at, "completed_at": at, "steps": list(steps)}

    def add(self, *jobs, conclusion="failure", updated=AFTER, **extra):
        self.github.add(50, *jobs, conclusion=conclusion, updated=updated, **extra)

    def assertStopped(self, reason="factory-pause"):
        for kind in gate.KINDS:
            self.assertRefused(reason, kind)

    def assertRunning(self):
        for kind in gate.KINDS:
            self.assertAllowed(kind)

    def test_successful_pause_relies_on_the_issue(self):
        for name in ("factory-pause", "pause / factory-pause"):
            self.github.runs, self.github.jobs = self.github.runs[:1], {
                OWN_RUN: self.github.jobs[OWN_RUN]}
            self.add(self.pause_job("success", name), conclusion="success")
            self.assertRunning()

    def test_unsuccessful_pause_stops_every_kind(self):
        for name in ("factory-pause", "a / b / factory-pause"):
            for conclusion in ("failure", "cancelled", "timed_out", "neutral",
                               "action_required", "stale", "startup_failure", None):
                with self.subTest(name=name, conclusion=conclusion):
                    self.github.runs = self.github.runs[:1]
                    self.add(self.pause_job(conclusion, name))
                    self.assertStopped()

    def test_unfinished_pause_stops_every_kind(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            self.github.runs = self.github.runs[:1]
            # Even one that started before the resume.
            self.add(self.pause_job(None, at=BEFORE, status=status), status="in_progress",
                     conclusion=None, updated=BEFORE)
            self.assertStopped()

    def test_called_pause_that_was_skipped_stops_every_kind(self):
        self.add(self.pause_job("skipped"))
        self.assertStopped()

    def test_called_pause_skipped_in_a_successful_run_today_stops(self):
        self.add(self.pause_job("skipped"), conclusion="success")
        self.assertStopped()

    def test_conditional_pause_job_that_was_skipped_is_not_a_pause(self):
        for conclusion in ("success", "failure"):
            self.github.runs = self.github.runs[:1]
            self.add(self.pause_job("skipped", "factory-pause"), conclusion=conclusion)
            self.assertRunning()

    def test_skipped_job_in_a_run_of_the_pause_workflow_itself_stops(self):
        for jobs in ([self.pause_job("skipped", "factory-pause")], []):
            self.github.runs = self.github.runs[:1]
            self.add(*jobs, conclusion="success", workflow_id=9,
                     path=".github/workflows/factory-pause.yml")
            self.assertStopped()

    def test_other_names_are_not_pauses(self):
        for name in ("factory-pause-report", "xfactory-pause", "factory-pause / verify",
                     "factory-paused"):
            self.github.runs = self.github.runs[:1]
            self.add(self.pause_job(name=name))
            self.assertRunning()

    def test_failure_marker_step_stops_every_kind(self):
        for conclusion, status in (("success", "completed"), ("failure", "completed"),
                                   ("cancelled", "completed"), (None, "in_progress")):
            self.github.runs = self.github.runs[:1]
            self.add(self.pause_job("failure", "publish", steps=[
                {"name": "factory-pause-failed", "conclusion": conclusion, "status": status}]))
            self.assertStopped("factory-pause-failed")

    def test_failure_marker_step_that_did_not_run_is_ignored(self):
        for conclusion, status in (("skipped", "completed"), (None, "queued"),
                                   (None, "pending")):
            self.github.runs = self.github.runs[:1]
            self.add(self.pause_job("failure", "publish", steps=[
                {"name": "factory-pause-failed", "conclusion": conclusion, "status": status},
                {"name": "factory-pause-failed-x", "conclusion": "success"}]))
            self.assertRunning()

    def test_only_a_later_resume_clears_a_failed_pause(self):
        for at, stopped in ((BEFORE, False), (RESUME, True), (AFTER, True)):
            for jobs in ([self.pause_job(at=at)],
                         [self.pause_job(name="publish", at=at, steps=[
                             {"name": "factory-pause-failed", "conclusion": "success"}])]):
                self.github.runs = self.github.runs[:1]
                self.add(*jobs)
                (self.assertStopped if stopped else self.assertRunning)()

    def test_a_successful_rerun_does_not_clear_a_failed_attempt(self):
        self.github.resume("2026-11-20T00:00:00Z")
        self.github.resumes = self.github.resumes[-1:]
        self.add(self.pause_job(at="2026-11-21T00:00:00Z"), self.pause_job("success"),
                 conclusion="success", run_attempt=2, created="2026-11-21T00:00:00Z",
                 updated="2026-11-21T01:00:00Z")
        self.assertStopped()

    def test_failure_does_not_expire(self):
        self.github.resumes[0]["created_at"] = "2026-01-01T00:00:00Z"
        old = "2026-02-01T00:00:00Z"
        self.add(self.pause_job(at=old), created=old, updated=old)
        self.assertStopped()

    def test_without_any_resume_all_history_counts(self):
        self.github.resumes = []
        old = "2025-02-01T00:00:00Z"
        self.add(self.pause_job(at=old), created=old, updated=old)
        self.assertStopped()

    def test_run_created_before_the_resume_but_failing_after_it_counts(self):
        self.add(self.pause_job(), created="2026-10-30T00:00:00Z")
        self.assertStopped()

    def test_removed_workflow_still_counts_but_other_workflows_do_not(self):
        self.add(self.pause_job(), path=".github/workflows/factory-gone.yml")
        self.assertStopped()
        self.github.runs[-1].update(path=".github/workflows/runTests.yml", workflow_id=6)
        self.assertRunning()

    def test_fork_pull_request_cannot_stop_the_factory(self):
        self.add(self.pause_job(), event="pull_request",
                 head_repository={"full_name": "mallory/repo"})
        self.assertRunning()
        self.github.runs[-1]["event"] = "workflow_run"
        self.assertStopped()

    def test_missing_run_since_the_resume_refuses_every_kind(self):
        self.github.runs[0]["run_number"] = 9
        self.assertStopped("missing")

    def test_missing_run_yesterday_but_since_the_resume_refuses(self):
        self.github.resumes[0]["created_at"] = "2026-11-19T00:00:00Z"
        self.github.add(50, created="2026-11-20T00:00:00Z", updated=YESTERDAY, run_number=3)
        self.github.runs[0]["run_number"] = 4
        self.assertStopped("missing")

    def test_lookups_are_bounded(self):
        for index in range(301):
            self.github.add(2000 + index, created=AFTER, conclusion="failure")
        self.assertRefused("too many")

    def test_missing_evidence_refuses_every_kind(self):
        for change in (lambda run: run.pop("conclusion"), lambda run: run.pop("run_attempt"),
                       lambda run: run.pop("updated_at")):
            self.github.runs = self.github.runs[:1]
            self.add(conclusion="success", updated="2026-11-24T10:30:00Z")
            change(self.github.runs[-1])
            self.assertStopped("lookup failed")
        for field in ("completed_at", "status", "conclusion", "steps", "name"):
            job = self.pause_job()
            del job[field]
            self.github.runs = self.github.runs[:1]
            self.add(job)
            self.assertStopped("")
        self.github.runs = self.github.runs[:1]
        self.add(self.pause_job())
        self.github.fail = "/runs/50/jobs"
        self.assertStopped("lookup failed")

    CLASSIFY = {"path": ".github/workflows/factory-classify.yml", "workflow_id": 8,
                "event": "pull_request_target",
                "head_repository": {"full_name": "mallory/repo"}}

    def test_outsider_runs_do_not_consume_lookups(self):
        for extra in (self.CLASSIFY, {"event": "pull_request", "head_repository": None},
                      {"event": "pull_request", "workflow_id": 9,
                       "head_repository": {"full_name": "mallory/repo"}}):
            for conclusion in ("success", "failure", "cancelled", "skipped"):
                with self.subTest(extra=extra, conclusion=conclusion):
                    self.github.runs = self.github.runs[:1]
                    for index in range(350):
                        self.github.add(2000 + index, created=AFTER, conclusion=conclusion,
                                        **extra)
                    self.github.fail = "/runs/2"
                    self.assertRunning()

    def test_unfinished_outsider_runs_do_not_stop_work(self):
        for index in range(350):
            self.github.add(2000 + index, created=AFTER, status="queued", conclusion=None,
                            **self.CLASSIFY)
        self.assertRunning()

    def test_deleted_outsider_runs_do_not_stop_work(self):
        self.add(created=AFTER, run_number=700, **self.CLASSIFY)
        self.github.add(51, created=AFTER, run_number=3, **self.CLASSIFY)
        self.assertRunning()
        self.github.runs = self.github.runs[:1]
        self.add(created=AFTER, run_number=7, workflow_id=9, event="pull_request",
                 head_repository={"full_name": "mallory/repo"})
        self.assertRunning()

    def test_a_real_pause_is_found_among_outsider_runs(self):
        self.add(self.pause_job())
        for index in range(350):
            self.github.add(2000 + index, created=AFTER, **self.CLASSIFY)
        self.assertStopped()

    def test_only_the_exact_path_and_event_are_excluded(self):
        for change in ({"event": "workflow_dispatch"}, {"event": "workflow_run"},
                       {"event": "pull_request", "head_repository": {"full_name": REPO}},
                       {"path": ".github/workflows/factory-classify.yaml"},
                       {"path": ".github/workflows/factory-classify.yml.yml"}):
            with self.subTest(change=change):
                self.github.runs = self.github.runs[:1]
                self.add(self.pause_job(), **{**self.CLASSIFY, **change})
                self.assertStopped()

    def test_an_outsider_run_cannot_cover_for_a_deleted_one(self):
        # Number 2 is gone; a fork's run 3 sits between it and a trusted run 4.
        self.github.runs[0]["run_number"] = 4
        self.add(created=AFTER, run_number=3, event="pull_request",
                 head_repository={"full_name": "mallory/repo"})
        self.github.add(51, created="2026-11-24T10:30:00Z", run_number=1)
        self.assertStopped("missing")

    def test_a_gap_that_retention_may_have_made_does_not_stop_work(self):
        # GitHub purges a run awaiting approval after 30 days, so one missing
        # between these may be innocent.
        self.github.resumes[0]["created_at"] = "2026-01-01T00:00:00Z"
        self.github.runs[0]["run_number"] = 4
        old = "2026-10-20T00:00:00Z"
        self.add(created=old, updated=old, run_number=2, conclusion="success")
        self.assertRunning()
        recent = "2026-10-27T00:00:00Z"
        self.github.runs[1].update(created_at=recent, updated_at=recent)
        self.assertStopped("missing")

    def test_retention_below_old_runs_does_not_stop_work(self):
        for created in ("2026-01-01T00:00:00Z", None):
            self.github.resumes = self.github.resumes[:1] if created else []
            if created:
                self.github.resumes[0]["created_at"] = created
            self.github.runs = self.github.runs[:1]
            old = "2026-10-20T00:00:00Z"
            self.add(created=old, updated=old, run_number=40, conclusion="success",
                     workflow_id=9)
            self.assertRunning()

    def test_pause_jobs_in_workflows_cannot_hide_their_failure(self):
        # Runs that succeeded before today are trusted not to hold a failure.
        for path in (Path(__file__).parents[2] / ".github/workflows").glob("factory-*.yml"):
            text = path.read_text(encoding="utf-8")
            if "factory-pause" in text.replace("factory-paused", ""):
                self.assertNotIn("continue-on-error", text, path.name)


class LimitTests(GateCase):
    def setUp(self):
        super().setUp()
        self.github.add(OWN_RUN, running())

    def test_the_twelfth_agent_run_starts_and_the_thirteenth_does_not(self):
        for run_id in range(11):
            self.github.add(run_id, job())
        self.assertAllowed("agent")
        self.github.add(11, job(conclusion="failure"))
        self.assertRefused("12 agent runs", "agent")
        self.github.jobs[OWN_RUN] = [running("factory-agent-implementation")]
        self.assertRefused("12 agent runs", "implementation")

    def test_count_includes_retries_pages_and_reusable_workflow_jobs(self):
        self.github.add(1, *[job("other")] * 100, *[job("work / factory-agent-fix (1)")] * 12)
        self.assertRefused("12 agent runs", "agent")

    def test_count_excludes_runs_that_never_started_the_agent(self):
        self.github.add(1, *[job(conclusion="failure", run_step="skipped")] * 12)
        self.github.add(2, *[job(conclusion="skipped")] * 12)
        self.github.add(3, *[job("factory-publish")] * 12)
        self.github.add(4, *[job(status="queued", conclusion=None)] * 12)
        self.assertAllowed("agent")

    def test_count_restarts_at_pacific_midnight(self):
        self.github.add(1, *[job(started=YESTERDAY)] * 12)
        self.assertAllowed("agent")

    def test_old_workflow_run_rerun_today_still_counts(self):
        self.github.add(1, *[job()] * 12, created="2026-10-30T00:00:00Z")
        self.assertRefused("12 agent runs", "agent")

    def test_fork_pull_request_jobs_cannot_consume_the_limit(self):
        self.github.add(1, *[job(usage="success")] * 12, event="pull_request",
                        head_repository={"full_name": "mallory/repo"})
        self.assertAllowed("agent")

    def test_fork_pull_request_whose_repository_was_deleted_is_ignored(self):
        self.github.add(1, *[job(usage="success")] * 12, event="pull_request",
                        head_repository=None)
        self.assertAllowed("agent")

    def test_trusted_events_on_a_fork_head_still_count(self):
        self.github.add(1, *[job()] * 12, event="workflow_run",
                        head_repository={"full_name": "mallory/repo"})
        self.assertRefused("12 agent runs", "agent")

    def test_daily_limit_does_not_strand_finished_work(self):
        self.github.add(1, *[job()] * 12)
        self.assertAllowed("publish")
        self.assertAllowed("merge")

    def test_usage_limit_stops_new_work_for_the_rest_of_the_day(self):
        self.github.add(1, job(conclusion="failure", usage="success"))
        for kind in ("job", "agent", "implementation"):
            self.assertRefused("usage limit", kind)
        self.assertAllowed("publish")

    def test_skipped_or_yesterdays_usage_step_does_not_stop_work(self):
        self.github.add(1, job(usage="skipped"))
        self.github.add(2, job(started=YESTERDAY, usage="success"))
        self.assertAllowed("agent")

    def test_usage_step_after_midnight_counts_for_the_day_it_finished(self):
        item = job(started=YESTERDAY, usage="success")
        item["steps"][-1]["completed_at"] = TODAY
        self.github.add(1, item)
        self.assertRefused("usage limit", "agent")

    def test_only_one_implementation_at_a_time(self):
        self.github.jobs[OWN_RUN] = [running("factory-agent-implementation")]
        self.assertAllowed("implementation")
        # Started yesterday, with no later run update.
        self.github.add(1, running("work / factory-agent-implementation", YESTERDAY),
                        updated=YESTERDAY, status="in_progress")
        self.assertRefused("another implementation", "implementation")

    def test_runs_of_a_removed_workflow_file_still_count(self):
        # The ledger lists runs by repository, so no workflow lookup can hide them.
        self.github.add(1, *[job()] * 12, workflow_id=9,
                        path=".github/workflows/factory-gone.yml", run_number=1)
        self.assertRefused("12 agent runs", "agent")

    def test_non_factory_workflows_do_not_count(self):
        self.github.add(1, *[job()] * 12, workflow_id=6,
                        path=".github/workflows/runTests.yml")
        self.assertAllowed("agent")

    def test_deleted_run_between_todays_runs_refuses(self):
        self.github.add(1, created="2026-11-24T12:00:00Z", run_number=3)
        self.github.runs[0]["run_number"] = 5
        self.assertRefused("missing", "agent")
        self.assertRefused("missing", "job")

    def test_older_run_number_gap_does_not_block(self):
        self.github.resume("2026-11-24T08:30:00Z")
        self.github.add(1, created="2026-11-20T00:00:00Z", run_number=4)
        self.github.add(2, created="2026-11-19T00:00:00Z", run_number=2)
        self.github.runs[0]["run_number"] = 5
        self.assertAllowed("agent")

    def test_todays_run_without_any_predecessor_refuses(self):
        self.github.runs[0]["run_number"] = 13
        self.assertRefused("missing", "agent")
        self.assertRefused("missing", "job")

    def test_oldest_of_todays_runs_removed_refuses(self):
        self.github.runs[0]["run_number"] = 6
        self.github.add(1, created="2026-11-24T12:00:00Z", run_number=5)
        self.github.add(2, created="2026-11-24T11:00:00Z", run_number=4)
        self.assertRefused("missing", "agent")

    def test_predecessor_older_than_the_lookback_is_found(self):
        self.github.resume("2026-11-24T08:30:00Z")
        for index in range(250):
            self.github.add(index, updated="2025-01-01T00:00:00Z", workflow_id=6,
                            created="2025-01-02T00:00:00Z", path="other.yml")
        self.github.runs[0]["run_number"] = 13
        self.github.add(999, updated="2025-01-01T00:00:00Z", run_number=12,
                        created="2025-01-01T00:00:00Z")
        self.assertAllowed("agent")

    def test_older_history_may_be_purged(self):
        self.github.resume("2026-11-24T08:30:00Z")
        self.github.runs[0]["run_number"] = 13
        self.github.add(1, created="2026-11-20T00:00:00Z", run_number=12)
        self.assertAllowed("agent")

    def test_incomplete_lists_refuse(self):
        self.github.add(1, *[job()] * 12)
        def lose(match, change):
            read = self.github.get

            def get(path):
                body, following = read(path)
                if match in path:
                    body = dict(body)
                    change(body)
                return body, following
            return get

        def empty(body):
            body[next(k for k in body if k != "total_count")] = []

        for match in ("/actions/runs?", "/actions/runs/1/jobs"):
            for change in (empty, lambda body: body.pop("total_count"),
                           lambda body: body.update(total_count="13"),
                           lambda body: body.update(total_count=True),
                           lambda body: body.update(total_count=10 ** 6)):
                with self.subTest(match=match):
                    original, self.github.get = self.github.get, lose(match, change)
                    self.assertRefused("lookup failed", "job")
                    self.github.get = original

    def test_short_page_before_a_next_link_refuses(self):
        for index in range(150):
            self.github.add(index, created="2026-11-20T00:00:00Z", updated=YESTERDAY)
        self.assertAllowed("agent")
        read = self.github.get

        def get(path):
            body, following = read(path)
            if path.partition("?")[0].endswith("/actions/runs"):
                body = {**body, "workflow_runs": body["workflow_runs"][1:]}
            return body, following

        self.github.get = get
        self.assertRefused("lookup failed", "agent")

    def test_run_created_while_listing_is_not_mistaken_for_loss(self):
        for index in range(150):
            self.github.add(index, created="2026-11-20T00:00:00Z", updated=YESTERDAY)
        read = self.github.get

        def get(path):
            answer = read(path)
            if "/actions/runs?" in path and "page=2" not in path:
                self.github.add(5000, created=TODAY)
            return answer

        self.github.get = get
        self.assertAllowed("agent")

    def test_agent_check_must_run_inside_a_recognized_agent_job(self):
        self.github.jobs[OWN_RUN] = [running("build")]
        self.assertRefused("not inside", "agent")
        self.github.jobs[OWN_RUN] = [running("factory-agent-review")]
        self.assertRefused("not inside", "implementation")


class FailureTests(GateCase):
    def test_each_failed_lookup_refuses(self):
        self.github.events = [pause_event()]
        self.github.resume(TODAY)
        self.github.add(OWN_RUN, running())
        self.assertAllowed("agent")
        for part in ("variables", "/issues?", "/issues/events", "factory-resume.yml",
                     "/approvals", "/labels/", "/actions/runs?", "/jobs"):
            with self.subTest(part=part):
                self.github.fail = part
                self.assertRefused("lookup failed", "agent")

    def test_malformed_responses_refuse(self):
        for body in (None, [], {}, "x", {"value": "true"}):
            with self.subTest(body=body):
                self.github.get = lambda path, body=body: (body, None)
                self.assertRefused("lookup failed", "agent")

    def test_malformed_job_refuses(self):
        self.github.add(OWN_RUN, running(), {"name": "factory-agent-x"})
        self.assertRefused("lookup failed", "agent")

    def test_endless_pagination_refuses(self):
        self.github.get = lambda path: (
            ({"value": "true"}, None) if "variables" in path else ([], path))
        self.assertRefused("lookup failed")


class CommandTests(unittest.TestCase):
    ENV = {"GITHUB_REPOSITORY": REPO, "FACTORY_GATE_TOKEN": "t",
           "GITHUB_RUN_ID": "1000"}

    def main(self, *arguments, env=None, responses=()):
        out, err = io.StringIO(), io.StringIO()
        with patch.dict("os.environ", self.ENV if env is None else env, clear=True), \
                patch("gate.open_api", side_effect=responses), \
                redirect_stdout(out), redirect_stderr(err):
            code = gate.main(arguments)
        return code, out.getvalue() + err.getvalue()

    @staticmethod
    def response(body, *links):
        response = io.BytesIO(json.dumps(body).encode())
        response.headers = Message()
        for link in links:
            response.headers["Link"] = link
        return response

    def test_allowed_exits_zero(self):
        label = {"name": "factory-paused"}
        code, text = self.main("publish", responses=map(self.response, (
            {"value": "true"}, label, [], {"total_count": 0, "workflow_runs": []}, [],
            {"total_count": 0, "workflow_runs": []}, label, [], [], {"value": "true"})))
        self.assertEqual(code, 0, text)
        self.assertIn("allowed", text)

    def test_refused_exits_one_with_the_reason(self):
        code, text = self.main("merge", responses=[self.response({"value": "false"})])
        self.assertEqual(code, 1)
        self.assertIn("FACTORY_ENABLED is off", text)

    def test_network_error_refuses(self):
        code, text = self.main("merge", responses=[OSError("no network")])
        self.assertEqual(code, 1)
        self.assertIn("lookup failed", text)

    def test_next_page_on_another_host_refuses_without_sending_the_token(self):
        code, text = self.main("publish", responses=[
            self.response({"value": "true"}),
            self.response({"name": "factory-paused"}),
            self.response([], '<https://evil.test/x>; rel="next"')])
        self.assertEqual(code, 1)
        self.assertIn("not on the GitHub API", text)

    def follow(self, *links):
        answer = self.response([], *links)
        with patch("gate.open_api", return_value=answer):
            return gate._github("t")("/x")[1]

    def test_next_link_spellings_are_followed(self):
        url = "<https://api.github.com/x?page=2>"
        for link in ('; rel="next"', "; rel=next", '; REL="next"', '; rel="last next"',
                     ' ; title="a, b" ; rel = "next"'):
            self.assertEqual(self.follow(url + link), "/x?page=2")
        self.assertEqual(self.follow('<https://api.github.com/x>; rel="prev"',
                                     url + '; rel="next"'), "/x?page=2")
        self.assertIsNone(self.follow('<https://api.github.com/x>; rel="prev"'))
        self.assertIsNone(self.follow())

    def test_unparseable_link_headers_refuse(self):
        url = "<https://api.github.com/x?page=2>"
        for link in ("", " ", "junk", url, url + "; rel", url + '; rel="next',
                     url + '; rel="next", junk', f'{url}; rel="next", {url[:-1]}3>; rel="next"'):
            with self.subTest(link=link), self.assertRaises(ValueError):
                self.follow(link)

    def test_missing_configuration_refuses(self):
        for name in self.ENV:
            env = {key: value for key, value in self.ENV.items() if key != name}
            code, text = self.main("publish", env=env)
            self.assertEqual(code, 1)
            self.assertIn(name, text)

    def test_isolated_command_refuses_cleanly_for_every_kind(self):
        # As workflows run it: -I drops the script's directory from the path.
        script = str(Path(gate.__file__).resolve())
        for kind in gate.KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as elsewhere:
                result = subprocess.run(
                    [sys.executable, "-I", script, kind], env={}, cwd=elsewhere,
                    capture_output=True, text=True)
                self.assertEqual(
                    (result.returncode, result.stdout, result.stderr),
                    (1, "", f"Factory gate refused {kind}: GITHUB_REPOSITORY is not set\n"))

    def test_require_raises_for_python_callers(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(gate.Refused, "GITHUB_REPOSITORY"):
                gate.require("publish")


class ResumeWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).parents[2] / ".github" / "workflows" /
                     "factory-resume.yml").read_text(encoding="utf-8")

    def test_names_match_the_gate(self):
        self.assertEqual(
            (gate.RESUME_WORKFLOW, gate.RESUME_ENVIRONMENT, gate.PAUSE_LABEL),
            ("factory-resume.yml", "factory-resume", "factory-paused"))

    def test_resume_is_manual_and_waits_on_the_environment(self):
        self.assertRegex(self.text, r"(?m)^on:\n  workflow_dispatch:\n\n")
        self.assertIn("\n    environment: factory-resume\n", self.text)
        self.assertEqual(self.text.count("runs-on:"), 2)
        self.assertEqual(self.text.count("if: github.ref == 'refs/heads/main'"), 2)

    def test_environment_protection_is_verified_before_the_gated_job(self):
        verify, resume = self.text.split("\n  resume:\n")
        self.assertNotIn("\n    environment:", verify)
        self.assertIn('"repos/$GITHUB_REPOSITORY/environments/factory-resume" >', verify)
        self.assertIn("scripts/check-release-environment.py", verify)
        self.assertIn("--reviewer sspeaks", verify)
        self.assertNotIn("continue-on-error", self.text)
        self.assertIn("\n    needs: verify\n", "\n" + resume)
        self.assertNotIn("always()", self.text)

    def test_jobs_hold_only_the_permissions_they_need(self):
        self.assertIn("\npermissions: {}\n", self.text)
        self.assertIn("    permissions:\n      actions: read\n      contents: read\n\n", self.text)
        self.assertIn("    permissions:\n      actions: read\n      issues: write\n\n", self.text)
        self.assertNotIn("secrets.", self.text)


if __name__ == "__main__":
    unittest.main()
