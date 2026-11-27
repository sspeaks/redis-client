import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import gate as factory_gate
import performance_gate as gate

WORKFLOW = Path(__file__).parents[2] / ".github/workflows/performance.yml"


def document(throughput=1000.0, p99=2000, allocation=500.0, errors=0, timeouts=0):
    return {
        "metrics": {
            "ops_per_second": throughput,
            "latency_micros": {"p99": p99},
            "allocation_bytes_per_op": allocation,
            "errors": errors,
            "timeouts": timeouts,
        }
    }


class Sampler:
    """Yields each build's documents in order, repeating the last one."""

    def __init__(self, base, head):
        self.documents = {"base": list(base), "head": list(head)}
        self.calls = []

    def __call__(self, build, scenario):
        self.calls.append(build)
        remaining = self.documents[build]
        return remaining.pop(0) if len(remaining) > 1 else remaining[0]


def evaluate(head, claims=()):
    sampler = Sampler([document()], head)
    return gate.evaluate(sampler, ["standalone"], claims), sampler


class EvaluateTests(unittest.TestCase):
    def test_unchanged_code_passes_after_one_run(self):
        result, _ = evaluate([document()])
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["runs"]), 1)

    def test_builds_are_interleaved_five_times_each_with_alternating_order(self):
        _, sampler = evaluate([document()])
        self.assertEqual(
            sampler.calls,
            ["base", "head", "head", "base", "base", "head", "head", "base", "base", "head"],
        )

    def test_each_metric_regression_that_repeats_blocks(self):
        for metric, head in (
            ("throughput", document(throughput=880.0)),
            ("p99", document(p99=2250)),
            ("allocation", document(allocation=560.0)),
        ):
            with self.subTest(metric=metric):
                result, _ = evaluate([head])
                self.assertFalse(result["passed"])
                self.assertEqual(len(result["runs"]), 2)
                self.assertEqual(result["regressions"], [f"standalone/{metric}"])

    def test_exactly_ten_percent_does_not_block(self):
        result, _ = evaluate([document(900.0, 2200, 550.0)])
        self.assertTrue(result["passed"])

    def test_regression_that_does_not_repeat_passes_after_a_third_run(self):
        result, _ = evaluate([document(allocation=600.0)] * 5 + [document()])
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["runs"]), 3)

    def test_regression_in_the_first_and_third_runs_blocks(self):
        slow = [document(allocation=600.0)] * 5
        result, _ = evaluate(slow + [document()] * 5 + slow)
        self.assertEqual(len(result["runs"]), 3)
        self.assertEqual(result["regressions"], ["standalone/allocation"])
        self.assertFalse(result["passed"])

    def test_one_outlier_does_not_move_the_result(self):
        result, _ = evaluate([document(p99=90000), document()])
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["runs"]), 1)

    def test_results_report_median_and_spread(self):
        result, _ = evaluate(
            [document(throughput=value) for value in (1000, 1010, 990, 1100, 900)]
        )
        self.assertEqual(
            result["runs"][0]["standalone/throughput"]["head"],
            {
                "samples": [1000, 1010, 990, 1100, 900],
                "median": 1000, "min": 900, "max": 1100, "stdev": 71.06,
            },
        )
        self.assertIn("1,000 (900-1,100, sd 71)", gate.render(result))

    def test_claimed_gain_must_repeat(self):
        result, _ = evaluate([document(allocation=400.0)], ["allocation"])
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["runs"]), 2)
        result, _ = evaluate([document(allocation=400.0)] * 5 + [document()], ["allocation"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["unproven_claims"], ["allocation"])

    def test_claim_of_ten_percent_or_less_is_unproven(self):
        result, _ = evaluate([document(allocation=450.0)], ["allocation"])
        self.assertEqual(result["unproven_claims"], ["allocation"])

    def test_claim_must_hold_in_every_scenario(self):
        def sampler(build, scenario):
            faster = build == "head" and scenario == "cluster"
            return document(allocation=250.0 if faster else 500.0)

        result = gate.evaluate(sampler, ["standalone", "cluster"], ["allocation"])
        self.assertEqual(result["unproven_claims"], ["allocation"])

    def test_two_slow_samples_in_five_block_when_they_repeat(self):
        slow = [document(1e2, 20000, 5000.0)] * 2 + [document()] * 3
        result, _ = evaluate(slow * 2)
        self.assertFalse(result["passed"])
        self.assertEqual(len(result["runs"]), 2)
        self.assertEqual(
            result["regressions"],
            ["standalone/allocation", "standalone/p99", "standalone/throughput"],
        )

    def test_a_different_regression_on_each_run_takes_a_third_run(self):
        p99, allocation = document(p99=3000), document(allocation=600.0)
        result, _ = evaluate([p99] * 5 + [allocation] * 5 + [p99])
        self.assertEqual(len(result["runs"]), 3)
        self.assertEqual(result["regressions"], ["standalone/p99"])
        self.assertFalse(result["passed"])

    def test_a_regression_in_every_run_passes_unless_one_metric_repeats(self):
        p99, allocation = document(p99=3000), document(allocation=600.0)
        result, _ = evaluate([p99] * 5 + [allocation] * 5 + [document(throughput=500.0)])
        self.assertEqual(len(result["runs"]), 3)
        self.assertEqual(result["regressions"], [])
        self.assertTrue(result["passed"])
        self.assertIn("## Performance gate: passed", gate.render(result))

    def test_results_keep_every_sample(self):
        result, _ = evaluate([document()])
        self.assertEqual(
            result["runs"][0]["standalone/p99"]["head"]["samples"], [2000] * 5
        )

    def test_invalid_samples_fail_closed(self):
        for bad in (
            document(errors=1), document(timeouts=1), document(errors=False),
            document(errors=None), document(errors=[]), document(errors=float("nan")),
            document(throughput=float("nan")), document(throughput=float("inf")),
            document(throughput=True), document(throughput="1"), document(throughput=10**400),
            document(throughput=1e9), document(p99=0), document(p99=1e12),
            document(allocation=0), document(allocation=-1), document(allocation=1e-300),
            {"metrics": {}}, {}, [],
        ):
            with self.subTest(bad=str(bad)[:80]), self.assertRaises(gate.GateError):
                evaluate([bad])

    def test_implausible_gain_is_not_accepted(self):
        with self.assertRaises(gate.GateError):
            evaluate([document(allocation=90.0)])


class ScopeTests(unittest.TestCase):
    def test_anything_that_could_affect_measurement_is_relevant(self):
        for path in (
            "hask-redis-mux/lib/Database/Redis/Client.hs",
            "hask-redis-mux/hask-redis-mux.cabal",
            "hask-redis-mux/lib/a.md",
            "hask-redis-mux/lib/LICENSE",
            "hask-redis-mux/bench/Foo.hs",
            "hask-redis-mux/data/x.json",
            "bench/BenchmarkMain.hs",
            "app/Main.hs",
            "redis-client.cabal",
            "cabal.project",
            "cabal.project.local",
            "flake.lock",
            "shell.nix",
            "brand-new-directory/Code.hs",
            "test/Lib.c",
            "test/Lib.h",
            "test/README.md",
            "docs/x.hs",
            "docs/x.c",
            "docker/x.c",
            "scripts/Foo.hs",
            "scripts/benchmark-cluster.sh",
            "scripts/compare-benchmark-results.py",
            "scripts/factory/performance_gate.py",
            "scripts/factory/gate.py",
            ".github/workflows/performance.yml",
            ".github/workflows/factory-performance-baseline.yml",
            ".github/workflows/factory-performance-calibrate.yml",
        ):
            with self.subTest(path=path):
                self.assertTrue(gate.is_relevant(path))

    def test_unrelated_changes_are_not_relevant(self):
        for path in (
            "docs/factory.md",
            "README.md",
            "hask-redis-mux/CHANGELOG.md",
            "test/Foo.hs",
            "hask-redis-mux/test/Foo.hs",
            "scripts/factory/intake.py",
            "scripts/test_release_metadata.py",
            ".github/workflows/runTests.yml",
            "Makefile",
        ):
            with self.subTest(path=path):
                self.assertFalse(gate.is_relevant(path))

    def test_symlinks_and_submodules_are_always_relevant(self):
        for modes in (("100644", "120000"), ("120000", "000000"), ("000000", "160000")):
            with self.subTest(modes=modes):
                self.assertTrue(gate.is_relevant("docs/x.md", modes))

    def test_changes_are_read_from_git_with_their_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*arguments):
                return subprocess.run(
                    ["git", "-C", directory, "-c", "user.name=x", "-c", "user.email=x",
                     "-c", "core.hooksPath=/dev/null", *arguments],
                    check=True, stdout=subprocess.PIPE, text=True,
                ).stdout.strip()

            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "base")
            base = git("rev-parse", "HEAD")
            os.symlink("../app", Path(directory, "README.md"))
            git("add", "-A")
            git("commit", "-q", "-m", "head")
            self.assertEqual(
                gate.changed_paths(base, "HEAD", directory),
                [("README.md", ("000000", "120000"))],
            )


class ClaimTests(unittest.TestCase):
    def test_canonical_lines_are_claims(self):
        self.assertEqual(
            gate.parse_claims("Faster.\r\nPerformance-claim: p99, allocation\r\n"),
            ["allocation", "p99"],
        )
        self.assertEqual(gate.parse_claims("x\rPerformance-claim: p99"), ["p99"])

    def test_text_without_a_claim_has_none(self):
        for text in (None, "", "This makes no performance claim.", "Improves performance.", "Performance impact: none",
            "Performance notes: see below", "The issue claims: it is slow", "Performance: unchanged"):
            with self.subTest(text=text):
                self.assertEqual(gate.parse_claims(text), [])

    def test_near_misses_are_refused(self):
        for text in (
            "performance-claim: p99", "- Performance-claim: p99", " Performance-claim: p99",
            "**Performance-claim:** p99", "Performance claim: p99", "Performance-claim:",
            "Performance-claim: p99, evil", "Performance-claim: P99", "Performance-claim p99",
            "<!-- Performance-claim: p99 -->", "x Performance-claim: p99",
            "Performance-claim: p99\x00", "Performance-claims: p99",
            "Performance\u200b-claim: p99", "Performance\u2011claim\uff1a p99",
            "Perf-claim: p99", "Performance claimed: p99", "Claim: p99", "Claims: allocation",
            "Claimed performance: p99", "Performance-clam: p99", "Preformance-claim: p99",
            "Performance gain: p99", "Performance improvement = p99", "| Performance-claim | p99 |",
            "\u0420erformance-claim: p99", "Performance-claim\uff1ap99", "Perf claim - p99",
            "Performance_claim: p99", "PerformanceClaim: p99", "Performance-claim: p99 or so",
            "Throughput claim: throughput", "Claimed performance gain: p99", "p99 claim: p99",
            "Allocation claims: allocation", "Latency claim: p99", "Claimed throughput gain: 2x",
        ):
            with self.subTest(text=text), self.assertRaises(gate.GateError):
                gate.parse_claims(text)

    def test_claims_are_read_from_the_ticket_too(self):
        class Issues:
            def get(self, path):
                return {"repos/o/r/issues/7": {"body": "Performance-claim: p99"},
                        "repos/o/r/issues/8": {"body": None}}.get(path)

        self.assertEqual(
            gate.all_claims(Issues(), "o/r", "Performance-claim: allocation\nCloses #7, fixes #8"),
            ["allocation", "p99"],
        )
        with self.assertRaises(gate.GateError):
            gate.all_claims(Issues(), "o/r", "Closes #9")

    def test_every_link_form_github_honors_is_followed(self):
        for keyword in (
            "close", "closes", "closed", "fix", "fixes", "fixed",
            "resolve", "resolves", "resolved", "CLOSES", "Fixes:",
        ):
            self.assertEqual(gate.tickets(f"x {keyword} #7.", "o/r"), [7], keyword)
        for link in (
            "#7", "o/r#7", "O/R#7", "GH-7", "gh-7",
            "https://github.com/o/r/issues/7", "http://github.com/O/r/issues/7",
            "https://www.github.com/o/r/issues/7#issuecomment-1",
        ):
            self.assertEqual(gate.tickets(f"Closes {link}", "o/r"), [7], link)
        self.assertEqual(gate.tickets("Fixes #1, closes #2\nresolves o/r#1", "o/r"), [1, 2])

    def test_emphasized_or_linked_references_are_followed(self):
        # Following a reference GitHub might not close is the safe direction: it can
        # only find more claims.
        for text in (
            "closes **#5**", "Closes __#5__", "Closes *#5*", "Fixes _o/r#5_",
            "Closes [#5](https://github.com/o/r/issues/5)", "Resolves [GH-5](x)",
            "Closes **https://github.com/o/r/issues/5**",
        ):
            self.assertEqual(gate.tickets(text, "o/r"), [5], text)

    def test_other_references_are_not_tickets(self):
        for text in ("See #7", "#7", "Closes x/y#7", "encloses #7", "Closes #", "Closes #7a", None):
            self.assertEqual(gate.tickets(text, "o/r"), [], text)

    def test_too_many_tickets_are_refused(self):
        with self.assertRaises(gate.GateError):
            gate.tickets(" ".join(f"closes #{n}" for n in range(1, 30)), "o/r")


class FakeGitHub:
    def __init__(self, releases=(), branch_exists=False):
        self.releases, self.branch_exists, self.posts = releases, branch_exists, []
        self.log = []

    def get(self, path):
        if "/releases" in path:
            return list(self.releases)
        return {"object": {"sha": "x"}} if self.branch_exists else None

    def post(self, path, body):
        self.posts.append((path, body))
        self.log.append(path.rsplit("/", 1)[1])
        return {"sha": f"sha{len(self.posts)}"}


RESULT = {"runs": [{"standalone/p99": {"head": {"samples": [1, 2]}}}], "passed": True}


class BaselineTests(unittest.TestCase):
    def test_stored_baseline_is_bounded(self):
        row = {"standalone/p99": {"head": {"samples": [1] * 5}}}
        for runs in ([], [row] * 4, [{}], [{"standalone/p99": {"head": {"samples": [1] * 6}}}],
                     [{"standalone/p99": {"head": {"samples": []}}}], {"0": row}, "x"):
            github = FakeGitHub()
            with self.subTest(runs=str(runs)[:40]), self.assertRaises(gate.GateError):
                gate.store_baseline(github, "o/r", {"runs": runs}, "a" * 40, list)
            self.assertEqual(github.posts, [])

    def test_oversized_result_is_refused_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory, "result.json")
            result.write_bytes(b" " * (gate.MAX_OUTPUT + 1))
            arguments = argparse.Namespace(result=result, repository="o/r", commit="a" * 40)
            with self.assertRaises(gate.GateError):
                gate.command_baseline(arguments)

    def test_only_plain_numbers_are_stored(self):
        for samples in (["x"], [True], [float("nan")], "12", [10**400]):
            result = {"runs": [{"standalone/p99": {"head": {"samples": samples}}}]}
            github = FakeGitHub()
            with self.subTest(samples=str(samples)[:20]), self.assertRaises(gate.GateError):
                gate.store_baseline(github, "o/r", result, "a" * 40, list)
            self.assertEqual(github.posts, [])
        for name in ("evil", "standalone/p99\n"):
            with self.assertRaises(gate.GateError):
                gate.store_baseline(
                    FakeGitHub(), "o/r", {"runs": [{name: {"head": {"samples": [1]}}}]},
                    "a" * 40, list,
                )
        with self.assertRaises(gate.GateError):
            gate.store_baseline(FakeGitHub(), "o/r", RESULT, "main", list)

    def test_first_result_is_stored_with_its_commit(self):
        github = FakeGitHub()
        self.assertTrue(gate.store_baseline(github, "o/r", RESULT, "a" * 40, list))
        entry = github.posts[0][1]["tree"][0]
        self.assertEqual(entry["path"], "performance-baseline.json")
        self.assertEqual(
            json.loads(entry["content"]),
            {
                "schema_version": 1,
                "note": "Not evidence. To compare, rebuild this commit on the same runner.",
                "commit": "a" * 40,
                "samples": [{"standalone/p99": [1, 2]}],
            },
        )
        self.assertEqual(
            github.posts[-1],
            (
                "repos/o/r/git/refs",
                {"ref": "refs/heads/factory-performance-baseline", "sha": "sha2"},
            ),
        )

    def test_only_a_passed_result_becomes_the_baseline(self):
        for passed in (False, None, "true", 1):
            github = FakeGitHub()
            with self.subTest(passed=passed), self.assertRaises(gate.GateError):
                gate.store_baseline(github, "o/r", {**RESULT, "passed": passed}, "a" * 40, list)
            self.assertEqual(github.posts, [])
        unmarked = {key: value for key, value in RESULT.items() if key != "passed"}
        with self.assertRaises(gate.GateError):
            gate.store_baseline(FakeGitHub(), "o/r", unmarked, "a" * 40, list)

    def test_existing_baseline_or_release_is_never_overwritten(self):
        for github in (
            FakeGitHub(branch_exists=True),
            FakeGitHub(releases=[{"draft": False}]),
        ):
            self.assertFalse(gate.store_baseline(github, "o/r", RESULT, "a" * 40, list))
            self.assertEqual(github.posts, [])

    def test_factory_gate_is_checked_immediately_before_every_write(self):
        github = FakeGitHub()
        gate.store_baseline(github, "o/r", RESULT, "a" * 40, lambda: github.log.append("gate"))
        self.assertEqual(github.log, ["gate", "trees", "gate", "commits", "gate", "refs"])

    def test_refusal_at_any_check_stops_every_later_write(self):
        for allowed in range(3):
            github = FakeGitHub()
            authorize = mock.Mock(side_effect=[None] * allowed + [factory_gate.Refused("off")])
            with self.subTest(allowed=allowed), self.assertRaises(factory_gate.Refused):
                gate.store_baseline(github, "o/r", RESULT, "a" * 40, authorize)
            self.assertEqual(len(github.posts), allowed)
            self.assertNotIn("refs", github.log)

    def test_command_asks_for_publish_and_writes_nothing_on_any_gate_failure(self):
        for failure in (factory_gate.Refused("off"), RuntimeError("broken")):
            github = FakeGitHub()
            with tempfile.TemporaryDirectory() as directory:
                result = Path(directory, "result.json")
                result.write_text(json.dumps(RESULT))
                arguments = argparse.Namespace(result=result, repository="o/r", commit="a" * 40)
                output = io.StringIO()
                with (
                    self.subTest(failure=failure),
                    mock.patch.object(gate, "GitHub", lambda: github),
                    mock.patch.object(factory_gate, "require", side_effect=failure) as require,
                    contextlib.redirect_stdout(output),
                ):
                    self.assertEqual(gate.command_baseline(arguments), 0)
            require.assert_called_once_with("publish")
            self.assertEqual(github.posts, [])
            self.assertIn("::notice::", output.getvalue())

    def test_draft_release_is_not_a_release(self):
        self.assertTrue(gate.baseline_needed(FakeGitHub(releases=[{"draft": True}]), "o/r"))


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.measuring = WORKFLOW.read_text(encoding="utf-8")
        workflow = WORKFLOW.with_name("factory-performance-baseline.yml")
        self.baseline = workflow.read_text(encoding="utf-8").split("\n  baseline:\n")[1]

    def steps(self):
        return re.split(r"\n    - ", self.baseline)[1:]

    def test_measuring_is_not_gated_and_never_sees_the_gate_token(self):
        self.assertNotIn("FACTORY_GATE_TOKEN", self.measuring)
        self.assertNotIn("factory/gate.py", self.measuring)
        self.assertNotIn(": write", self.measuring)

    def test_only_a_passed_measurement_is_stored(self):
        condition = re.search(r"\n    if: >-\n((?:      .*\n)+)", self.baseline)[1]
        self.assertIn("needs.measure.outputs.verdict == 'passed'", condition)
        for verdict in ("blocked", "unmeasured", "not-needed"):
            self.assertNotIn(verdict, condition)

    def test_measuring_for_the_baseline_waits_for_the_gate(self):
        text = WORKFLOW.with_name("factory-performance-baseline.yml").read_text(encoding="utf-8")
        jobs = text.split("\njobs:\n")[1]
        gate_job = re.split(r"\n  [a-z-]+:\n", jobs.split("\n  gate:\n")[1])[0]
        checkout, check = re.split(r"\n    - ", gate_job)[1:]
        self.assertIn("ref: main\n", checkout)
        self.assertIn("python3 -I scripts/factory/gate.py publish", check)
        self.assertNotIn("always()", gate_job)
        measure = re.split(r"\n  [a-z-]+:\n", jobs.split("\n  measure:\n")[1])[0]
        self.assertIn("    needs: gate\n", measure)
        self.assertIn("    if: needs.gate.outputs.allowed == 'true'\n", measure)
        self.assertNotIn("secrets", measure)

    def test_calibration_calls_the_gate_before_measuring(self):
        text = WORKFLOW.with_name("factory-performance-calibrate.yml").read_text(encoding="utf-8")
        checkout, check, *rest = re.split(r"\n    - ", text.split("\n    steps:\n")[1])
        self.assertIn("ref: main\n", checkout)
        self.assertTrue(check.endswith("run: python3 -I scripts/factory/gate.py job"))
        self.assertTrue(rest)
        self.assertNotRegex(text, r"always\(\)|failure\(\)|continue-on-error")

    def test_publish_gate_from_main_precedes_every_other_step(self):
        checkout, check, *rest = self.steps()
        self.assertIn("ref: main\n", checkout)
        self.assertIn("scripts/factory/gate.py publish", check)
        self.assertTrue(rest)
        for step in rest:
            self.assertIn("if: steps.gate.outputs.allowed == 'true'\n", step)

    def job(self, name):
        body = re.split(rf"\n  {name}:\n", self.measuring)[1]
        return re.split(r"\n  [a-z-]+:\n", body)[0]


    def test_head_is_built_on_a_different_runner_from_base(self):
        self.assertIn("needs.scope.outputs.head", self.job("build-head"))
        self.assertNotIn("scope.outputs.head }}", self.job("measure"))
        for name in ("build-head", "measure", "performance", "scope"):
            self.assertNotIn(": write", self.job(name))

    def verdict(self, scope, run, measure, reported):
        script = self.job("performance").split("run: |\n")[1]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "output")
            output.touch()
            completed = subprocess.run(
                ["bash", "-e", "-c", script], stdout=subprocess.DEVNULL,
                env={
                    "PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(output),
                    "SCOPE": scope, "RUN": run, "MEASURE": measure, "REPORTED": reported,
                },
            )
            return completed.returncode, output.read_text().strip()

    def test_only_measured_or_unneeded_changes_pass(self):
        self.assertEqual(self.verdict("success", "true", "success", "passed"), (0, "verdict=passed"))
        self.assertEqual(
            self.verdict("success", "false", "skipped", ""), (0, "verdict=not-needed")
        )
        for case, expected in (
            (("success", "true", "failure", "blocked"), "blocked"),
            (("success", "true", "failure", "unmeasured"), "unmeasured"),
            (("success", "true", "skipped", ""), "unmeasured"),
            (("success", "true", "success", ""), "unmeasured"),
            (("success", "true", "failure", "passed"), "unmeasured"),
            (("success", "unmeasured", "skipped", ""), "unmeasured"),
            (("success", "", "skipped", ""), "unmeasured"),
            (("failure", "false", "skipped", ""), "unmeasured"),
            (("cancelled", "", "skipped", ""), "unmeasured"),
        ):
            with self.subTest(case=case):
                self.assertEqual(self.verdict(*case), (1, f"verdict={expected}"))

    def test_gate_step_allows_only_on_success_and_never_fails_the_job(self):
        script = self.steps()[1].split("run: |\n")[1].split("\n\n")[0]
        for status, expected in ((0, "allowed=true\n"), (1, ""), (2, ""), (127, "")):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                fake = Path(directory, "python3")
                fake.write_text(f"#!/bin/sh\nexit {status}\n")
                fake.chmod(0o755)
                output = Path(directory, "output")
                output.touch()
                completed = subprocess.run(
                    ["bash", "-e", "-c", script], stdout=subprocess.DEVNULL,
                    env={
                        "PATH": f"{directory}:{os.environ['PATH']}",
                        "GITHUB_OUTPUT": str(output),
                    },
                )
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(output.read_text(), expected)


class HarnessTests(unittest.TestCase):
    def trees(self, directory):
        base, head = Path(directory, "base"), Path(directory, "head")
        for tree in (base, head):
            (tree / "bench").mkdir(parents=True)
            (tree / "bench/BenchmarkMain.hs").write_text(tree.name)
        return base, head

    def test_head_is_built_with_the_base_harness(self):
        with tempfile.TemporaryDirectory() as directory:
            base, head = self.trees(directory)
            (head / "bench/Cheat.hs").write_text("cheat")
            gate.use_base_harness(base, head)
            self.assertEqual((head / "bench/BenchmarkMain.hs").read_text(), "base")
            self.assertFalse((head / "bench/Cheat.hs").exists())

    def test_symlinked_harness_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            base, head = self.trees(directory)
            (head / "bench/BenchmarkMain.hs").unlink()
            (head / "bench").rmdir()
            (head / "bench").symlink_to(base / "bench")
            with self.assertRaises(gate.GateError):
                gate.use_base_harness(base, head)


def full_document(**overrides):
    result = {
        "scenario": "standalone",
        "operation": "mixed",
        "elapsed_seconds": 6.01,
        "config": {
            "host": "127.0.0.1", "port": int(gate.REDIS_PORT), "tls": False,
            "duration_seconds": 6, "warmup_seconds": 0, "concurrency": 16, "batch_size": 64,
            "mux_count": 1, "key_size_bytes": 32, "payload_size_bytes": 256,
            "timeout_ms": 5000, "response_delay_ms": None, "stall_after_requests": None,
        },
        "environment": {"environmentCapabilities": 1, "environmentRtsFlags": {}},
        "metrics": {
            "attempted_ops": 6010, "successful_ops": 6010, "errors": 0, "timeouts": 0,
            "ops_per_second": 1000.0, "allocation_bytes_per_op": 500.0,
            "latency_micros": {"p50": 500, "p95": 900, "p99": 1000, "p999": 2000},
        },
    }
    for path, value in overrides.items():
        target = result
        *parents, last = path.split("__")
        for key in parents:
            target = target[key]
        target[last] = value
    return result


class DocumentTests(unittest.TestCase):
    SERVER_CALLS = 6010 + 8192

    def test_matching_document_is_accepted(self):
        gate.check_document(full_document(), "standalone", self.SERVER_CALLS)

    def test_document_that_contradicts_the_run_is_refused(self):
        for override in (
            {"scenario": "cluster"}, {"operation": "ping"}, {"elapsed_seconds": 3.0},
            {"elapsed_seconds": 9.0}, {"elapsed_seconds": True}, {"config__concurrency": 1},
            {"config__duration_seconds": 1}, {"config__port": 1}, {"config": None},
            {"metrics__attempted_ops": 60100}, {"metrics__successful_ops": 10},
            {"metrics__attempted_ops": True}, {"metrics__ops_per_second": 5000.0},
            {"metrics__latency_micros__p95": 1500},
        ):
            with self.subTest(override=override), self.assertRaises(gate.GateError):
                gate.check_document(full_document(**override), "standalone", self.SERVER_CALLS)

    def test_operations_redis_never_saw_are_refused(self):
        with self.assertRaises(gate.GateError):
            gate.check_document(full_document(), "standalone", 8192)

    def test_hostile_json_is_refused(self):
        for text in (b"", b"[", b"NaN", b'{"a": Infinity}', b"[" * 100000, b"9" * 10000, b"\xff"):
            with self.subTest(text=text[:10]), self.assertRaises(gate.GateError):
                gate.parse_document(text)


class FakeRedis:
    """Counts as a server would; calls grow with each look."""

    def __init__(self, scenario, directory):
        self.looks = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def calls(self):
        self.looks += 1
        return {"get": self.looks * 10, "set": 6010 + 8192 - self.looks * 10}


class SamplerTests(unittest.TestCase):
    def binary(self, directory, name, text):
        path = Path(directory, name)
        path.write_text("#!/bin/sh\n" + text)
        path.chmod(0o755)
        return path

    def sampler(self, directory, head):
        good = f"sleep 0.4\ncat <<'EOF'\n{json.dumps(full_document())}\nEOF\n"
        binaries = {
            "base": self.binary(directory, "b", good),
            "head": self.binary(directory, "h", head or good),
        }
        sampler = gate.BenchmarkSampler(
            binaries, "none", redis=FakeRedis, settle=0.05, window=0.1
        )
        self.addCleanup(sampler.close)
        return sampler, binaries

    def test_throughput_comes_from_redis_not_the_measured_process(self):
        with tempfile.TemporaryDirectory() as directory:
            sampler, _ = self.sampler(directory, None)
            # The fake server serves the same total at every look.
            with self.assertRaisesRegex(gate.GateError, "throughput"):
                gate.extract(sampler("head", "standalone"))

    def test_leftover_processes_are_killed(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, "alive")
            leftover = f"(sleep 1; touch {marker}) >/dev/null 2>&1 &\n"
            sampler, _ = self.sampler(
                directory,
                leftover + f"sleep 0.4\ncat <<'EOF'\n{json.dumps(full_document())}\nEOF\n",
            )
            sampler("head", "standalone")
            time.sleep(1.2)
            self.assertFalse(marker.exists())

    def test_binary_changed_after_the_gate_started_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            sampler, _ = self.sampler(directory, None)
            stored = sampler.binaries["base"]
            stored.chmod(0o755)
            stored.write_text("tampered")
            with self.assertRaisesRegex(gate.GateError, "changed"):
                sampler("head", "standalone")

    def test_changing_the_original_does_not_affect_the_measured_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            sampler, binaries = self.sampler(directory, None)
            binaries["base"].write_text("tampered")
            sampler("base", "standalone")

    def test_unexpected_binary_hash_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = self.binary(directory, "b", "")
            with self.assertRaisesRegex(gate.GateError, "hash"):
                gate.BenchmarkSampler(
                    {"base": binary, "head": binary}, "none", expected={"base": "0" * 64}
                )

    def test_process_that_exits_early_or_floods_output_is_refused(self):
        for text in ("exit 1\n", "sleep 0.4\nexit 3\n", "yes\n"):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as directory:
                sampler, _ = self.sampler(directory, text)
                with self.assertRaises(gate.GateError):
                    sampler("head", "standalone")

    def test_different_runtime_flags_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            other = full_document(environment__environmentRtsFlags={"A": 64})
            sampler, _ = self.sampler(
                directory, f"sleep 0.4\ncat <<'EOF'\n{json.dumps(other)}\nEOF\n"
            )
            sampler("base", "standalone")
            with self.assertRaisesRegex(gate.GateError, "runtime"):
                sampler("head", "standalone")

    def test_containers_have_no_network_writable_mounts_or_privileges(self):
        servers = gate.container_options("servers", "none")
        benchmark = gate.container_options("head", "container:servers")
        for command in (servers, benchmark):
            for option in ("--read-only", "--cap-drop=ALL", "--user=65534:65534", "--pull=never",
                           "--security-opt=no-new-privileges"):
                self.assertIn(option, command)
            self.assertFalse([item for item in command if item.startswith("--publish")])
        self.assertIn("--network=none", servers)
        self.assertIn("--network=container:servers", benchmark)
        command = gate.benchmark_command("head", Path("/x/head"), "servers")
        self.assertNotIn("docker.sock", " ".join(command))
        self.assertIn("--network=container:servers", command)
        mounts = [item for item in command if item.startswith("--volume=")]
        self.assertTrue(mounts and all(mount.endswith(":ro") for mount in mounts))

    def test_fetching_libraries_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, "b")
            paths = [f"/nix/store/{n:032d}-x" for n in range(3)]
            binary.write_text(" ".join(paths))
            calls = []

            def run(command, **options):
                calls.append((command[-1], options["timeout"]))
                raise subprocess.TimeoutExpired(command, options["timeout"])

            with mock.patch.object(subprocess, "run", run):
                gate.realise_references(binary)
            self.assertEqual([path for path, _ in calls], paths)
            self.assertTrue(all(0 < limit <= gate.FETCH_SECONDS for _, limit in calls))
            calls.clear()
            with mock.patch.object(subprocess, "run", run), mock.patch.object(
                time, "monotonic", side_effect=[0, 0, gate.FETCH_SECONDS + 1]
            ):
                with self.assertRaises(gate.GateError):
                    gate.realise_references(binary)
            binary.write_text(" ".join(f"/nix/store/{n:032d}-x" for n in range(500)))
            with self.assertRaises(gate.GateError):
                gate.realise_references(binary)


class CalibrationTests(unittest.TestCase):
    def test_reports_variation_and_how_often_each_metric_would_flag(self):
        values = [document(p99=2000)] * 10 + [document(p99=3000)] * 10
        pending = iter(values)
        report = gate.calibrate(lambda build, scenario: next(pending), ["standalone"], 2)
        row = report["standalone/p99"]
        self.assertEqual(row["changes"], [0.0, 0.0])
        self.assertEqual(row["flagged_runs"], 0)
        self.assertEqual(row["sample_variation"], [0.0, 0.0])
        pending = iter(
            [document(p99=p) for p in (2000, 3000, 3000, 2000, 2000, 3000, 3000, 2000, 2000, 3000)]
        )
        row = gate.calibrate(lambda build, scenario: next(pending), ["standalone"], 1)[
            "standalone/p99"
        ]
        self.assertEqual((row["changes"], row["flagged_runs"]), ([0.5], 1))
        self.assertIn("standalone/p99", gate.render_calibration({"standalone/p99": row}))


if __name__ == "__main__":
    unittest.main()
