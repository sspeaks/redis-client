import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-release-environment.py")
PROTECTED = {
    "name": "release",
    "can_admins_bypass": False,
    "protection_rules": [
        {
            "type": "required_reviewers",
            "prevent_self_review": False,
            "reviewers": [{"type": "User", "reviewer": {"login": "sspeaks"}}],
        }
    ],
}


MAIN_ONLY = {
    "total_count": 1,
    "branch_policies": [{"id": 1, "name": "main", "type": "branch"}],
}


class ReleaseEnvironmentTests(unittest.TestCase):
    def check(self, environment):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "environment.json"
            path.write_text(json.dumps(environment), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path), "--reviewer", "sspeaks"],
                capture_output=True,
                text=True,
            )

    def assert_rejected(self, environment, message):
        result = self.check(environment)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)

    def test_accepts_maintainer_review_without_admin_bypass(self):
        result = self.check(PROTECTED)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_admin_bypass(self):
        environment = copy.deepcopy(PROTECTED)
        environment["can_admins_bypass"] = True
        self.assert_rejected(environment, "bypass")

    def test_rejects_unreported_admin_bypass(self):
        environment = copy.deepcopy(PROTECTED)
        del environment["can_admins_bypass"]
        self.assert_rejected(environment, "bypass")

    def test_rejects_an_auto_created_environment(self):
        environment = copy.deepcopy(PROTECTED)
        environment["protection_rules"] = []
        self.assert_rejected(environment, "required reviewer")

    def test_rejects_any_reviewer_other_than_the_maintainer(self):
        for kind, reviewer in (
            ("User", {"login": "someone-else"}),
            ("Team", {"slug": "sspeaks"}),
        ):
            with self.subTest(kind=kind):
                environment = copy.deepcopy(PROTECTED)
                environment["protection_rules"][0]["reviewers"].append(
                    {"type": kind, "reviewer": reviewer}
                )
                self.assert_rejected(environment, "required reviewer")

    def test_rejects_a_gate_the_maintainer_cannot_approve(self):
        environment = copy.deepcopy(PROTECTED)
        environment["protection_rules"][0]["prevent_self_review"] = True
        self.assert_rejected(environment, "self-review")

    def test_errors_name_the_checked_environment(self):
        environment = copy.deepcopy(PROTECTED)
        environment["name"] = "factory-resume"
        environment["can_admins_bypass"] = True
        self.assert_rejected(environment, "factory-resume environment: ")

    def test_rejects_an_unexpected_response(self):
        self.assert_rejected({"message": "Not Found"}, "bypass")

    def check_branches(self, environment, policies):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("environment", "policies")]
            for path, content in zip(paths, (environment, policies)):
                path.write_text(json.dumps(content), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(paths[0]), "--reviewer", "sspeaks",
                 "--branch", "main", "--branch-policies", str(paths[1])],
                capture_output=True,
                text=True,
            )  # fmt: skip

    def limited(self, **policy):
        environment = copy.deepcopy(PROTECTED)
        environment["deployment_branch_policy"] = {
            "protected_branches": False,
            "custom_branch_policies": True,
            **policy,
        }
        return environment

    def test_accepts_only_the_named_branch(self):
        result = self.check_branches(self.limited(), MAIN_ONLY)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_branch_limit_does_not_replace_review(self):
        environment = self.limited()
        environment["can_admins_bypass"] = True
        self.assertEqual(self.check_branches(environment, MAIN_ONLY).returncode, 1)

    def test_rejects_unlimited_or_protected_branch_deployments(self):
        unlimited = copy.deepcopy(PROTECTED)
        unlimited["deployment_branch_policy"] = None
        for environment in (
            PROTECTED,
            unlimited,
            self.limited(protected_branches=True, custom_branch_policies=False),
        ):
            result = self.check_branches(environment, MAIN_ONLY)
            self.assertEqual(result.returncode, 1)
            self.assertIn("selected branches", result.stderr)

    def test_rejects_other_branches_tags_and_unexpected_answers(self):
        main = MAIN_ONLY["branch_policies"][0]
        for policies in (
            {"total_count": 2, "branch_policies": [main, dict(main, name="dev")]},
            {"total_count": 2, "branch_policies": [main]},
            {"total_count": 1, "branch_policies": [dict(main, type="tag")]},
            {"total_count": 1, "branch_policies": [dict(main, name="*")]},
            {"total_count": 1, "branch_policies": [{"name": "main"}]},
            {"total_count": 0, "branch_policies": []},
            {"message": "Not Found"},
        ):
            result = self.check_branches(self.limited(), policies)
            self.assertEqual(result.returncode, 1, policies)
            self.assertIn("main branch", result.stderr)

    def test_branch_arguments_go_together(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "environment.json"
            path.write_text(json.dumps(self.limited()), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(path), "--reviewer", "sspeaks",
                 "--branch", "main"],
                capture_output=True,
            )  # fmt: skip
            self.assertEqual(result.returncode, 2)


UNATTENDED = {
    "name": "factory-agent",
    "can_admins_bypass": False,
    "protection_rules": [{"type": "branch_policy"}],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}


class UnattendedEnvironmentTests(unittest.TestCase):
    """--no-reviewer: main only, no bypass, and nothing that waits for a person."""

    def check(self, environment, policies=MAIN_ONLY, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("environment", "policies")]
            for path, content in zip(paths, (environment, policies)):
                path.write_text(json.dumps(content), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(paths[0]), *(arguments or ("--no-reviewer",)),
                 "--branch", "main", "--branch-policies", str(paths[1])],
                capture_output=True, text=True,
            )  # fmt: skip

    def test_accepts_main_only_without_bypass_or_reviewer(self):
        result = self.check(UNATTENDED)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_anything_else(self):
        for change in (
            {"can_admins_bypass": True},
            {"can_admins_bypass": None},
            {"protection_rules": []},
            {"protection_rules": [{"type": "branch_policy"}, {"type": "wait_timer", "wait_timer": 1}]},
            {"protection_rules": PROTECTED["protection_rules"] + [{"type": "branch_policy"}]},
            {"deployment_branch_policy": None},
            {"deployment_branch_policy": {"protected_branches": True, "custom_branch_policies": False}},
        ):
            with self.subTest(change):
                self.assertEqual(self.check({**UNATTENDED, **change}).returncode, 1)
        for broken in ({"message": "Not Found"}, [], {"protection_rules": None}):
            self.assertEqual(self.check(broken).returncode, 1, broken)

    def test_rejects_other_branches(self):
        main = MAIN_ONLY["branch_policies"][0]
        for policies in ({"total_count": 1, "branch_policies": [dict(main, name="dev")]},
                         {"total_count": 0, "branch_policies": []}, {"message": "Not Found"}):
            self.assertEqual(self.check(UNATTENDED, policies).returncode, 1, policies)

    def run_raw(self, environment, policies, *arguments):
        """Like check, but with raw file contents and extra arguments."""
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("environment", "policies")]
            for path, content in zip(paths, (environment, policies)):
                text = content if isinstance(content, str) else json.dumps(content)
                path.write_text(text, encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-I", str(SCRIPT), str(paths[0]), "--no-reviewer",
                 "--branch", "main", "--branch-policies", str(paths[1]), *arguments],
                capture_output=True, text=True,
            )  # fmt: skip

    def test_the_named_environment_is_required(self):
        publish = {**UNATTENDED, "name": "factory-publish"}
        self.assertEqual(self.run_raw(publish, MAIN_ONLY, "--name", "factory-publish").returncode, 0)
        for environment in ({**UNATTENDED, "name": "other"}, {k: v for k, v in publish.items() if k != "name"}):
            result = self.run_raw(environment, MAIN_ONLY, "--name", "factory-publish")
            self.assertEqual(result.returncode, 1, environment)
            self.assertIn("factory-publish environment: is not the expected environment", result.stderr)

    def test_every_missing_field_fails(self):
        for key in UNATTENDED:
            if key == "name":
                continue
            missing = {k: v for k, v in UNATTENDED.items() if k != key}
            self.assertEqual(self.run_raw(missing, MAIN_ONLY).returncode, 1, key)

    def test_unreadable_or_truncated_answers_fail(self):
        main = MAIN_ONLY["branch_policies"][0]
        for policies in (
            {}, [], "", "{", "null",
            {"total_count": 2, "branch_policies": [main]},
            {"total_count": 2, "branch_policies": [main, {"name": "*", "type": "branch"}]},
            {"total_count": 1, "branch_policies": [{"name": "main", "type": "tag"}]},
            {"total_count": 1, "branch_policies": [{"name": "main"}]},
            {"total_count": 1, "branch_policies": [{"name": "main*", "type": "branch"}]},
            {"total_count": True, "branch_policies": [main]},
            {"total_count": 1, "branch_policies": None},
            {"total_count": 1, "branch_policies": ["main"]},
        ):
            with self.subTest(policies=policies):
                result = self.run_raw(UNATTENDED, policies)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        for environment in ("", "{", "null", "[]", {"protection_rules": [None]}):
            with self.subTest(environment=environment):
                result = self.run_raw(environment, MAIN_ONLY)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_needs_the_branch_and_exactly_one_mode(self):
        for arguments in (("--no-reviewer", "--reviewer", "sspeaks"),):
            self.assertEqual(self.check(UNATTENDED, MAIN_ONLY, *arguments).returncode, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "environment.json"
            path.write_text(json.dumps(UNATTENDED), encoding="utf-8")
            for arguments in (["--no-reviewer"], []):
                result = subprocess.run([sys.executable, str(SCRIPT), str(path), *arguments],
                                        capture_output=True)
                self.assertEqual(result.returncode, 2, arguments)


if __name__ == "__main__":
    unittest.main()
