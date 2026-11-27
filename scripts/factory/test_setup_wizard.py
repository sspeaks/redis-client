import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / "testdata")]

import fake_github  # noqa: E402
import gate  # noqa: E402
import negative_test  # noqa: E402
import publish  # noqa: E402
import setup_github  # noqa: E402
import setup_steps  # noqa: E402
from fake_github import NOW, FakeGitHub, ready  # noqa: E402
from setup_github import Answer, check  # noqa: E402

SUBSCRIPTION = "sk-ant-" + "oat01-" + "dummydummy" * 9 + "ab"
PUBLISH = "github_" + "pat_" + "dummydummy" * 2 + "ab_" + "dummydummy" * 5 + "abcdefghi"
EXPIRY = {"github-authentication-token-expiration": "2027"}
YES = ("Type yes", "yes")


def by_token(fake):
    return [entry for entry in fake.state["log"] if entry[0] == "token"]


class NegativeTest(unittest.TestCase):
    def prove(self, *powers, **changes):
        self.fake = FakeGitHub({**ready(), "powers": list(powers), **changes})
        self.fake.workflow("admin", "factory-resume", "dispatches")
        self.waiting = setup_github.waiting_resume(self.fake.admin)
        return negative_test.prove(
            self.fake.admin, self.fake.token, self.waiting, "abc", settle=0
        )

    def assert_clean(self):
        self.assertEqual(self.fake.state["refs"], {"refs/heads/main": "c0"})
        self.assertEqual(sorted(self.fake.state["rulesets"]), ["1", "2"])

    def test_a_correct_token_passes_and_leaves_nothing(self):
        self.assertEqual(self.prove(), ([], []))
        self.assert_clean()
        self.assertEqual(setup_github.waiting_resume(self.fake.admin), self.waiting)
        tried = [path for _, _, path, _ in by_token(self.fake)]
        for wanted in ("pending_deployments", "/rulesets/", "/contents/.github/workflows/",
                       "/deployments"):
            self.assertTrue(any(wanted in path for path in tried), wanted)

    def test_each_power_is_caught_and_does_no_lasting_harm(self):
        for power, word in (
            ("workflows-push", "workflow file"),
            ("workflows-write", "workflow file"),
            ("approve", "pending environment"),
            ("workflows", "workflow file"),
            ("rules", "main's rules"),
            ("tags", "tag"),
            ("administration", "ruleset"),
            ("deployments", "Deployments"),
        ):
            with self.subTest(power):
                problems, _ = self.prove(power)
                self.assertTrue(any(word in problem for problem in problems), problems)
                self.assert_clean()

    def test_a_not_found_answer_is_left_for_the_maintainer(self):
        self.assertEqual(
            self.prove("actions", "variables"), ([], ["no Variables: write", "no Actions: write"])
        )

    def test_an_approving_token_is_given_nothing_else_to_do(self):
        self.prove("approve", "workflows", "rules", "tags")
        self.assertEqual(len(by_token(self.fake)), 1)

    def test_a_malformed_write_is_not_taken_for_a_refusal(self):
        problems, _ = self.prove(denied=["contents"])
        self.assertTrue(any("control failed" in problem for problem in problems), problems)
        self.assert_clean()

    def altered(self, change, **changes):
        """prove(), with change(method, path, answer, fake) applied to the token's answers."""
        fake = self.fake = FakeGitHub({**ready(), **changes})
        fake.workflow("admin", "factory-resume", "dispatches")

        def token(method, path, body=None):
            answer = fake.token(method, path, body)
            return change(method, path, answer, fake) or answer

        waiting = setup_github.waiting_resume(fake.admin)
        return negative_test.prove(fake.admin, token, waiting, "abc", settle=0)

    def lucky(self, power, first):
        """A token with `power` whose first answer to paths with `first` is a refusal."""
        seen = []

        def change(method, path, answer, fake):
            if method != "GET" and first in path and not seen:
                seen.append(path)
                return Answer(*fake_github.DENIED, EXPIRY)
            return None

        return self.altered(change, powers=[power])

    def test_one_lucky_refusal_proves_nothing(self):
        for power, first in (
            ("rules", "/git/refs/heads/factory-negative-test/abc/control"),
            ("approve", "pending_deployments"),
            ("actions", "/dispatches"), ("variables", "/actions/variables/"),
            ("secrets", "/actions/secrets/"), ("tags", "/git/refs"),
        ):
            with self.subTest(power):
                problems, _ = self.lucky(power, first)
                self.assertTrue(problems)
                self.assert_clean()

    def test_inconsistent_refusals_are_reported_as_not_proved(self):
        for target in ("/actions/variables/", "/actions/secrets/", "/dispatches", "pending_deployments"):
            seen = []

            def change(method, path, answer, fake, target=target):
                if method != "GET" and target in path:
                    seen.append(path)
                    return Answer(500) if len(seen) == 2 else None
                return None

            problems, _ = self.altered(change)
            self.assertTrue(any("NOT PROVED" in problem for problem in problems), (target, problems))
            self.assert_clean()

    def test_refusals_that_differ_are_reported_as_not_proved(self):
        # The token's real answer to deleting a ruleset is fake_github.DENIED.
        for first in (Answer(404, {"message": "Not Found"}, EXPIRY),
                      Answer(403, {"message": "Must have admin rights"}, EXPIRY)):
            seen = []

            def change(method, path, answer, fake, first=first):
                if method == "DELETE" and "/rulesets/" in path:
                    seen.append(path)
                    return first if len(seen) == 1 else None
                return None

            with self.subTest(first=first.body):
                problems, _ = self.altered(change)
                self.assertEqual(len(seen), 2)
                self.assertTrue(any("NOT PROVED: deleting a ruleset" in problem
                                    for problem in problems), problems)
                self.assert_clean()

    def test_a_push_refusal_must_name_the_rules(self):
        def change(method, path, answer, fake):
            if answer.status == 422 and "/control" in path:
                return Answer(422, {"message": "Unprocessable"}, EXPIRY)
            return None

        problems, _ = self.altered(change)
        self.assertTrue(any("main's rules" in problem for problem in problems), problems)
        self.assert_clean()

    def test_a_dead_token_or_an_outage_is_not_taken_for_refusals(self):
        for status in (403, 404, 422, 401, 500):
            started = []

            def change(method, path, answer, fake, status=status):
                if "/rulesets/" in path:
                    started.append(1)
                return Answer(status, fake_github.DENIED[1], EXPIRY) if started else None

            problems, _ = self.altered(change)
            self.assertTrue(problems, status)
            self.assert_clean()

    def test_the_same_push_must_work_once_the_rules_are_gone(self):
        def change(method, path, answer, fake):
            if method == "PATCH" and [e for e in fake.state["log"] if e[1] == "POST" and "/rulesets" in e[2]]:
                return Answer(422)
            return None

        problems, _ = self.altered(change)
        self.assertTrue(problems)
        self.assert_clean()

    def test_a_refusal_the_maintainer_shares_proves_nothing(self):
        for path, word in (("/deployments", "Deployments"), ("pending_deployments", "pending")):
            fake = self.fake = FakeGitHub()
            fake.workflow("admin", "factory-resume", "dispatches")

            def admin(method, target, body=None, path=path, fake=fake):
                if method == "POST" and target.endswith(path):
                    return Answer(*fake_github.DENIED)
                return fake.admin(method, target, body)

            waiting = setup_github.waiting_resume(fake.admin)
            problems, _ = negative_test.prove(admin, fake.token, waiting, "abc", settle=0)
            self.assertTrue(any(word in problem for problem in problems), problems)
            self.assert_clean()

    def test_a_run_the_maintainer_cannot_approve_is_not_used(self):
        fake = FakeGitHub({**ready(), "can_approve": False})
        fake.workflow("admin", "factory-resume", "dispatches")
        self.assertIsNone(setup_github.waiting_resume(fake.admin))

    def test_validation_before_permission_leaves_write_access_unproved(self):
        def change(method, path, answer, fake):
            return Answer(404) if path.endswith("/deployments") else None

        problems, unproved = self.altered(change)
        self.assertEqual(problems, [])
        self.assertIn("has Issues: write", unproved)
        self.assertIn("no Deployments: write", unproved)

    def test_further_signals_do_not_stop_the_cleanup(self):
        for sent in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            fake = self.fake = FakeGitHub()
            fake.workflow("admin", "factory-resume", "dispatches")
            handlers = [signal.getsignal(s) for s in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)]

            def token(method, path, body=None, fake=fake, sent=sent):
                if method == "PUT":
                    os.kill(os.getpid(), sent)
                return fake.token(method, path, body)

            def admin(method, path, body=None, fake=fake, sent=sent):
                if method == "DELETE":
                    os.kill(os.getpid(), sent)
                return fake.admin(method, path, body)

            waiting = setup_github.waiting_resume(fake.admin)
            with self.assertRaises(KeyboardInterrupt):
                negative_test.prove(admin, token, waiting, "abc", settle=0)
            self.assert_clean()
            self.assertEqual(
                [signal.getsignal(s) for s in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)], handlers
            )

    def test_a_write_that_lands_during_cleanup_is_removed(self):
        self.fake = FakeGitHub()
        late = ["refs/heads/factory-negative-test/late/x"]

        def admin(method, path, body=None):
            answer = self.fake.admin(method, path, body)
            if method == "GET" and "/tags/" in path and late:
                name = late.pop(0)
                if name:
                    self.fake.state["refs"][name] = "c0"
            return answer

        self.assertEqual(negative_test.cleanup(admin, self.fake.token, settle=0), [])
        self.assert_clean()

    def test_a_rate_limit_is_not_taken_for_a_refusal(self):
        problems, _ = self.prove(headers={**EXPIRY, "retry-after": "1"})
        self.assertTrue(any("main's rules" in problem for problem in problems))
        self.assert_clean()

    def test_classic_or_unlimited_tokens_never_start(self):
        for headers in ({}, {**EXPIRY, "x-oauth-scopes": ""}):
            self.assertTrue(self.prove(headers=headers)[0])
            self.assertEqual(by_token(self.fake), [])

    def test_unblocked_tags_stop_it_first(self):
        problems, _ = self.prove(rulesets={"2": ready()["rulesets"]["2"]})
        self.assertTrue(any("tag ruleset" in problem for problem in problems))
        self.assertEqual(by_token(self.fake), [])

    def test_an_interrupt_still_cleans_up(self):
        self.fake = FakeGitHub()
        self.fake.workflow("admin", "factory-resume", "dispatches")

        def token(method, path, body=None):
            if method == "PUT":
                raise KeyboardInterrupt
            return self.fake.token(method, path, body)

        waiting = setup_github.waiting_resume(self.fake.admin)
        with self.assertRaises(KeyboardInterrupt):
            negative_test.prove(self.fake.admin, token, waiting, "abc", settle=0)
        self.assert_clean()

    def test_cleanup_reports_a_stuck_tag_and_touches_only_its_own_names(self):
        fake = FakeGitHub()
        fake.state["refs"].update({
            "refs/tags/factory-negative-test-x": "c0",
            "refs/heads/factory-negative-testing": "c0",
        })
        problems = negative_test.cleanup(fake.admin, settle=0)
        self.assertEqual(len(problems), 1)
        self.assertIn("turn the tag ruleset off", problems[0])
        self.assertIn("refs/heads/factory-negative-testing", fake.state["refs"])


class GateTokenTest(unittest.TestCase):
    @staticmethod
    def api(changes, read=200):
        def answer(method, path, body=None):
            if path == "/user":
                return Answer(200, {"login": "sspeaks"}, EXPIRY)
            if method == "GET":
                return Answer(read, [])
            for part, status in changes.items():
                if part in path:
                    return Answer(status)
            return Answer(*fake_github.DENIED)

        return answer

    def test_any_write_access_is_refused(self):
        def problems(token):
            return setup_steps.gate_token_problems(FakeGitHub().admin, token)

        public = ["has Actions: read", "has Issues: read", "has Contents: read"]
        self.assertEqual(problems(self.api({})), ([], public))
        for part in ("/issues", "/pulls", "/git/refs", "/variables/", "/deployments"):
            self.assertEqual(len(problems(self.api({part: 422}))[0]), 1, part)
        self.assertEqual(problems(self.api({"/variables/": 404})), ([], ["no Variables: write", *public]))

    def test_it_must_read_what_the_gate_reads(self):
        found = setup_steps.gate_token_problems(FakeGitHub().admin, self.api({}, read=403))[0]
        self.assertEqual(len(found), 4)


class ChecksTest(unittest.TestCase):
    def problems(self, function, *arguments, **changes):
        return check(function, FakeGitHub({**ready(), **changes}).admin, *arguments)

    def test_ready_settings_pass(self):
        for function in (
            setup_github.preflight, setup_github.workflows_on_main, setup_github.switch_off,
            setup_github.tag_ruleset, setup_github.main_ruleset, setup_github.secret_copies,
            setup_github.fork_approval,
        ):
            self.assertEqual(self.problems(function), [], function.__name__)
        for environment in ready()["environments"]:
            name = environment["name"]
            self.assertEqual(self.problems(setup_github.environment, name), [], name)

    def test_weak_or_missing_environments_fail(self):
        environments = ready()["environments"]
        for environment in environments:
            name = environment["name"]
            for changed in (
                [],
                [{**e, "can_admins_bypass": True} for e in environments],
                [{**e, "protection_rules": []} for e in environments],
            ):
                self.assertTrue(
                    self.problems(setup_github.environment, name, environments=changed), name
                )
            any_branch = [{**e, "deployment_branch_policy": None} for e in environments]
            found = self.problems(setup_github.environment, name, environments=any_branch)
            self.assertEqual(bool(found), name != "release")

    def test_rulesets_must_be_complete_and_without_bypass(self):
        for identity, function in (
            ("1", setup_github.tag_ruleset), ("2", setup_github.main_ruleset),
        ):
            for change in (
                {"bypass_actors": [{"actor_id": 5}]},
                {"bypass_actors": None},
                {"enforcement": "disabled"},
                {"rules": []},
                {"conditions": {"ref_name": {"include": ["release-*"], "exclude": []}}},
            ):
                rulesets = ready()["rulesets"]
                rulesets[identity].update(change)
                self.assertTrue(self.problems(function, rulesets=rulesets), change)
            rulesets = ready()["rulesets"]
            del rulesets[identity]["bypass_actors"]
            self.assertTrue(self.problems(function, rulesets=rulesets))

    def test_every_ruleset_covering_main_counts(self):
        extra = fake_github.ruleset(3, "more", "branch", "refs/heads/ma*", [{"type": "update"}])
        rulesets = {**ready()["rulesets"], "3": extra}
        self.assertEqual(self.problems(setup_github.main_ruleset, rulesets=rulesets), [])
        for name, value in (("bypass_actors", [{"actor_id": 5}]), ("bypass_actors", None)):
            changed = {**rulesets, "3": {**extra, name: value}}
            self.assertTrue(self.problems(setup_github.main_ruleset, rulesets=changed))

    def test_main_must_stay_mergeable_by_one_person(self):
        self.assertEqual(self.problems(setup_github.main_mergeable), [])
        for key, value in (
            ("required_approving_review_count", 1), ("require_code_owner_review", True),
            ("require_last_push_approval", True), ("required_reviewers", [{"x": 1}]),
            ("require_extra_approval_for_unattributed_changes", True),
            ("required_approving_review_count", None),
        ):
            rulesets = ready()["rulesets"]
            rule = {"type": "pull_request", "parameters": {**fake_github.RULES[2]["parameters"], key: value}}
            rulesets["3"] = fake_github.ruleset(3, "more", "branch", "refs/heads/ma*", [rule])
            self.assertTrue(self.problems(setup_github.main_mergeable, rulesets=rulesets), key)
        for changes in (
            {"checks": []},
            {"checks": [{"name": "build", "app": {"id": 99}, "conclusion": "success"}]},
            {"checks": [{"name": "build", "app": {"id": 15368}, "conclusion": "failure"}]},
            {"merge": {"allow_merge_commit": False, "allow_squash_merge": False, "allow_rebase_merge": False}},
        ):
            self.assertTrue(self.problems(setup_github.main_mergeable, **changes), changes)
        for change in (
            {"integration_id": 99}, {"integration_id": None},
        ):
            rulesets = ready()["rulesets"]
            rule = rulesets["2"]["rules"][3]["parameters"]["required_status_checks"][0]
            rule.update(change)
            if change["integration_id"] is None:
                del rule["integration_id"]
            self.assertTrue(self.problems(setup_github.main_mergeable, rulesets=rulesets), change)
        for methods in (["squash"], [], None):
            rulesets = ready()["rulesets"]
            rulesets["2"]["rules"][2]["parameters"]["allowed_merge_methods"] = methods
            self.assertTrue(self.problems(setup_github.main_mergeable, rulesets=rulesets), methods)
        rulesets = ready()["rulesets"]
        rulesets["2"]["rules"] = [*rulesets["2"]["rules"], {"type": "required_linear_history"}]
        self.assertTrue(self.problems(setup_github.main_mergeable, rulesets=rulesets))
        reviews = {"required_pull_request_reviews": {"required_approving_review_count": 1}}
        self.assertTrue(self.problems(setup_github.main_mergeable, protection=reviews))

    def test_the_checkout_must_be_a_clean_main_as_on_github(self):
        for changes, good in (
            ({}, True), ({"head": "c9"}, False), ({"branch": "refs/heads/x"}, False),
            ({"dirty": "?? scripts/factory/json.py"}, False),
        ):
            terminal = Terminal(self, {**ready(), **changes})
            self.assertEqual(terminal.steps("check", "checkout")[0] == 0, good, changes)

    def test_token_copies_anywhere_else_fail(self):
        for place in ("actions", "dependabot", "agents", "codespaces", "factory-resume"):
            for name in ("FACTORY_PUBLISH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"):
                secrets = {place: {name: NOW}}
                self.assertTrue(self.problems(setup_github.secret_copies, secrets=secrets))
        secrets = {
            "actions": {"FACTORY_GATE_TOKEN": NOW},
            "factory-model": {"CLAUDE_CODE_OAUTH_TOKEN": NOW},
        }
        self.assertEqual(self.problems(setup_github.secret_copies, secrets=secrets), [])

    def test_fork_workflows_need_approval(self):
        for policy in ("first_time_contributors", None):
            self.assertTrue(self.problems(setup_github.fork_approval, forks=policy))

    def test_the_agent_environment_waits_for_no_one(self):
        environments = [e for e in ready()["environments"] if e["name"] != "factory-agent"]
        for changed in (
            environments,
            [*environments, fake_github.environment("factory-agent", fake_github.REVIEW)],
            [*environments, {**fake_github.environment("factory-agent"), "can_admins_bypass": True}],
            [*environments, fake_github.environment("factory-agent", limited=False)],
        ):
            self.assertTrue(self.problems(setup_github.environment, "factory-agent", environments=changed))

    def test_each_environment_is_checked_as_its_workflow_checks_it(self):
        commands = []
        real = subprocess.run

        def run(command, **options):
            commands.append([str(part) for part in command[2:]])
            return real(command, **options)

        with mock.patch.object(setup_github.subprocess, "run", run):
            for name in ("factory-agent", "factory-publish", "factory-resume"):
                self.assertEqual(self.problems(setup_github.environment, name), [], name)
        checker = str(setup_github.RELEASE_CHECKER)
        self.assertEqual(commands[0][0], checker)
        self.assertEqual(commands[0][2:5], ["--no-reviewer", "--branch", "main"])
        self.assertEqual(commands[1][0], checker)
        self.assertEqual(commands[1][2:5], ["--name", "factory-publish", "--no-reviewer"])
        self.assertEqual(commands[2][2:4], ["--reviewer", "sspeaks"])

    def test_each_subscription_token_has_its_own_environment(self):
        both = {place: {"CLAUDE_CODE_OAUTH_TOKEN": NOW} for place in ("factory-model", "factory-agent")}
        self.assertEqual(self.problems(setup_github.secret_copies, secrets=both), [])
        for kind, place in (("subscription", "factory-model"), ("agent", "factory-agent")):
            self.assertEqual(self.problems(setup_github.secret_missing, kind, secrets=both), [])
            alone = {place: {"CLAUDE_CODE_OAUTH_TOKEN": NOW}}
            self.assertEqual(self.problems(setup_github.secret_missing, kind, secrets=alone), [])
            other = {p: v for p, v in both.items() if p != place}
            self.assertTrue(self.problems(setup_github.secret_missing, kind, secrets=other))

    def test_the_usage_credits_variable_must_be_exact(self):
        self.assertEqual(self.problems(setup_github.usage_credits), [])
        for value in (None, "checked and off ", "Checked and off", "checked", ""):
            variables = {} if value is None else {"FACTORY_USAGE_CREDITS": value}
            self.assertTrue(self.problems(setup_github.usage_credits, variables=variables), value)

    def test_only_an_unset_or_off_switch_passes(self):
        self.assertTrue(self.problems(setup_github.switch_off, variable="true"))
        self.assertEqual(self.problems(setup_github.switch_off, variable="false"), [])
        for value in ("True", "FALSE", "false ", "0", "off", "x"):
            self.assertTrue(self.problems(setup_github.switch_off, variable=value), value)
        self.assertTrue(check(setup_github.switch_off, lambda *_: Answer(500)))

    def test_unreadable_answers_are_problems(self):
        extra = {"environment": ("release",), "missing": ("gate",)}
        for name, function in setup_steps.CHECKS.items():
            found = check(function, lambda *_: Answer(200, {}), *extra.get(name, ()))
            self.assertTrue(found, name)

    def test_setup_test_records(self):
        run = {"id": 1, "status": "completed"}
        good = [
            {"name": "observe", "conclusion": "success",
             "steps": [{"name": gate.PAUSE_FAILED_STEP, "conclusion": "skipped"}]},
            {"name": "call-failed / factory-pause", "conclusion": "failure"},
            {"name": "call-skipped", "conclusion": "skipped"},
        ]
        function = setup_github.setup_test
        self.assertEqual(self.problems(function, run, jobs=good), [])
        self.assertTrue(self.problems(function, {**run, "status": "queued"}, jobs=good))
        for index, change in (
            (0, {"steps": []}),
            (0, {"conclusion": "failure"}),
            (1, {"name": "factory-pause"}),
            (1, {"conclusion": "skipped"}),
            (2, {"name": "call-skipped / factory-pause"}),
            (2, {"conclusion": "success"}),
        ):
            jobs = [dict(job) for job in good]
            jobs[index].update(change)
            self.assertTrue(self.problems(function, run, jobs=jobs), change)

    def test_the_setup_test_workflow_matches_the_gate_and_cannot_pause(self):
        workflow = HERE.parents[1] / ".github/workflows/factory-setup-test.yml"
        text = workflow.read_text(encoding="utf-8")
        self.assertNotIn("setup-test", publish.PAUSE_REASONS)
        self.assertEqual(re.findall(r"reason: (\S+)", text), ["setup-test"] * 2)
        self.assertIn(
            f"- name: {gate.PAUSE_FAILED_STEP}\n        if: github.event_name == 'never'", text
        )
        self.assertNotIn("secrets", text)


class Terminal:
    """Runs a command on a terminal with a fake `gh` and browser, answering prompts."""

    def __init__(self, case, state):
        directory = tempfile.TemporaryDirectory()
        case.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps(state))
        fake = HERE / "testdata" / "fake_github.py"
        self.program("gh", f"exec '{sys.executable}' '{fake}' \"$@\"")
        self.program("python3", f"exec '{sys.executable}' \"$@\"")
        self.program("git", f"exec '{sys.executable}' '{fake}' git \"$@\"")
        for name in ("open", "xdg-open", "wslview", "explorer.exe"):
            self.program(name, "exit 0")
        self.environment = {
            "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "TERM": "dumb",
            "FAKE_GH_STATE": str(self.state),
            "GH_DEBUG": "api",
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def program(self, name, text):
        path = self.root / name
        path.write_text(f"#!/bin/sh\n{text}\n")
        path.chmod(0o755)

    def run(self, command, answers, timeout=60):
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execvpe(command[0], command, self.environment)
        output, position, answers = "", 0, list(answers)
        deadline = time.monotonic() + timeout
        try:
            while True:
                if time.monotonic() > deadline:
                    os.kill(pid, signal.SIGKILL)
                    raise AssertionError(f"waiting for {answers[:1]}:\n{output[-2000:]}")
                if not select.select([master], [], [], 0.2)[0]:
                    continue
                try:
                    data = os.read(master, 65536)
                except OSError:  # Linux reports the end this way.
                    data = b""
                if not data:
                    break
                output += data.decode(errors="replace")
                found = answers and re.search(answers[0][0], output[position:])
                if found:
                    position += found.end()
                    os.write(master, (answers.pop(0)[1] + "\n").encode())
        finally:
            os.close(master)
            status = os.waitpid(pid, 0)[1]
        return os.waitstatus_to_exitcode(status), output, answers

    def steps(self, *arguments, answers=()):
        command = [sys.executable, "-I", str(HERE / "setup_steps.py"), *arguments]
        return self.run(command, answers)

    def wizard(self, *arguments, answers=()):
        return self.run(["bash", str(HERE / "setup-wizard.sh"), *arguments], answers)

    def read(self):
        return json.loads(self.state.read_text())


class StepsTest(unittest.TestCase):
    def test_subscription_token_reaches_only_gh_stdin(self):
        terminal = Terminal(self, ready())
        status, output, left = terminal.steps(
            "token", "subscription", answers=[YES, YES, ("hidden", SUBSCRIPTION), YES, YES]
        )
        state = terminal.read()
        self.assertEqual((status, left), (0, []), output)
        self.assertEqual(state["stored"], {"factory-model/CLAUDE_CODE_OAUTH_TOKEN": SUBSCRIPTION})
        self.assertNotIn("dummydummy", output)
        self.assertNotIn("dummydummy", json.dumps(state["argv"]))
        self.assertEqual(state["leaks"], [])
        for path in terminal.root.rglob("*"):
            if path.is_file() and path != terminal.state:
                self.assertNotIn(b"dummydummy", path.read_bytes(), path)

    def test_declining_anywhere_changes_nothing(self):
        script = [YES, YES, ("hidden", SUBSCRIPTION), YES]
        for index in (0, 1, 3):
            terminal = Terminal(self, ready())
            answers = [*script[:index], ("Type yes", "y")]
            status, _, _ = terminal.steps("token", "subscription", answers=answers)
            state = terminal.read()
            self.assertEqual((status, state["log"], state["stored"]), (1, [], {}))

    def test_wrong_kinds_of_token_are_not_stored(self):
        api_key = "sk-ant-" + "api03-" + "dummydummy" * 3
        for value in (
            api_key, PUBLISH, SUBSCRIPTION + " x", "", SUBSCRIPTION[:40], SUBSCRIPTION * 2,
            SUBSCRIPTION + "\n" + "dummydummy", SUBSCRIPTION + "\n" + SUBSCRIPTION + "\nyes\nyes\n",
        ):
            terminal = Terminal(self, ready())
            status, output, _ = terminal.steps(
                "token", "subscription", answers=[YES, YES, ("hidden", value)]
            )
            self.assertEqual((status, terminal.read()["stored"]), (1, {}))
            self.assertNotIn("dummydummy", output)

    def test_nothing_changes_while_the_factory_is_on(self):
        for command in (
            ["labels"], ["setup-test"], ["dispatch-resume"],
            ["token", "subscription"], ["token", "gate"], ["token", "publish"],
        ):
            terminal = Terminal(self, {**ready(), "variable": "true"})
            status, output, _ = terminal.steps(*command)
            self.assertEqual((status, terminal.read()["log"]), (1, []), command)
            self.assertIn("FACTORY_ENABLED is on", output)

    def test_publish_token_needs_a_waiting_resume_run(self):
        terminal = Terminal(self, ready())
        status, output, _ = terminal.steps("token", "publish", answers=[YES])
        self.assertEqual((status, terminal.read()["log"]), (1, []))
        self.assertIn("no Factory resume run is waiting", output)

    def test_labels_are_confirmed_one_by_one_and_rerun_safely(self):
        others = [name for name in setup_github.LABELS if name not in setup_github.NEW_LABELS]
        terminal = Terminal(self, {**ready(), "labels": others})
        for answers, status, made in (
            ([YES, ("Type yes", "no")], 1, 1), ([YES, YES], 0, 3), ([], 0, 3),
        ):
            ended, output, left = terminal.steps("labels", answers=answers)
            self.assertEqual((ended, len(terminal.read()["log"]), left), (status, made, []), output)

    def test_input_that_ends_confirms_nothing(self):
        terminal = Terminal(self, ready())
        ran = subprocess.run(
            [sys.executable, "-I", str(HERE / "setup_steps.py"), "labels"],
            input="", text=True, capture_output=True, env=terminal.environment, check=False,
        )
        self.assertEqual((ran.returncode, terminal.read()["log"]), (1, []))

    def test_a_token_is_never_read_without_a_terminal(self):
        with mock.patch("os.open", side_effect=OSError), self.assertRaises(setup_github.Problem):
            setup_steps.read_secret("x", ".*")

    def test_truncated_or_doubled_github_tokens_do_not_match(self):
        pattern = setup_steps.TOKENS["publish"][1]
        self.assertTrue(re.fullmatch(pattern, PUBLISH))
        for value in (PUBLISH[:-1], PUBLISH + "a", PUBLISH * 2):
            self.assertFalse(re.fullmatch(pattern, value))

    def test_visible_prompts_warn_against_tokens(self):
        for answer in (PUBLISH, "x"):
            terminal = Terminal(self, ready())
            _, output, _ = terminal.steps("labels", answers=[("Type yes", answer)])
            self.assertIn("never paste a token here", output)
            self.assertEqual("revoke it" in output, answer == PUBLISH)

    def test_each_change_needs_a_current_checkout(self):
        for command in (["labels"], ["setup-test"], ["dispatch-resume"], ["token", "gate"]):
            terminal = Terminal(self, {**ready(), "head": "c9"})
            status, output, _ = terminal.steps(*command)
            self.assertEqual((status, terminal.read()["log"]), (1, []))
            self.assertIn("checkout", output)

    def test_unset_removes_each_copy_even_when_on(self):
        secrets = {place: {"FACTORY_GATE_TOKEN": NOW} for place in ("actions", "factory-publish")}
        terminal = Terminal(self, {**ready(), "variable": "true", "secrets": secrets})
        status, output, _ = terminal.steps("unset", "gate", answers=[YES, YES])
        self.assertEqual(status, 0, output)
        self.assertEqual(terminal.read()["secrets"], {"actions": {}, "factory-publish": {}})

    def test_unset_goes_on_past_a_failure_and_a_refusal(self):
        places = ("actions", "dependabot", "agents", "codespaces", "factory-publish", "release")
        secrets = {place: {"FACTORY_GATE_TOKEN": NOW} for place in places}
        terminal = Terminal(self, {**ready(), "secrets": secrets, "stuck": ["dependabot"]})
        answers = [YES, YES, ("Type yes", "no"), YES, YES, YES]
        status, output, left = terminal.steps("unset", "gate", answers=answers)
        self.assertEqual((status, left), (1, []), output)
        kept = [place for place, names in terminal.read()["secrets"].items() if names]
        self.assertEqual(sorted(kept), ["agents", "dependabot"])

    def test_unset_goes_on_when_a_place_cannot_be_listed(self):
        fake = FakeGitHub({**ready(), "secrets": {"actions": {"FACTORY_GATE_TOKEN": NOW}}})

        def admin(method, path, body=None):
            return Answer(500) if "/agents/" in path else fake.admin(method, path, body)

        with (
            mock.patch.object(setup_github, "gh_api", admin),
            mock.patch.object(setup_steps, "confirm", lambda question: None),
            mock.patch("sys.stdout"), mock.patch("sys.stderr") as errors,
        ):
            status = setup_steps.main(["unset", "gate"])
        self.assertEqual((status, fake.state["secrets"]), (1, {"actions": {}}))
        self.assertIn("agents", str(errors.mock_calls))

    def test_revocation_is_only_an_attestation(self):
        for kind in setup_steps.TOKENS:
            terminal = Terminal(self, ready())
            status, output, _ = terminal.steps("revoked", kind, answers=[YES])
            self.assertEqual(status, 0, output)
            self.assertNotIn("hidden", output)
            self.assertIn("not verified", output)

    def test_usage_credits_variable_is_set_only_after_confirmation(self):
        for answers, status, value in (
            ([("Type yes", "no")], 1, None),
            ([YES, YES], 0, "checked and off"),
        ):
            terminal = Terminal(self, {**ready(), "variables": {"FACTORY_USAGE_CREDITS": "x"}})
            ended, output, _ = terminal.steps("usage-credits", answers=answers)
            self.assertEqual(ended, status, output)
            expected = value or "x"
            self.assertEqual(terminal.read()["variables"], {"FACTORY_USAGE_CREDITS": expected})

    def test_the_usage_credits_variable_needs_the_factory_off(self):
        terminal = Terminal(self, {**ready(), "variable": "true", "variables": {}})
        self.assertEqual(terminal.steps("usage-credits", answers=[YES, YES])[0], 1)
        self.assertEqual(terminal.read()["variables"], {})

    def test_the_agent_token_goes_only_to_its_environment(self):
        terminal = Terminal(self, ready())
        status, output, left = terminal.steps(
            "token", "agent", answers=[YES, YES, ("hidden", SUBSCRIPTION), YES, YES]
        )
        self.assertEqual((status, left), (0, []), output)
        self.assertEqual(terminal.read()["stored"], {"factory-agent/CLAUDE_CODE_OAUTH_TOKEN": SUBSCRIPTION})

    def test_unsetting_one_subscription_token_keeps_the_other(self):
        both = {place: {"CLAUDE_CODE_OAUTH_TOKEN": NOW} for place in ("factory-model", "factory-agent", "actions")}
        terminal = Terminal(self, {**ready(), "secrets": both})
        status, output, _ = terminal.steps("unset", "agent", answers=[YES, YES])
        self.assertEqual(status, 0, output)
        self.assertEqual(terminal.read()["secrets"], {
            "factory-model": {"CLAUDE_CODE_OAUTH_TOKEN": NOW}, "factory-agent": {}, "actions": {}})

    def test_a_resume_is_started_once(self):
        terminal = Terminal(self, ready())
        self.assertEqual(terminal.steps("dispatch-resume", answers=[YES])[0], 0)
        self.assertEqual(terminal.steps("dispatch-resume")[0], 0)
        self.assertEqual(len(terminal.read()["runs"]["factory-resume"]), 1)


class PublishTokenTest(unittest.TestCase):
    """In process, because the token's own requests go through token_api."""

    def run_token(self, *powers):
        fake = FakeGitHub({**ready(), "powers": list(powers)})
        fake.workflow("admin", "factory-resume", "dispatches")
        stored = []

        def store(secret, place, value):
            stored.append((secret, place, value))
            fake.state["secrets"].setdefault(place, {})[secret] = NOW

        with (
            mock.patch.object(setup_github, "gh_api", fake.admin),
            mock.patch.object(setup_github, "token_api", lambda value: fake.token),
            mock.patch.object(setup_steps, "read_secret", lambda *_: PUBLISH),
            mock.patch.object(setup_steps, "confirm", lambda question: None),
            mock.patch.object(setup_steps, "store", store),
            mock.patch.object(setup_github, "checkout", lambda api: []),
            mock.patch.object(negative_test.time, "sleep", lambda _: None),
            mock.patch("sys.stdout"),
            mock.patch("sys.stderr"),
        ):
            return setup_steps.main(["token", "publish"]), stored

    def test_stored_only_after_the_negative_test_passes(self):
        stored = [("FACTORY_PUBLISH_TOKEN", "factory-publish", PUBLISH)]
        self.assertEqual(self.run_token(), (0, stored))
        for power in ("approve", "workflows", "rules", "tags", "administration"):
            self.assertEqual(self.run_token(power), (1, []), power)


class WizardTest(unittest.TestCase):
    def test_check_reports_and_changes_nothing(self):
        terminal = Terminal(self, {**ready(), "labels": list(setup_github.LABELS)})
        status, output, _ = terminal.wizard("check")
        self.assertEqual((status, terminal.read()["log"]), (1, []))
        self.assertIn("Verified: main", output)
        self.assertNotRegex(output, r"\bproved")
        self.assertIn("no Factory resume run has been approved", output)

    def test_stopping_changes_nothing_and_a_rerun_skips_done_stages(self):
        terminal = Terminal(self, {**ready(), "environments": []})
        stop = [("start", ""), (r"again\? \[y/N", "n")]
        status, output, _ = terminal.wizard(answers=stop)
        self.assertEqual((status, terminal.read()["log"]), (1, []), output)
        self.assertIn("Stage 2/19", output)
        terminal.state.write_text(json.dumps(ready()))
        decline = [stop[0], ("Type yes", "no"), stop[1]]
        status, output, _ = terminal.wizard(answers=decline)
        self.assertEqual((status, terminal.read()["log"]), (1, []), output)
        self.assertIn("Stage 7/19", output)
        self.assertNotIn("Save the protection rules", output)

    def test_stages_are_counted(self):
        text = (HERE / "setup-wizard.sh").read_text(encoding="utf-8")
        body = text[text.index("TOTAL_STAGES=19"):]
        stages = re.findall(r"^(?:stage|environment_stage|token_stage) ", body, re.MULTILINE)
        self.assertEqual(len(stages), 19)

    def test_the_live_proof_setup_is_only_verified(self):
        text = (HERE / "setup-wizard.sh").read_text(encoding="utf-8")
        body = text[text.index("run_wizard() {"):]
        self.assertNotIn("environment_stage factory-model", body)
        self.assertNotIn("token_stage subscription", body)
        self.assertIn("until_done check environment factory-model", body)
        self.assertIn("until_done stored subscription", body)
        self.assertIn("environment_stage factory-agent", body)
        self.assertIn("token_stage agent", body)
        self.assertLess(body.index("until_done usage-credits"), body.index("token_stage agent"))

    def test_unknown_tokens_and_commands_stop(self):
        for arguments in (["rotate", "other"], ["revoke"], ["enable"]):
            terminal = Terminal(self, ready())
            status, _, _ = terminal.wizard(*arguments)
            self.assertEqual((status, terminal.read()["log"]), (2, []))

    def test_revoking_a_subscription_token(self):
        secrets = {"factory-model": {"CLAUDE_CODE_OAUTH_TOKEN": NOW}}
        terminal = Terminal(self, {**ready(), "secrets": secrets, "variable": "true"})
        status, output, left = terminal.wizard(
            "revoke", "subscription", answers=[
                ("start", ""), ("Type yes", "no"), (r"again\? \[y/N", "n"), YES]
        )
        self.assertEqual((status, left), (1, []), output)
        self.assertIn("NOT finished", output)
        self.assertEqual(terminal.read()["secrets"], {"factory-model": {}})

    def test_rotation_reaches_revocation_without_a_new_token(self):
        secrets = {"factory-model": {"CLAUDE_CODE_OAUTH_TOKEN": NOW}}
        terminal = Terminal(self, {**ready(), "secrets": secrets})
        status, output, left = terminal.wizard("rotate", "subscription", answers=[
            ("start", ""), ("Type yes", "no"), (r"again\? \[y/N", "n"), YES, YES,
        ])
        self.assertEqual((status, left), (1, []), output)
        self.assertEqual(terminal.read()["secrets"], {"factory-model": {}})

    def test_leftovers_are_offered_first_even_when_on(self):
        state = {**ready(), "variable": "true"}
        state["refs"]["refs/heads/factory-negative-test/x/control"] = "c0"
        for arguments in ([], ["rotate", "gate"]):
            terminal = Terminal(self, state)
            terminal.wizard(*arguments, answers=[
                ("start", ""), YES, (r"again\? \[y/N", "n")])
            self.assertEqual(terminal.read()["refs"], {"refs/heads/main": "c0"}, arguments)
        terminal = Terminal(self, state)
        _, output, _ = terminal.wizard("check")
        self.assertIn("factory-negative-test/x/control", output)

    def test_main_is_not_changed_when_the_maintainer_would_be_locked_out(self):
        text = (HERE / "setup-wizard.sh").read_text(encoding="utf-8")
        part = text[text.index('stage "Remove the administrator bypass'):]
        self.assertLess(part.index("until_done check mergeable"), part.index("open_url"))
        self.assertIn("locked out", part[:part.index("open_url")])

    def test_the_library_cannot_take_or_write_values(self):
        text = (HERE / "setup-wizard.sh").read_text(encoding="utf-8")
        stages = text[text.index("# STAGES:"):]
        for name in ("write_env", "set_secret", "set_var", "ask_secret"):
            uses = [line for line in stages.splitlines() if name in line]
            self.assertEqual(len(uses), 1, uses)
            self.assertRegex(uses[0], r"\(\) +\{ exit 70; \}")
        self.assertNotRegex(stages, r"gh (variable|secret|api)")


if __name__ == "__main__":
    unittest.main()
