import argparse
import contextlib
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import run_agent


def dummy(prefix, fill="x"):
    """A pretend token. Built when called, so that no source or compiled file holds one."""
    return prefix + fill * 60


def git_problem(environment, found):
    """Why tests that need git must skip, or None. Never skips in CI."""
    if found or environment.get("CI"):
        return None
    return "git is not installed"


TOKEN = dummy("sk-ant-oat01-")
PROBE_OK = {"type": "factory_probe", "phase": "before", "ok": True, "failures": []}
SUCCESS = {"type": "result", "subtype": "success", "is_error": False, "num_turns": 3}


def lines(*events):
    return [json.dumps(event) for event in events]


class ClassifyTests(unittest.TestCase):
    def outcome(self, output=(PROBE_OK, SUCCESS), events=({"kind": "ok"},), capped=None, exit_code=0):
        return run_agent.classify(lines(*output), list(events), capped, exit_code)

    def test_success(self):
        self.assertEqual(self.outcome(), "success")

    def test_usage_limit_is_distinct_from_every_other_failure(self):
        failed = (PROBE_OK, {"type": "result", "subtype": "success", "is_error": True})
        expected = {
            "usage_limit": "usage_limit",
            "throttled": "throttled",
            "overloaded": "overloaded",
            "auth_failed": "auth_failed",
            "upstream_error": "upstream_error",
            "upstream_unreachable": "upstream_unreachable",
            "ok": "agent_failed",
        }
        for kind, outcome in expected.items():
            self.assertEqual(self.outcome(failed, [{"kind": kind}], exit_code=1), outcome)

    def test_usage_limit_stops_the_day_even_if_the_agent_claims_success(self):
        self.assertEqual(self.outcome(events=[{"kind": "usage_limit"}]), "usage_limit")

    def test_agent_text_cannot_fake_a_usage_limit(self):
        forged = {
            "type": "result", "subtype": "success", "is_error": True,
            "result": "You've hit your session limit", "api_error_status": 429,
        }  # fmt: skip
        self.assertEqual(self.outcome((PROBE_OK, forged), exit_code=1), "agent_failed")

    def test_success_needs_a_model_reply_the_proxy_saw(self):
        self.assertEqual(self.outcome(events=[]), "agent_failed")

    def test_token_echo_outranks_everything(self):
        events = [{"kind": "ok"}, {"kind": "usage_limit"}, {"kind": "token_echoed"}]
        self.assertEqual(self.outcome(events=events), "token_echoed")

    def test_usage_credits_outrank_everything(self):
        events = [{"kind": "usage_limit"}, {"kind": "usage_credits"}]
        self.assertEqual(self.outcome(events=events), "usage_credits_on")

    def test_recovered_errors_do_not_fail_a_successful_run(self):
        self.assertEqual(self.outcome(events=[{"kind": "overloaded"}, {"kind": "ok"}]), "success")

    def test_error_followed_by_recovery_is_not_blamed_for_a_later_failure(self):
        failed = (PROBE_OK, dict(SUCCESS, is_error=True))
        self.assertEqual(
            self.outcome(failed, [{"kind": "overloaded"}, {"kind": "ok"}], exit_code=1),
            "agent_failed",
        )

    def test_caps(self):
        self.assertEqual(self.outcome(capped="time_cap"), "time_cap")
        turns = {"type": "result", "subtype": "error_max_turns", "is_error": True}
        self.assertEqual(self.outcome((PROBE_OK, turns), exit_code=1), "turn_cap")
        self.assertEqual(
            self.outcome(
                (PROBE_OK, dict(SUCCESS, is_error=True)),
                [{"kind": "refused", "reason": "model request cap reached"}],
                exit_code=1,
            ),
            "turn_cap",
        )

    def test_no_probe_or_failed_probe_is_never_success(self):
        self.assertEqual(self.outcome((SUCCESS,)), "sandbox_failed")
        self.assertEqual(self.outcome((SUCCESS, PROBE_OK)), "sandbox_failed")
        bad = dict(PROBE_OK, ok=False)
        self.assertEqual(self.outcome((bad, SUCCESS)), "sandbox_failed")

    def test_failed_probe_after_the_agent_fails_the_run(self):
        after = dict(PROBE_OK, phase="after", ok=False)
        self.assertEqual(self.outcome((PROBE_OK, SUCCESS, after)), "sandbox_failed")

    def test_missing_result_and_garbage_output_fail(self):
        self.assertEqual(
            run_agent.classify(lines(PROBE_OK) + ["not json", "[1]", "[" * 100000], [], None, 0), "agent_failed"
        )
        self.assertEqual(self.outcome(exit_code=2), "agent_failed")


class ContainerCommandTests(unittest.TestCase):
    def setUp(self):
        self.command = run_agent.container_command(
            "img", "name", Path("/w"), Path("/s"), Path("/p"), "claude-sonnet-5-5"
        )

    def test_has_no_network_privilege_or_host_docker_socket(self):
        text = " ".join(self.command)
        for flag in ("--network none", "--cap-drop ALL", "no-new-privileges"):
            self.assertIn(flag, text)
        for forbidden in ("docker.sock", "--privileged", "--pid=", "--pid ", " host", "--env-file"):
            self.assertNotIn(forbidden, text)

    def test_mounts_only_the_workspace_sockets_and_prompt(self):
        mounts = [b for a, b in zip(self.command, self.command[1:]) if a == "--volume"]
        self.assertEqual(sorted(mounts), ["/p:/prompt:ro", "/s:/run/factory:ro", "/w:/workspace"])

    def test_every_environment_value_is_fixed_here(self):
        values = [b for a, b in zip(self.command, self.command[1:]) if a == "--env"]
        self.assertTrue(all("=" in value for value in values))
        names = {value.split("=")[0] for value in values}
        self.assertFalse(names & {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "GITHUB_TOKEN"})

    def test_python_leaves_no_compiled_files(self):
        # Test files hold pretend tokens that a compiler may join into real-looking ones.
        self.assertIn("PYTHONDONTWRITEBYTECODE=1", self.command)

    def test_resources_are_bounded(self):
        for flag in ("--memory", "--memory-swap", "--cpus", "--pids-limit"):
            self.assertIn(flag, self.command)

    def test_turn_cap(self):
        at = self.command.index("--max-turns")
        self.assertEqual(self.command[at + 1], "100")
        self.assertEqual(run_agent.TIME_CAP_SECONDS, 3600)

    def test_bare_mode_would_ignore_the_subscription(self):
        self.assertNotIn("--bare", self.command)


class RunTests(unittest.TestCase):
    """Runs the entry point with a stand-in `docker` executable."""

    def setUp(self):
        git = shutil.which("git")
        if problem := git_problem(os.environ, git):
            self.skipTest(problem)
        self.assertIsNotNone(git, "git is required in CI")
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin, self.workspace = self.root / "bin", self.root / "ws"
        self.bin.mkdir()
        self.workspace.mkdir()
        (self.workspace / "a.txt").write_text("old\n")
        (self.root / "prompt").write_text("do it")
        self.env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.root)}

    def docker(self, body, after=""):
        script = self.bin / "docker"
        script.write_text(
            "#!/bin/sh\n"
            f'echo "$@" >> {self.root}/calls\n'
            f"env >> {self.root}/env\n"
            f'if [ "$1" = run ]; then\n{body}\nfi\n{after}\n'
        )
        script.chmod(script.stat().st_mode | stat.S_IXUSR)

    def command(self, *extra, credits=True):
        return [
            sys.executable, str(Path(run_agent.__file__)), "--image", "img",
            "--workspace", str(self.workspace), "--prompt", str(self.root / "prompt"),
            "--output", str(self.root / "out"), "--model", "claude-sonnet-5-5",
            *(["--usage-credits-confirmed-off"] if credits else []), *extra,
        ]  # fmt: skip

    def run_agent(self, *extra, token=TOKEN, env=None, credits=True):
        return subprocess.run(
            self.command(*extra, credits=credits), input=token, text=True, capture_output=True,
            env={**self.env, **(env or {})}, timeout=30,
        )  # fmt: skip

    def result(self):
        return json.loads((self.root / "out" / "result.json").read_text())

    def emit(self, *events):
        return "\n".join(f"echo '{json.dumps(event)}'" for event in events)

    # The stand-in cannot talk to the model, so the furthest it gets is agent_failed.
    def test_outputs_a_patch_without_running_workspace_git_config(self):
        hook = self.root / "pwned"
        self.docker(
            f"cd {self.workspace}; git init -q .; git config core.fsmonitor 'touch {hook}';"
            "echo new > a.txt; echo x > b.txt\n" + self.emit(PROBE_OK, SUCCESS)
        )
        self.run_agent()
        self.assertEqual(self.result()["outcome"], "agent_failed")
        patch = (self.root / "out" / "agent.patch").read_text()
        self.assertIn("+new", patch)
        self.assertIn("b.txt", patch)
        self.assertNotIn(".git/", patch)
        self.assertFalse(hook.exists())

    def test_agent_output_never_reaches_the_job_log(self):
        self.docker(
            "echo ::add-mask::out; echo ::warning::err >&2\n"
            + self.emit(PROBE_OK, dict(SUCCESS, num_turns="::error::turns", result="::error::r"))
        )
        done = self.run_agent()
        self.assertNotIn("::", done.stdout + done.stderr)
        self.assertIn("::warning::", (self.root / "out" / "agent.stderr").read_text())

    def test_refused_patch_still_writes_a_result(self):
        self.docker(f"ln -s /etc/passwd {self.workspace}/link\n" + self.emit(PROBE_OK, SUCCESS))
        self.assertEqual(self.run_agent().returncode, 1)
        self.assertIn("symbolic link", self.result()["patch_refused"])
        self.assertFalse((self.root / "out" / "agent.patch").exists())

    def test_crash_still_writes_a_result(self):
        self.assertEqual(self.run_agent(env={"PATH": "/nonexistent"}).returncode, 1)
        self.assertIn(self.result()["outcome"], ("internal_error", "workspace_refused"))

    def test_token_in_the_transcript_is_withheld(self):
        self.docker(self.emit(PROBE_OK, SUCCESS) + f"\necho {TOKEN[13:40]}")
        self.assertEqual(self.run_agent().returncode, 1)
        self.assertEqual(self.result()["outcome"], "token_echoed")
        self.assertNotIn(TOKEN[13:40], (self.root / "out" / "agent.jsonl").read_text())

    def test_token_in_another_case_is_withheld(self):
        self.docker(self.emit(PROBE_OK, SUCCESS) + f"\necho {TOKEN[13:40].swapcase()}")
        self.run_agent()
        self.assertEqual(self.result()["outcome"], "token_echoed")

    def test_floods_of_tiny_lines_stop_before_they_are_parsed(self):
        self.docker("yes '' | head -c 3000000")
        self.assertEqual(self.run_agent().returncode, 1)
        self.assertEqual(self.result()["outcome"], "output_overflow")

    def test_refuses_a_rerun(self):
        self.docker("true")
        for attempt in ("2", "x", ""):
            self.assertEqual(self.run_agent(env={"GITHUB_RUN_ATTEMPT": attempt}).returncode, 2)
        self.assertFalse((self.root / "calls").exists())
        self.assertEqual(self.run_agent(env={"GITHUB_RUN_ATTEMPT": "1"}).returncode, 1)

    def test_failed_kill_is_a_failure_without_a_patch(self):
        self.docker("exec sleep 20", after='if [ "$1" = kill ]; then exit 1; fi')
        self.assertEqual(self.run_agent("--time-cap", "1").returncode, 1)
        self.assertEqual(self.result()["outcome"], "container_not_stopped")
        self.assertFalse((self.root / "out" / "agent.patch").exists())

    def test_container_that_outlives_its_client_is_a_failure(self):
        self.docker(self.emit(PROBE_OK, SUCCESS), after='if [ "$1" = ps ]; then echo abc; fi')
        self.assertEqual(self.run_agent().returncode, 1)
        self.assertEqual(self.result()["outcome"], "container_not_stopped")

    def test_unbounded_output_stops_the_run(self):
        self.docker("exec head -c 70000000 /dev/zero")
        self.assertEqual(self.run_agent().returncode, 1)
        self.assertEqual(self.result()["outcome"], "output_overflow")
        size = (self.root / "out" / "agent.jsonl").stat().st_size
        self.assertLessEqual(size, 64 * 1024 * 1024)

    def test_reports_the_outcome_to_the_workflow(self):
        self.docker(self.emit(PROBE_OK, SUCCESS))
        path = self.root / "github"
        self.run_agent(env={"GITHUB_OUTPUT": str(path)})
        self.assertEqual(
            self.outputs(path),
            {"outcome": "agent_failed", "usage_limit": "false", "searched": "true"},
        )

    def outputs(self, path):
        """What a later step sees: the last value of each name."""
        return dict(line.split("=", 1) for line in path.read_text().splitlines())

    def interrupt(self, *signals, printed=TOKEN):
        """Start a run whose container has printed the token and hangs, then signal it."""
        github = self.root / "github"
        self.docker(
            self.emit(PROBE_OK) + f"\necho {printed}; touch {self.root}/ready; exec sleep 20"
        )
        process = subprocess.Popen(
            self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env={**self.env, "GITHUB_OUTPUT": str(github)},
        )  # fmt: skip
        process.stdin.write(TOKEN)
        process.stdin.close()
        deadline = time.monotonic() + 20
        while not (self.root / "ready").exists():
            self.assertIsNone(process.poll(), "the run ended before its container started")
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        time.sleep(0.3)
        for number in signals:
            process.send_signal(number)
            time.sleep(0.05)
        process.wait(30)
        process.stdout.close()
        process.stderr.close()
        output = self.root / "out"
        for path in output.rglob("*") if output.exists() else ():
            self.assertNotIn(TOKEN, path.read_text(), path.name)
        return process.returncode, self.outputs(github)

    def test_cancelling_stops_the_container_and_still_searches_for_the_token(self):
        for signals in ([signal.SIGINT], [signal.SIGTERM], [signal.SIGINT, signal.SIGTERM]):
            with self.subTest(signals):
                code, outputs = self.interrupt(*signals)
                self.assertEqual(code, 1)
                self.assertEqual(
                    outputs,
                    {"outcome": "token_echoed", "usage_limit": "false", "searched": "true"},
                )
                self.assertIn("kill factory-", (self.root / "calls").read_text())
                self.assertIn("withheld", (self.root / "out" / "agent.jsonl").read_text())
                self.tearDownRun()

    def tearDownRun(self):
        subprocess.run(["rm", "-rf", str(self.root / "out"), str(self.root / "ready"),
                        str(self.root / "calls"), str(self.root / "github")])  # fmt: skip

    def test_a_killed_run_leaves_nothing_unsearched_to_upload(self):
        code, outputs = self.interrupt(signal.SIGKILL)
        self.assertEqual(code, -signal.SIGKILL)
        self.assertEqual(
            outputs, {"outcome": "unfinished", "usage_limit": "false", "searched": "false"}
        )
        self.assertFalse((self.root / "out").exists())
        # Nothing could tidy up the private directory, so do it here.
        (sockets,) = re.findall(r"(/tmp/factory-\w+)/s:", (self.root / "calls").read_text())
        shutil.rmtree(sockets)

    def test_cancelling_a_clean_run_reports_it(self):
        code, outputs = self.interrupt(signal.SIGTERM, printed="hello")
        self.assertEqual(code, 1)
        self.assertEqual(
            outputs, {"outcome": "cancelled", "usage_limit": "false", "searched": "true"}
        )
        self.assertEqual(self.result()["outcome"], "cancelled")

    def test_the_search_still_runs_when_the_run_crashes(self):
        self.docker(self.emit(PROBE_OK) + f"\necho {TOKEN}")
        github = self.root / "github"
        done = subprocess.run(
            [sys.executable, "-c",
             "import sys, run_agent\n"
             "def crash(*_): raise RuntimeError\n"
             "run_agent.classify = crash\n"
             "sys.argv[0] = 'run_agent'\n"
             "sys.exit(run_agent.main())", *self.command()[2:]],
            input=TOKEN, text=True, capture_output=True, timeout=30,
            env={**self.env, "GITHUB_OUTPUT": str(github),
                 "PYTHONPATH": str(Path(run_agent.__file__).parent)},
        )  # fmt: skip
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertNotIn(TOKEN, (self.root / "out" / "agent.jsonl").read_text())
        self.assertEqual(self.outputs(github)["searched"], "true")

    def run_in_process(self, attempt, trace=None):
        """Call run() here with a stand-in attempt. Returns the step outputs."""
        github, output = self.root / "github", self.root / "out"
        github.unlink(missing_ok=True)
        shutil.rmtree(output, ignore_errors=True)
        saved = [(n, signal.getsignal(n)) for n in (signal.SIGINT, signal.SIGTERM)]
        arguments = argparse.Namespace(output=output)
        try:
            with (
                tempfile.TemporaryDirectory() as scratch,
                mock.patch.dict(os.environ, GITHUB_OUTPUT=str(github)),
                mock.patch.object(run_agent, "attempt", attempt),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                sys.settrace(trace)
                try:
                    run_agent.run(arguments, TOKEN, Path(scratch))
                finally:
                    sys.settrace(None)
        finally:
            for number, handler in saved:
                signal.signal(number, handler)
        return self.outputs(github)

    def test_no_moment_to_cancel_skips_the_search(self):
        def attempt(*_):
            return {"outcome": "success"}

        for moment in range(60):
            lines = 0

            def trace(frame, event, _):
                nonlocal lines
                if frame.f_code is not run_agent.run.__code__:
                    return None
                # Only once this process handles the signal; before, it just ends.
                if event == "line" and callable(signal.getsignal(signal.SIGTERM)):
                    lines += 1
                    if lines == moment:
                        os.kill(os.getpid(), signal.SIGTERM)
                return trace

            outputs = self.run_in_process(attempt, trace)
            self.assertEqual(outputs["searched"], "true", moment)
            self.assertIn(outputs["outcome"], ("success", "cancelled"), moment)
            if lines < moment:
                break
        else:
            self.fail("run() was not traced to its end")

    def test_a_late_usage_limit_is_never_taken_back(self):
        logs = []

        def attempt(*arguments):
            logs.extend(a for a in arguments if isinstance(a, run_agent.EventLog))
            return {"outcome": "success"}

        real = run_agent.publish

        def publish(*arguments):
            # A request still in flight reports the limit while files are searched.
            logs[0].record({"kind": "usage_limit"})
            return real(*arguments)

        with mock.patch.object(run_agent, "publish", publish):
            self.assertEqual(self.run_in_process(attempt)["usage_limit"], "true")

    def test_nothing_is_published_when_the_search_fails(self):
        staging, output = self.root / "staging", self.root / "published"
        staging.mkdir()
        (staging / "agent.jsonl").write_text("unsearched")

        class Broken:
            def found(self, data):
                raise MemoryError

        with self.assertRaises(MemoryError):
            run_agent.publish(staging, output, {"outcome": "success"}, Broken())
        self.assertFalse(output.exists())

    def test_published_files_are_only_the_known_ones(self):
        staging, output = self.root / "staging", self.root / "published"
        staging.mkdir()
        (staging / "agent.jsonl").write_text("x")
        (staging / "link").symlink_to("/etc/passwd")
        run_agent.publish(
            staging, output, {"outcome": "success"}, run_agent.proxy.TokenSearch(TOKEN)
        )
        self.assertEqual(
            sorted(path.name for path in output.iterdir()), ["agent.jsonl", "result.json"]
        )

    def test_a_usage_limit_is_reported_at_once(self):
        path = self.root / "github"
        with mock.patch.dict(os.environ, GITHUB_OUTPUT=str(path)):
            log = run_agent.EventLog()
            log.record({"kind": "ok"})
            self.assertFalse(path.exists())
            log.record({"kind": "usage_limit"})
            self.assertEqual(self.outputs(path), {"usage_limit": "true"})

    def test_output_directory_must_be_new(self):
        self.docker("true")
        (self.root / "out").mkdir()
        self.assertNotEqual(self.run_agent().returncode, 0)
        self.assertFalse((self.root / "calls").exists())

    def test_token_reaches_no_child_environment_argument_or_output(self):
        self.docker(self.emit(PROBE_OK, SUCCESS))
        done = self.run_agent()
        seen = done.stdout + done.stderr
        for path in self.root.rglob("*"):
            if path.is_file():
                seen += path.read_text(errors="replace")
        self.assertNotIn(TOKEN, seen)

    def test_time_cap_kills_the_container(self):
        self.docker("exec sleep 20")
        done = self.run_agent("--time-cap", "1")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(self.result()["outcome"], "time_cap")
        self.assertIn("kill factory-", (self.root / "calls").read_text())

    def test_time_cap_can_only_be_lowered(self):
        self.docker("true")
        self.assertEqual(self.run_agent("--time-cap", "3601").returncode, 2)

    def test_refuses_before_starting_a_container(self):
        self.docker("true")
        for arguments in (
            {"env": {"ANTHROPIC_API_KEY": "k"}},
            {"env": {"ANTHROPIC_API_KEY": ""}},
            {"credits": False},
            {"token": ""},
            {"token": dummy("sk-ant-api03-")},
        ):
            self.assertEqual(self.run_agent(**arguments).returncode, 2, arguments)
        self.assertFalse((self.root / "calls").exists())


class GitRequirementTests(unittest.TestCase):
    def test_skips_only_outside_ci(self):
        self.assertIsNone(git_problem({}, "/usr/bin/git"))
        self.assertIn("git", git_problem({}, None))
        self.assertIsNone(git_problem({"CI": "true"}, None))


class EventLogTests(unittest.TestCase):
    def test_noise_is_bounded_and_never_displaces_other_events(self):
        log = run_agent.EventLog(limit=3)
        for _ in range(10):
            log.record({"kind": "refused", "reason": "host not allowed"})
        decisive = [
            {"kind": "refused", "reason": "model request cap reached"},
            {"kind": "usage_limit"},
            {"kind": "usage_credits"},
            {"kind": "token_echoed"},
            {"kind": "overloaded"},
            {"kind": "tunnel", "host": "cache.nixos.org", "bytes": 1},
        ]
        for event in decisive:
            log.record(event)
        self.assertEqual(
            [{k: v for k, v in event.items() if k != "time"} for event in log.events[3:]],
            decisive,
        )
        self.assertEqual(len(log.events), 3 + len(decisive))

    def test_each_tunnel_host_has_its_own_room(self):
        log = run_agent.EventLog(limit=2)
        for _ in range(5):
            log.record({"kind": "tunnel", "host": "hackage.haskell.org", "bytes": 1})
        log.record({"kind": "tunnel", "host": "cache.nixos.org", "bytes": 9})
        self.assertEqual([e["host"] for e in log.events][-1], "cache.nixos.org")
        self.assertEqual(len(log.events), 3)


if __name__ == "__main__":
    unittest.main()
