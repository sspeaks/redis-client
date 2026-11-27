#!/usr/bin/env python3
"""Block merges on measured performance regressions (docs/factory.md, Performance).

scope      decide whether a change needs measuring, and which gains it claims
build      build one tree's benchmark, optionally with another tree's bench/
run        measure base and head interleaved, and compare them
calibrate  measure one binary against itself, to learn how noisy a runner is
baseline   store the first passed result while no release exists

Exit codes: 0 passed, 1 blocked by measurements, 2 could not measure. 2 also blocks.

Rules. A run is five interleaved samples of each build. A metric regresses in a run
when head's median is over 10% worse than base's, or head's second-worst sample is
over 10% worse than base's worst. Any regression, or a claim, takes a second run. If
something regressed but no metric regressed in both, a third run decides. It blocks
only when the same metric regressed in two of the runs, such as the first and third.
Different metrics regressing in each of three runs pass. A claimed gain must show in
the medians of every scenario in every run. These are decision rules, not
significance tests.

Claims. A line exactly `Performance-claim: METRIC[, METRIC]` in the pull request body,
or in the body of an issue that body closes with one of GitHub's keywords: `#N`,
`GH-N`, `OWNER/REPO#N` or the issue's URL, in this repository. A reference in
emphasis or a link (`closes **#5**`, `Closes [#5](url)`) is followed too; whether
GitHub closes the issue through those forms was not tested, but following one can
only find more claims. Labels that look like a claim (`Throughput claim:`,
`Claimed performance gain:`) are refused. Not seen: claims in prose, in comments or titles, in issues of
other repositories, or in issues linked only through the Development sidebar.
Anyone who can edit such an issue can add a claim, or a near-miss, and so block the
pull request. That fails closed; remove the line or the link to clear it.

Verdict. A check's name can be imitated. The merge gate (#193) must:
  1. call performance.yml with workflow_call from a workflow on main;
  2. pass the exact current main commit as `base` and the exact commit it would merge,
     containing that base, as `head`;
  3. accept only `passed` or `not-needed`; anything else, including empty, refuses;
  4. pass the pull request body as `claim_text`, grant `contents: read` and
     `issues: read`, leave `baseline_only` unset, and pass no secrets;
  5. measure again whenever main moves or head changes.

Measuring is not subject to the factory kill switch or pause: it writes nothing,
applies to every pull request, and a skipped required check would count as passing.
Storing the baseline is a publish, so `baseline` asks gate.py immediately before
each write. A refusal skips the write and exits 0; it is not a performance failure.

Residual risks:
  * Head code runs inside the process being measured. Throughput is taken from
    Redis's own counters, and operation count, duration and config are checked
    against what was asked. p99 and allocation are only reported by that process, so
    code written to forge them can. It could also send useless commands, attack
    its own sample's Redis, or behave well only under this workload. Review is the
    defense against that.
  * Each sample's servers and benchmark share a network namespace holding only
    loopback: no host, metadata service, internet or other sample. The kernel and
    the Docker runtime are still shared with the runner.
  * head's build has its own runner, but a job's internal token can create artifacts
    in its run and write caches. Nothing here reads a cache. Only head's own binary
    crosses between jobs as an artifact before the verdict, and the verdict is a job
    output that head's build cannot set. If that build takes the results artifact's
    name, the upload fails and the verdict is unmeasured. The baseline is the one
    thing read from an artifact after the verdict; both its builds are from main,
    and it is bounded, reduced to numbers, and never evidence.
  * head's app/, .cabal files and flags are part of what is measured.
  * Regressions of 10% or less, or that show in one sample in five, pass, and can
    accumulate across pull requests. The stored baseline's numbers are from another
    machine and are not evidence. To check for accumulation, build the baseline or
    release commit and the new commit, then `run` them together on one runner.
  * test/*.hs is out of scope. A .cabal change is measured, but one that made test/
    part of the library would let a later test/ change go unmeasured.
  * `--isolation none` is for local use: a process that leaves its process group
    survives. CI uses one container per sample.
"""

import argparse
import contextlib
import difflib
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import commit_id
import gate as factory_gate

SAMPLES = 5
THRESHOLD = 0.10
MAX_GAIN = 5  # A bigger improvement is more likely a broken measurement.
DURATION = 6
PREPOPULATED = 8192  # BenchmarkMain's prepopulateItemCount for the settings below.
MAX_OUTPUT = 1 << 20
# The pinned image in docker/standalone; it only provides a root filesystem.
IMAGE = (
    "redis:7.2.12@sha256:16623900b6ddd58e8bac04ccb6b611b9a5d1aed165453e28bcaed251d549d62c"
)
CLAIM_PREFIX = "Performance-claim: "
TICKET = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+[*_\[]{0,3}"
    r"(?:https?://(?:www\.)?github\.com/(?P<url>[\w.-]+/[\w.-]+)/issues/"
    r"|(?P<repository>[\w.-]+/[\w.-]+)?#|GH-)(?P<number>\d{1,9})(?![^\W_])",
    re.IGNORECASE,
)
MAX_TICKETS = 20
# Labels, without spaces or punctuation, that can only be a misspelled claim.
_CLAIMED = r"(?:perf|performance|throughput|p99|latency|allocations?)"
CLAIM_LABEL = re.compile(
    rf"(?:perf|performance)(?:gains?|improvements?)"
    rf"|{_CLAIMED}?claim(?:s|ed)?{_CLAIMED}?(?:gains?|improvements?)?"
)
FETCH_SECONDS = 600
MAX_FETCHES = 200
BASELINE_BRANCH = "factory-performance-baseline"
BASELINE_FILE = "performance-baseline.json"
SCENARIOS = ("standalone", "cluster")
SCRIPTS = Path(__file__).resolve().parents[1]
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")
CLUSTER_PORTS = os.environ.get("CLUSTER_PORTS", "7000 7001 7002").split()

# Metric name: (path in the benchmark document, whether larger is better).
METRICS = {
    "throughput": (("metrics", "ops_per_second"), True),
    "p99": (("metrics", "latency_micros", "p99"), False),
    "allocation": (("metrics", "allocation_bytes_per_op"), False),
}

PORTS = {"standalone": REDIS_PORT, "cluster": CLUSTER_PORTS[0]}
BOUNDS = {"throughput": (1, 1e7), "p99": (1, 6e6), "allocation": (16, 1e9)}

# Everything else, including paths nobody has thought of yet, is measured. Symlinks
# and submodules are always measured, whatever their path.
IRRELEVANT = re.compile(
    r"^docs/.*\.(?:md|json|png|svg)$"
    r"|^(?:hask-redis-mux/)?[^/]+\.md$"
    r"|^(?:hask-redis-mux/)?test/.*\.hs$"
    r"|^docker/.*\.(?:ya?ml|conf|sh|md)$"
    r"|^scripts/(?:AGENTS\.md|test[-_][^/]*\.(?:py|sh))$"
    r"|^scripts/factory/(?!performance_gate\.py$|gate\.py$)[^/]+\.py$"
    r"|^\.github/(?!workflows/(?:factory-)?performance).*\.(?:ya?ml|md|py)$"
    r"|^(?:\.githooks|\.vscode)/"
    r"|^(?:LICENSE|Makefile|renovate\.json|hie\.yaml|\.gitignore|\.envrc)$"
)


class GateError(Exception):
    """The change could not be measured."""


def load_compare_script():
    spec = importlib.util.spec_from_file_location(
        "compare_benchmark_results", SCRIPTS / "compare-benchmark-results.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMPARE = load_compare_script()


def is_relevant(path, modes=("100644", "100644")):
    if any(mode not in ("000000", "100644", "100755") for mode in modes):
        return True
    return not IRRELEVANT.search(path)


def changed_paths(base, head, directory="."):
    """[(path, (old mode, new mode))] for every changed path."""
    fields = subprocess.run(
        ["git", "-C", directory, "diff", "--raw", "--no-renames", "--abbrev=40", "-z", base, head],
        check=True, stdout=subprocess.PIPE, text=True, errors="surrogateescape",
    ).stdout.split("\0")[:-1]
    return [
        (path, tuple(entry.lstrip(":").split()[:2]))
        for entry, path in zip(fields[::2], fields[1::2], strict=True)
    ]


def parse_claims(text):
    """Claimed metrics. A line that only resembles a claim is refused, not ignored."""
    claims = set()
    for line in (text or "").splitlines():
        plain = "".join(
            character for character in unicodedata.normalize("NFKC", line).casefold()
            if unicodedata.category(character) != "Cf"
        )
        # The words with any punctuation before a colon, or leading a line, or a label
        # that can only be meant as one.
        label = re.sub(r"[\W_]+", "", re.split(r"[:=]| - ", plain, maxsplit=1)[0])
        labelled = re.search(r"[:=]| - ", plain) and (
            CLAIM_LABEL.fullmatch(label)
            or difflib.SequenceMatcher(None, label, "performanceclaim").ratio() > 0.85
        )
        if not (
            re.search(r"performance[\W_]*claims?[\W_]*:", plain)
            or re.sub(r"[\W_]+", "", plain).startswith("performanceclaim")
            or labelled
        ):
            continue
        metrics = line.removeprefix(CLAIM_PREFIX).split(", ")
        if not line.startswith(CLAIM_PREFIX) or any(metric not in METRICS for metric in metrics):
            raise GateError(
                f"not a valid performance claim: {line!r}; "
                f"write {CLAIM_PREFIX!r} followed by {', '.join(METRICS)}"
            )
        claims.update(metrics)
    return sorted(claims)


def tickets(text, repository):
    """Issues in this repository that the text closes, as GitHub reads it."""
    numbers = set()
    for link in TICKET.finditer(text or ""):
        other = link["url"] or link["repository"] or repository
        if other.casefold() == repository.casefold():
            numbers.add(int(link["number"]))
    if len(numbers) > MAX_TICKETS:
        raise GateError(f"the text closes more than {MAX_TICKETS} tickets")
    return sorted(numbers)


def all_claims(github, repository, text):
    """Claims in a pull request body and in the tickets it closes."""
    claims = set(parse_claims(text))
    for ticket_number in tickets(text, repository):
        ticket = github.get(f"repos/{repository}/issues/{ticket_number}")
        if ticket is None:
            raise GateError(f"ticket #{ticket_number} does not exist")
        claims.update(parse_claims(ticket["body"]))
    return sorted(claims)


def number(value, what):
    # Exact types: bool is an int, and float() of a huge int raises.
    if type(value) not in (int, float) or not -1e15 < value < 1e15:
        raise GateError(f"{what} is not a plausible number")
    return value


def lookup(document, *path):
    try:
        return COMPARE.lookup(document, path)
    except (KeyError, TypeError, IndexError) as error:
        raise GateError(f"malformed benchmark document: {error!r}") from error


def extract(document):
    for key in ("errors", "timeouts"):
        count = lookup(document, "metrics", key)
        if type(count) is not int or count:
            raise GateError(f"benchmark did not report zero {key}")
    values = {}
    for name, (path, _) in METRICS.items():
        values[name] = number(lookup(document, *path), name)
        low, high = BOUNDS[name]
        if not low <= values[name] <= high:
            raise GateError(f"benchmark reported implausible {name}={values[name]!r}")
    return values


def parse_document(text):
    def refuse(constant):
        raise ValueError(f"{constant} is not JSON")

    try:
        return json.loads(text.decode(), parse_constant=refuse)
    except (ValueError, RecursionError) as error:
        raise GateError(f"benchmark wrote invalid JSON: {error}") from error


def check_document(document, scenario, server_calls):
    """Check a document against what was asked for and what Redis saw."""
    config = {
        "host": "127.0.0.1", "port": int(PORTS[scenario]), "tls": False,
        "duration_seconds": DURATION, "warmup_seconds": 0, "concurrency": 16,
        "batch_size": 64, "mux_count": 1, "key_size_bytes": 32, "payload_size_bytes": 256,
        "timeout_ms": 5000, "response_delay_ms": None, "stall_after_requests": None,
    }
    for key, wanted in (("scenario", scenario), ("operation", "mixed"), ("config", config)):
        if lookup(document, key) != wanted:
            raise GateError(f"benchmark reported a different {key}")
    elapsed = number(lookup(document, "elapsed_seconds"), "elapsed time")
    if not DURATION <= elapsed <= DURATION + 2:
        raise GateError(f"benchmark reported {elapsed}s for a {DURATION}s run")
    attempted = number(lookup(document, "metrics", "attempted_ops"), "operation count")
    if attempted <= 0 or attempted != lookup(document, "metrics", "successful_ops"):
        raise GateError(
            f"not all of {attempted} operations succeeded: "
            f"errors={lookup(document, 'metrics', 'errors')!r:.40}, "
            f"timeouts={lookup(document, 'metrics', 'timeouts')!r:.40}"
        )
    seen = server_calls - PREPOPULATED
    if abs(seen - attempted) > 0.01 * attempted:
        raise GateError(f"benchmark reported {attempted} operations; Redis saw {seen}")
    rate = number(lookup(document, "metrics", "ops_per_second"), "throughput")
    if abs(rate - attempted / elapsed) > 0.01 * rate:
        raise GateError("benchmark throughput contradicts its own operation count")
    latencies = [
        number(lookup(document, "metrics", "latency_micros", key), key)
        for key in ("p50", "p95", "p99", "p999")
    ]
    if latencies != sorted(latencies):
        raise GateError("benchmark latency percentiles are out of order")


def summarize(values):
    return {
        "samples": values,
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": round(statistics.stdev(values), 2),
    }


def measure(sampler, scenarios):
    """One run: every metric of every scenario, compared on medians."""
    run = {}
    for scenario in scenarios:
        samples = {"base": [], "head": []}
        for index in range(SAMPLES):
            # Alternating the order keeps slow drift from favouring one build.
            for build_name in ("base", "head") if index % 2 == 0 else ("head", "base"):
                samples[build_name].append(extract(sampler(build_name, scenario)))
        for metric, (_, larger_is_better) in METRICS.items():
            base, head = (
                summarize([sample[metric] for sample in samples[build_name]])
                for build_name in ("base", "head")
            )
            change = (head["median"] - base["median"]) / base["median"]
            # Two bad samples in five do not move a median.
            worst_base = base["min"] if larger_is_better else base["max"]
            second_worst = sorted(head["samples"], reverse=not larger_is_better)[1]
            tail = (second_worst - worst_base) / worst_base
            gain, tail_gain = (
                (change, tail) if larger_is_better else (-change, -tail)
            )
            ratio = head["median"] / base["median"]
            if (ratio if larger_is_better else 1 / ratio) > MAX_GAIN:
                raise GateError(f"{scenario}/{metric} improved implausibly ({change:+.0%})")
            run[f"{scenario}/{metric}"] = {
                "base": base,
                "head": head,
                "change": change,
                "tail_change": tail,
                "regressed": -gain > THRESHOLD or -tail_gain > THRESHOLD,
                "improved": gain > THRESHOLD,
            }
    return run


def evaluate(sampler, scenarios, claims=()):
    """Measure, and measure again while there is something to confirm."""
    runs, flagged = [], []

    def measure_again():
        runs.append(measure(sampler, scenarios))
        flagged.append({name for name, row in runs[-1].items() if row["regressed"]})

    def repeated():
        names = set().union(*flagged)
        return sorted(name for name in names if sum(name in run for run in flagged) > 1)

    measure_again()
    if claims or flagged[0]:
        measure_again()
        if any(flagged) and not repeated():
            measure_again()
    regressions = repeated()
    unproven = [
        claim for claim in claims
        if not all(run[f"{scenario}/{claim}"]["improved"] for run in runs for scenario in scenarios)
    ]
    return {
        "schema_version": 2,
        "threshold": THRESHOLD,
        "claims": list(claims),
        "runs": runs,
        "regressions": regressions,
        "unproven_claims": unproven,
        "passed": not (regressions or unproven),
    }


def calibrate(sampler, scenarios, runs):
    """Both builds are the same binary, so every difference is noise."""
    measured = [measure(sampler, scenarios) for _ in range(runs)]
    return {
        name: {
            "changes": [run[name]["change"] for run in measured],
            "sample_variation": [
                round(statistics.stdev(values) / statistics.mean(values), 4)
                for run in measured
                for values in [run[name]["base"]["samples"] + run[name]["head"]["samples"]]
            ],
            "flagged_runs": sum(run[name]["regressed"] for run in measured),
            "runs": [run[name] for run in measured],
        }
        for name in measured[0]
    }


def render_calibration(report):
    lines = [
        "## Base against itself",
        "",
        "| Metric | Runs | Median change (min to max) | Variation within a run (min to max) "
        "| Runs the current rule flags |",
        "| --- | --- | --- | --- | --- |",
    ]
    for name, row in report.items():
        changes, variation = row["changes"], row["sample_variation"]
        lines.append(
            f"| {name} | {len(changes)} | {min(changes):+.1%} to {max(changes):+.1%} "
            f"| {min(variation):.1%} to {max(variation):.1%} | {row['flagged_runs']} |"
        )
    return "\n".join(lines) + "\n"


def render(result):
    def cell(summary):
        return (
            f"{summary['median']:,.0f} ({summary['min']:,.0f}-{summary['max']:,.0f}, "
            f"sd {summary['stdev']:,.0f})"
        )

    lines = ["## Performance gate: " + ("passed" if result["passed"] else "BLOCKED"), ""]
    for label, names in (
        ("Repeated regression", result["regressions"]),
        ("Claimed gain not shown", result["unproven_claims"]),
    ):
        lines += [f"- {label}: {name}" for name in names]
    for number, run in enumerate(result["runs"], 1):
        lines += [
            "",
            f"### Run {number}",
            "",
            f"Median (min-max, standard deviation) of {SAMPLES} interleaved samples.",
            "",
            "| Metric | Base | Head | Change | |",
            "| --- | --- | --- | --- | --- |",
        ]
        for name, row in run.items():
            note = "regressed" if row["regressed"] else "improved" if row["improved"] else ""
            lines.append(
                f"| {name} | {cell(row['base'])} | {cell(row['head'])} "
                f"| {row['change']:+.1%} | {note} |"
            )
    return "\n".join(lines) + "\n"


def use_base_harness(base, head):
    """A change must not be able to edit the benchmark that judges it."""
    if (base / "bench").is_symlink() or (head / "bench").is_symlink():
        raise GateError("bench/ is a symlink")
    if (head / "bench").exists():
        shutil.rmtree(head / "bench")
    shutil.copytree(base / "bench", head / "bench", symlinks=True)


def build(tree):
    command = "cabal build redis-client-benchmark >&2 && cabal list-bin redis-client-benchmark"
    completed = subprocess.run(
        ["nix-shell", "--run", command], cwd=tree, stdout=subprocess.PIPE, text=True
    )
    lines = completed.stdout.split()
    if completed.returncode or not lines:
        raise GateError(
            f"could not build the benchmark in {tree}; the head is built with the "
            "base's bench/, so a change to what bench/ uses needs the maintainer"
        )
    return lines[-1]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Redis:
    """Fresh servers for one sample, so no sample can reconfigure another's."""

    container = None

    def __init__(self, scenario, directory):
        self.scenario, self.directory = scenario, directory

    def __enter__(self):
        try:
            self.start()
            for _ in range(50):
                if all(self.cli(port, "ping") == "PONG" for port in self.ports()):
                    break
                time.sleep(0.1)
            else:
                raise GateError(f"Redis did not start for {self.scenario}")
            self.check_started()
            if sum(self.calls().values()):
                raise GateError("Redis was already in use")
        except BaseException:
            self.__exit__()
            raise
        return self

    def __exit__(self, *_):
        self.stop()

    def ports(self):
        return CLUSTER_PORTS if self.scenario == "cluster" else [REDIS_PORT]

    def cli(self, port, *command):
        return subprocess.run(
            [*self.prefix(), "redis-cli", "-h", "127.0.0.1", "-p", port, *command],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10,
        ).stdout.strip()

    def calls(self):
        """How many GET and SET commands the servers have executed."""
        counts = {"get": 0, "set": 0}
        for port in self.ports():
            stats = self.cli(port, "info", "commandstats")
            if "# Commandstats" not in stats:
                raise GateError(f"Redis on port {port} stopped answering")
            for name in counts:
                found = re.search(rf"^cmdstat_{name}:calls=(\d+),", stats, re.MULTILINE)
                counts[name] += int(found[1]) if found else 0
        return counts


SERVER = ["redis-server", "--save", "", "--appendonly", "no", "--bind", "127.0.0.1",
          "--port", REDIS_PORT]


class LocalRedis(Redis):
    """Servers on this machine, for local use."""

    server = None

    def prefix(self):
        return []

    def cluster(self, action, check=True):
        subprocess.run(
            [SCRIPTS / "benchmark-cluster.sh", action, Path(self.directory, "cluster")],
            check=check, stdout=sys.stderr, timeout=120,
        )

    def start(self):
        if self.scenario == "cluster":
            self.cluster("start")
        else:
            self.server = subprocess.Popen(SERVER, stdout=subprocess.DEVNULL)
            time.sleep(0.5)

    def check_started(self):
        # A server already on the port would answer while ours exits.
        if self.server is not None and self.server.poll() is not None:
            raise GateError(f"redis-server could not start on port {REDIS_PORT}")

    def stop(self):
        if self.scenario == "cluster":
            self.cluster("stop", check=False)
        if self.server is not None:
            self.server.kill()
            self.server.wait()


class ContainerRedis(Redis):
    """Servers in a network namespace that holds nothing but loopback."""

    def __init__(self, scenario, directory):
        super().__init__(scenario, directory)
        self.container = f"factory-performance-{uuid.uuid4().hex}"

    def prefix(self):
        return ["docker", "exec", self.container]

    def start(self):
        script = SCRIPTS / "benchmark-cluster.sh"
        docker(
            *container_options(self.container, "none"), "--detach", "--init",
            "--tmpfs=/tmp:size=2g", f"--volume={script}:/benchmark-cluster.sh:ro",
            "--workdir=/tmp", "--entrypoint=sleep", IMAGE, "600",
        )
        if self.scenario == "cluster":
            docker(
                "exec", f"--env=CLUSTER_PORTS={' '.join(CLUSTER_PORTS)}", self.container,
                "bash", "/benchmark-cluster.sh", "start", "/tmp/cluster",
            )
        else:
            docker("exec", "--detach", self.container, *SERVER)

    def check_started(self):
        pass

    def stop(self):
        remove_container(self.container)


def docker(*arguments):
    return subprocess.run(
        ["docker", *arguments], check=True, stdout=subprocess.PIPE, text=True, timeout=120
    ).stdout


def remove_container(name):
    """Kill everything in a container, and make sure of it."""
    subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=60)
    if docker("ps", "--all", "--quiet", "--filter", f"name={name}"):
        raise GateError(f"container {name} did not stop")


def container_options(name, network):
    return [
        "run", "--rm", "--pull=never", f"--name={name}", f"--network={network}",
        "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
        "--user=65534:65534", "--pids-limit=512", "--memory=4g",
    ]


def benchmark_command(name, binary, servers):
    return [
        "docker", *container_options(name, f"container:{servers}"),
        f"--volume={binary}:/benchmark:ro", "--volume=/nix/store:/nix/store:ro",
        "--entrypoint=/benchmark", IMAGE,
    ]


class BenchmarkSampler:
    """Runs one build once, and checks what it reports."""

    def __init__(self, binaries, isolation, expected=None, redis=None, settle=0.5, window=4):
        self.isolation = isolation
        self.redis = redis or (ContainerRedis if isolation == "docker" else LocalRedis)
        self.settle, self.window = settle, window
        self.directory = tempfile.TemporaryDirectory()
        self.binaries, self.hashes, self.runtime = {}, {}, None
        for name, source in binaries.items():
            # Our own copy, so nothing that can reach the original matters.
            copy = Path(self.directory.name, f"{name}-benchmark")
            shutil.copyfile(source, copy)
            copy.chmod(0o555)
            self.binaries[name], self.hashes[name] = copy, sha256(copy)
            if (expected or {}).get(name, self.hashes[name]) != self.hashes[name]:
                self.close()
                raise GateError(f"{name} binary does not have the expected hash")
        # The container runs as another user, which must be able to reach the copies.
        Path(self.directory.name).chmod(0o755)

    def close(self):
        self.directory.cleanup()

    def __call__(self, build_name, scenario):
        for name, path in self.binaries.items():
            if sha256(path) != self.hashes[name]:
                raise GateError(f"{name} binary changed during measurement")
        try:
            with tempfile.TemporaryDirectory() as work, self.redis(scenario, work) as redis:
                throughput, text = self.run(build_name, scenario, redis, work)
                document = parse_document(text)
                check_document(document, scenario, sum(redis.calls().values()))
        except (subprocess.SubprocessError, OSError) as error:
            raise GateError(f"{build_name} {scenario} sample failed: {error}") from error
        runtime = {
            key: lookup(document, "environment", key)
            for key in ("environmentCapabilities", "environmentRtsFlags")
        }
        self.runtime = self.runtime or runtime
        if runtime != self.runtime:
            raise GateError(f"{build_name} ran with different runtime settings")
        # Measured by Redis and our clock, not by the process being judged.
        document["metrics"]["ops_per_second"] = throughput
        print(
            f"{scenario} {build_name}: throughput={throughput:.0f} "
            f"p99={lookup(document, 'metrics', 'latency_micros', 'p99')} "
            f"allocation={lookup(document, 'metrics', 'allocation_bytes_per_op')}",
            file=sys.stderr, flush=True,
        )
        return document

    def run(self, build_name, scenario, redis, work):
        # 1024 requests in flight keep p99 in the milliseconds, well clear of the
        # benchmark's 50 microsecond histogram buckets. With no warmup, every
        # operation Redis counts after prepopulation is a measured one.
        arguments = [
            "--scenario", scenario, "--host", "127.0.0.1", "--port", PORTS[scenario],
            "--duration", str(DURATION), "--warmup", "0", "--concurrency", "16",
            "--batch-size", "64", "--operation", "mixed", "--timeout-ms", "5000",
            "+RTS", "-T", "-RTS",
        ]
        container = f"factory-performance-{uuid.uuid4().hex}"
        prefix = [str(self.binaries[build_name])]
        if self.isolation == "docker":
            prefix = benchmark_command(container, self.binaries[build_name], redis.container)
        output = Path(work, "output")
        with output.open("wb") as stream:
            process = subprocess.Popen(
                prefix + arguments, stdin=subprocess.DEVNULL, stdout=stream,
                start_new_session=True,
            )
        try:
            throughput = self.observe(process, redis, output)
            deadline = time.monotonic() + 60
            while process.poll() is None:
                self.check_running(output, deadline)
                time.sleep(0.05)
        finally:
            self.kill(process, container)
        if process.returncode:
            raise GateError(f"{build_name} {scenario} benchmark exited {process.returncode}")
        if output.stat().st_size > MAX_OUTPUT:
            raise GateError("benchmark wrote too much output")
        return throughput, output.read_bytes()

    def check_running(self, output, deadline):
        if output.stat().st_size > MAX_OUTPUT:
            raise GateError("benchmark wrote too much output")
        if time.monotonic() > deadline:
            raise GateError("benchmark took too long")

    def observe(self, process, redis, output):
        """Operations per second over a fixed window inside the measured phase."""
        deadline = time.monotonic() + 60
        # Prepopulation only sets, so the first GET starts the measured phase.
        while not redis.calls()["get"]:
            if process.poll() is not None:
                raise GateError("benchmark exited before it was measured")
            self.check_running(output, deadline)
            time.sleep(0.05)
        time.sleep(self.settle)
        start, before = time.monotonic(), sum(redis.calls().values())
        time.sleep(self.window)
        end, after = time.monotonic(), sum(redis.calls().values())
        if process.poll() is not None:
            raise GateError("benchmark exited before the measurement window ended")
        return (after - before) / (end - start)

    def kill(self, process, container):
        """Nothing a sample started may outlive it."""
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signal.SIGKILL)
        if self.isolation == "docker":
            remove_container(container)
        process.wait(timeout=60)


def realise_references(binary):
    """Fetch the store paths a binary built elsewhere needs. Nix verifies signatures,
    and paths already present are never replaced. What cannot be fetched is left to
    fail when the binary runs."""
    references = sorted(
        set(re.findall(rb"/nix/store/[a-z0-9]{32}-[\w.+-]+", binary.read_bytes()))
    )
    if len(references) > MAX_FETCHES:
        raise GateError(f"head's binary refers to more than {MAX_FETCHES} store paths")
    deadline = time.monotonic() + FETCH_SECONDS
    for path in references:
        if os.path.exists(path):
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GateError("fetching the libraries head's binary needs took too long")
        with contextlib.suppress(subprocess.TimeoutExpired):
            subprocess.run(
                ["nix-store", "--realise", path.decode()], capture_output=True,
                timeout=min(remaining, 120),
            )


class GitHub:
    def api(self, *arguments, body=None):
        return subprocess.run(
            ["gh", "api", *arguments], input=body, capture_output=True, text=True
        )

    def get(self, path):
        """Return the document, or None when it does not exist."""
        completed = self.api(path)
        if completed.returncode:
            if "HTTP 404" in completed.stderr:
                return None
            raise GateError(f"GET {path}: {completed.stderr.strip()}")
        return json.loads(completed.stdout)

    def post(self, path, body):
        completed = self.api("--method", "POST", path, "--input", "-", body=json.dumps(body))
        if completed.returncode:
            raise GateError(f"POST {path}: {completed.stderr.strip()}")
        return json.loads(completed.stdout)


def baseline_needed(github, repository):
    releases = github.get(f"repos/{repository}/releases?per_page=100")
    if releases is None:
        raise GateError("could not list releases")
    if any(not release["draft"] for release in releases):
        return False
    return github.get(f"repos/{repository}/git/ref/heads/{BASELINE_BRANCH}") is None


def baseline_samples(result):
    """Only known metric names and plain numbers; nothing else from a run is stored."""
    names = {f"{scenario}/{metric}" for scenario in SCENARIOS for metric in METRICS}
    runs = lookup(result, "runs")
    if type(runs) is not list or not 1 <= len(runs) <= 3:
        raise GateError("result does not have one to three runs")
    samples = []
    for run in runs:
        if type(run) is not dict or not run or not set(run) <= names:
            raise GateError("result is not a performance result")
        kept = {}
        for name in sorted(run):
            values = lookup(run, name, "head", "samples")
            if type(values) is not list or len(values) not in range(1, SAMPLES + 1):
                raise GateError("result is not a performance result")
            kept[name] = [number(value, name) for value in values]
        samples.append(kept)
    return samples


def store_baseline(github, repository, result, commit, authorize):
    """Create the baseline branch. Creating a ref is atomic, so the first result wins.

    `authorize` is called immediately before each write and raises to refuse it.
    """
    if not commit_id.is_commit_id(commit):
        raise GateError("baseline commit is not a full hash")
    if type(result) is not dict or result.get("passed") is not True:
        raise GateError("only a passed result can be the baseline")
    content = json.dumps({
        "schema_version": 1,
        "note": "Not evidence. To compare, rebuild this commit on the same runner.",
        "commit": commit,
        "samples": baseline_samples(result),
    }, indent=2) + "\n"
    if not baseline_needed(github, repository):
        return False

    def write(kind, body):
        authorize()
        return github.post(f"repos/{repository}/git/{kind}", body)

    tree = write("trees", {"tree": [
        {"path": BASELINE_FILE, "mode": "100644", "type": "blob", "content": content},
    ]})
    commit_object = write("commits", {
        "message": f"Record performance baseline for {commit}",
        "tree": tree["sha"], "parents": [],
    })
    write("refs", {"ref": f"refs/heads/{BASELINE_BRANCH}", "sha": commit_object["sha"]})
    return True


def authorize_publish():
    try:
        factory_gate.require("publish")
    except Exception as error:  # A broken gate refuses too.
        raise factory_gate.Refused(str(error) or type(error).__name__) from error


def command_scope(arguments):
    claims = all_claims(GitHub(), arguments.repository, os.environ.get("CLAIM_TEXT"))
    needed = bool(claims) or any(
        is_relevant(path, modes) for path, modes in changed_paths(arguments.base, arguments.head)
    )
    if needed and arguments.baseline_only:
        needed = baseline_needed(GitHub(), arguments.repository)
    print(f"run={'true' if needed else 'false'}")
    print(f"claims={','.join(claims)}")
    return 0


def command_build(arguments):
    tree = arguments.tree.resolve()
    if arguments.harness:
        use_base_harness(arguments.harness.resolve(), tree)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(build(tree), arguments.output)
    print(f"sha256={sha256(arguments.output)}")
    return 0


def report(text, document, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(text)


def command_run(arguments):
    claims = [claim for claim in arguments.claims.split(",") if claim]
    if not set(claims) <= set(METRICS):
        raise GateError("unknown performance claim")
    if arguments.isolation == "docker":
        realise_references(arguments.head)
    sampler = BenchmarkSampler(
        {"base": arguments.base, "head": arguments.head}, arguments.isolation,
        expected={"base": arguments.base_sha256} if arguments.base_sha256 else None,
    )
    with contextlib.closing(sampler):
        result = evaluate(sampler, SCENARIOS, claims)
    result["sha256"] = sampler.hashes
    report(render(result), result, arguments.output)
    return 0 if result["passed"] else 1


def command_calibrate(arguments):
    sampler = BenchmarkSampler(
        {"base": arguments.binary, "head": arguments.binary}, arguments.isolation
    )
    with contextlib.closing(sampler):
        result = calibrate(sampler, SCENARIOS, arguments.runs)
    report(render_calibration(result), result, arguments.output)
    return 0


def command_baseline(arguments):
    with arguments.result.open("rb") as stream:
        text = stream.read(MAX_OUTPUT + 1)
    if len(text) > MAX_OUTPUT:
        raise GateError("the result is too large")
    result = parse_document(text)
    try:
        stored = store_baseline(
            GitHub(), arguments.repository, result,
            arguments.commit, authorize_publish,
        )
    except factory_gate.Refused as error:
        print(f"::notice::Baseline not stored; the factory gate refused: {error}")
        return 0
    print("Stored the baseline." if stored else "A release or baseline already exists.")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(required=True)
    scope = commands.add_parser("scope")
    scope.add_argument("base")
    scope.add_argument("head")
    scope.add_argument("--baseline-only", action="store_true",
                       help="measure only when a baseline still has to be stored")
    scope.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    scope.set_defaults(handler=command_scope)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("tree", type=Path, help="disposable checkout")
    build_parser.add_argument("--harness", type=Path, help="checkout whose bench/ is used")
    build_parser.add_argument("--output", type=Path, required=True)
    build_parser.set_defaults(handler=command_build)
    run = commands.add_parser("run")
    run.add_argument("--base", type=Path, required=True, help="benchmark binary")
    run.add_argument("--base-sha256", help="refuse any other base binary")
    run.add_argument("--head", type=Path, required=True, help="benchmark binary")
    run.add_argument("--claims", default="")
    run.set_defaults(handler=command_run)
    calibration = commands.add_parser("calibrate")
    calibration.add_argument("binary", type=Path)
    calibration.add_argument("--runs", type=int, default=10)
    calibration.set_defaults(handler=command_calibrate)
    for command in (run, calibration):
        command.add_argument("--isolation", choices=("docker", "none"), default="docker")
        command.add_argument("--output", type=Path, required=True)
    baseline = commands.add_parser("baseline")
    baseline.add_argument("result", type=Path)
    baseline.add_argument("--commit", required=True)
    baseline.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    baseline.set_defaults(handler=command_baseline)
    arguments = parser.parse_args()
    try:
        return arguments.handler(arguments)
    except (GateError, subprocess.SubprocessError, OSError, ValueError) as error:
        print(f"performance gate: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
