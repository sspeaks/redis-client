import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path


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
        self.added = []
        self.removed = []

    def closed_issues(self):
        yield from self.issues

    def add_labels(self, issue_number, labels):
        self.added.append((issue_number, labels))

    def remove_label(self, issue_number, label):
        self.removed.append((issue_number, label))


class IssueStatusTransitionTests(unittest.TestCase):
    def test_direct_close_removes_all_active_statuses(self):
        plan = MODULE.plan_transition(
            issue(
                10,
                [
                    "status:ready",
                    "status:in-progress",
                    "status:needs-review",
                    "squad:lead",
                    "priority:p2",
                ],
            ),
            "closed",
        )
        self.assertEqual(
            plan,
            {
                "add": [],
                "remove": [
                    "status:in-progress",
                    "status:needs-review",
                    "status:ready",
                ],
            },
        )

    def test_merge_driven_close_uses_the_same_terminal_transition(self):
        merged_pr_close = issue(
            11,
            ["status:needs-review", "type:maintenance", "wave:2"],
            closed_by={"login": "merge-bot"},
        )
        self.assertEqual(
            MODULE.plan_transition(merged_pr_close, "closed"),
            {"add": [], "remove": ["status:needs-review"]},
        )

    def test_reopen_with_owner_restores_ready(self):
        plan = MODULE.plan_transition(
            issue(12, ["squad:tester", "priority:p1", "status:needs-review"]),
            "reopened",
        )
        self.assertEqual(
            plan,
            {"add": ["status:ready"], "remove": ["status:needs-review"]},
        )

    def test_reopen_without_owner_is_clearly_untriaged(self):
        plan = MODULE.plan_transition(
            issue(13, ["squad", "priority:p2", "status:in-progress"]),
            "reopened",
        )
        self.assertEqual(
            plan,
            {"add": [], "remove": ["status:in-progress"]},
        )

    def test_reopen_without_owner_enters_the_triage_inbox(self):
        plan = MODULE.plan_transition(
            issue(14, ["priority:p2", "type:maintenance"]),
            "reopened",
        )
        self.assertEqual(plan, {"add": ["squad"], "remove": []})

    def test_transition_is_idempotent(self):
        closed = issue(15, ["squad:lead", "priority:p2"])
        reopened = issue(15, ["squad:lead", "priority:p2", "status:ready"])
        self.assertEqual(
            MODULE.plan_transition(closed, "closed"),
            {"add": [], "remove": []},
        )
        self.assertEqual(
            MODULE.plan_transition(reopened, "reopened"),
            {"add": [], "remove": []},
        )

    def test_apply_preserves_non_status_labels(self):
        client = FakeClient()
        source_issue = issue(
            16,
            [
                "status:in-progress",
                "status:blocked",
                "squad:lead",
                "priority:p2",
                "type:maintenance",
                "wave:2",
                "retro-action",
            ],
        )
        plan = MODULE.plan_transition(source_issue, "closed")
        with redirect_stdout(io.StringIO()):
            MODULE.apply_plan(
                client, source_issue, "closed", plan, dry_run=False
            )
        self.assertEqual(client.added, [])
        self.assertEqual(client.removed, [(16, "status:in-progress")])

    def test_reconciliation_dry_run_makes_no_mutations(self):
        client = FakeClient(
            [
                issue(17, ["status:ready", "squad:lead", "priority:p2"]),
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
            '"mode": "dry-run", "remove": ["status:ready"]}',
        )


if __name__ == "__main__":
    unittest.main()
