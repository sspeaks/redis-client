import importlib.util
import io
import os
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("github_issue_status.py")
SPEC = importlib.util.spec_from_file_location("github_issue_status", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def issue(number, labels, **extra):
    return {
        "number": number,
        "labels": [{"name": label} for label in labels],
        **extra,
    }


class FakeClient:
    def __init__(self, issues=()):
        self.issues = list(issues)
        self.issue_by_number = {
            current_issue["number"]: current_issue
            for current_issue in self.issues
        }
        self.added = []
        self.removed = []

    def closed_issues(self):
        yield from self.issues

    def get_issue(self, issue_number):
        return self.issue_by_number[issue_number]

    def add_labels(self, issue_number, labels):
        self.added.append((issue_number, labels))
        current_labels = self.issue_by_number[issue_number]["labels"]
        existing = {
            label["name"] if isinstance(label, dict) else label
            for label in current_labels
        }
        current_labels.extend(
            {"name": label} for label in labels if label not in existing
        )

    def remove_label(self, issue_number, label):
        current_labels = self.issue_by_number[issue_number]["labels"]
        remaining = [
            current_label
            for current_label in current_labels
            if (
                current_label["name"]
                if isinstance(current_label, dict)
                else current_label
            )
            != label
        ]
        if len(remaining) == len(current_labels):
            raise AssertionError(f"label already absent: {label}")
        self.issue_by_number[issue_number]["labels"] = remaining
        self.removed.append((issue_number, label))


class IssueStatusTransitionTests(unittest.TestCase):
    def test_direct_close_clears_only_needs_triage(self):
        self.assertEqual(
            MODULE.plan_transition(
                issue(10, ["needs-triage", "type:maintenance", "priority:p2"]),
                "closed",
            ),
            {"add": [], "remove": ["needs-triage"]},
        )

    def test_merge_driven_close_uses_the_same_terminal_transition(self):
        merged_pr_close = issue(
            11,
            ["needs-triage", "type:maintenance", "wave:2"],
            closed_by={"login": "merge-bot"},
        )
        self.assertEqual(
            MODULE.plan_transition(merged_pr_close, "closed"),
            {"add": [], "remove": ["needs-triage"]},
        )

    def test_labels_outside_the_triage_vocabulary_are_untouched(self):
        labels = ["status:ready", "status:in-progress", "status:needs-review"]
        self.assertEqual(
            MODULE.plan_transition(issue(12, labels), "closed"),
            {"add": [], "remove": []},
        )
        self.assertEqual(
            MODULE.plan_transition(issue(12, labels), "reopened"),
            {"add": ["needs-triage"], "remove": []},
        )

    def test_reopen_leaves_exactly_one_triage_state(self):
        for label in (
            "needs-info",
            "ready-for-agent",
            "ready-for-human",
            "wontfix",
        ):
            with self.subTest(label=label):
                self.assertEqual(
                    MODULE.plan_transition(issue(13, [label]), "reopened"),
                    {"add": ["needs-triage"], "remove": [label]},
                )

    def test_reopen_without_state_enters_the_triage_inbox(self):
        plan = MODULE.plan_transition(
            issue(14, ["priority:p2", "type:maintenance"]),
            "reopened",
        )
        self.assertEqual(plan, {"add": ["needs-triage"], "remove": []})

    def test_transition_is_idempotent(self):
        closed = issue(15, ["type:maintenance", "priority:p2"])
        reopened = issue(15, ["needs-triage", "priority:p2"])
        self.assertEqual(
            MODULE.plan_transition(closed, "closed"),
            {"add": [], "remove": []},
        )
        self.assertEqual(
            MODULE.plan_transition(reopened, "reopened"),
            {"add": [], "remove": []},
        )

    def test_apply_preserves_non_triage_labels(self):
        source_issue = issue(
            16,
            [
                "needs-triage",
                "priority:p2",
                "type:maintenance",
                "wave:2",
                "retro-action",
            ],
        )
        client = FakeClient([source_issue])
        plan = MODULE.plan_transition(source_issue, "closed")
        with redirect_stdout(io.StringIO()):
            MODULE.apply_plan(
                client, source_issue, "closed", plan, dry_run=False
            )
        self.assertEqual(client.added, [])
        self.assertEqual(client.removed, [(16, "needs-triage")])

    def test_replaying_stale_event_plan_does_not_repeat_deletion(self):
        source_issue = issue(
            19,
            ["needs-triage", "type:maintenance", "priority:p2"],
        )
        client = FakeClient([source_issue])
        stale_plan = MODULE.plan_transition(source_issue, "closed")

        with redirect_stdout(io.StringIO()):
            MODULE.apply_plan(
                client, source_issue, "closed", stale_plan, dry_run=False
            )
            MODULE.apply_plan(
                client, source_issue, "closed", stale_plan, dry_run=False
            )

        self.assertEqual(client.added, [])
        self.assertEqual(client.removed, [(19, "needs-triage")])
        self.assertEqual(
            MODULE.label_names(client.get_issue(19)),
            {"type:maintenance", "priority:p2"},
        )

    def apply_reopen(self, event_labels, current_labels, state="open"):
        event_issue = issue(20, event_labels, state="open")
        client = FakeClient([issue(20, current_labels, state=state)])
        plan = MODULE.plan_transition(event_issue, "reopened")
        with redirect_stdout(io.StringIO()):
            MODULE.apply_plan(
                client, event_issue, "reopened", plan, dry_run=False
            )
        return MODULE.label_names(client.get_issue(20))

    def test_reopen_replaces_stale_triage_states(self):
        labels = ["wontfix", "needs-info", "priority:p2"]
        self.assertEqual(
            self.apply_reopen(labels, labels),
            {"needs-triage", "priority:p2"},
        )

    def test_reopen_keeps_triage_state_set_after_the_event(self):
        for event_labels, current_labels in (
            ([], ["ready-for-agent"]),
            (["wontfix"], ["wontfix", "ready-for-agent"]),
            (["needs-triage"], ["needs-triage", "ready-for-agent"]),
        ):
            with self.subTest(event=event_labels):
                self.assertEqual(
                    self.apply_reopen(event_labels, current_labels),
                    {"ready-for-agent"},
                )

    def test_reopen_skips_issue_that_is_closed_again(self):
        self.assertEqual(
            self.apply_reopen(["wontfix"], ["wontfix"], state="closed"),
            {"wontfix"},
        )

    def test_close_and_reconciliation_clear_the_triage_inbox(self):
        labels = ["needs-triage", "wontfix", "priority:p2"]
        self.assertEqual(
            MODULE.plan_transition(issue(21, labels), "closed"),
            {"add": [], "remove": ["needs-triage"]},
        )
        client = FakeClient([issue(21, labels, state="closed")])
        with redirect_stdout(io.StringIO()):
            MODULE.reconcile(client, dry_run=False)
        self.assertEqual(client.removed, [(21, "needs-triage")])

    def test_reconciliation_dry_run_makes_no_mutations(self):
        client = FakeClient(
            [
                issue(17, ["needs-triage", "type:maintenance", "priority:p2"]),
                issue(18, ["priority:p1", "type:bug"]),
            ]
        )
        output = io.StringIO()
        with redirect_stdout(output):
            MODULE.reconcile(client, dry_run=True)
        self.assertEqual(client.added, [])
        self.assertEqual(client.removed, [])
        self.assertEqual(
            output.getvalue().strip(),
            '{"action": "closed", "add": [], "issue": 17, '
            '"mode": "dry-run", "remove": ["needs-triage"]}',
        )



class Server:
    """A local HTTP server that records the requests it receives."""

    def __init__(self, test, status=200, location=None):
        self.requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(handler):
                self.requests.append((handler.path, handler.headers.get("Authorization")))
                handler.send_response(status)
                if location:
                    handler.send_header("Location", location)
                handler.send_header("Content-Length", "2")
                handler.end_headers()
                handler.wfile.write(b"[]")

            def log_message(handler, *arguments):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{server.server_port}"
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        test.addCleanup(server.server_close)
        test.addCleanup(thread.join)
        test.addCleanup(server.shutdown)


class GitHubClientTests(unittest.TestCase):
    """The token never leaves the API host: no redirects, no proxies."""

    def use_api(self, server):
        patcher = mock.patch.object(MODULE.github_http, "API", server.url)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_requests_go_to_the_repository_with_the_token(self):
        api = Server(self)
        self.use_api(api)
        self.assertEqual(MODULE.GitHubClient("o/r", "secret").request("GET", "/issues/1"), [])
        self.assertEqual(api.requests, [("/repos/o/r/issues/1", "Bearer secret")])

    def test_redirects_are_refused_and_never_followed(self):
        for status in (301, 302, 307, 308):
            with self.subTest(status=status):
                other = Server(self)
                api = Server(self, status, other.url + "/steal")
                self.use_api(api)
                with self.assertRaises(RuntimeError):
                    MODULE.GitHubClient("o/r", "secret").request("GET", "/issues/1")
                self.assertEqual(other.requests, [])

    def test_environment_proxies_are_ignored(self):
        api, proxy = Server(self), Server(self)
        self.use_api(api)
        with mock.patch.dict(os.environ, {"http_proxy": proxy.url, "https_proxy": proxy.url,
                                          "all_proxy": proxy.url, "no_proxy": ""}):
            MODULE.GitHubClient("o/r", "secret").request("GET", "/issues/1")
        self.assertEqual(proxy.requests, [])
        self.assertEqual(len(api.requests), 1)


if __name__ == "__main__":
    unittest.main()
