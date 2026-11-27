#!/usr/bin/env python3
"""Run one sandboxed agent on the Claude subscription.

Reads the token from stdin, so it is in no environment or command line here.
Writes result.json, agent.patch, agent.jsonl, agent.stderr and
proxy-events.jsonl to --output, and `outcome`, `usage_limit` and `searched` to
GITHUB_OUTPUT. --output appears only once every file in it has been searched for
the token; until then they are in a private directory, even if this process is
killed. Upload it only if `searched` is true.
Output from the container goes to files only, never to the job log, where it
could be read as workflow commands.

Exit status: 0 success, 1 the run failed, 2 the run was refused, 3 usage limit.

The outcome `success` means the agent finished; apart from the model replies,
the evidence for that comes from the container. It is never evidence that the
work is right: check the patch in a fresh container, as check_proof.py does.

In a workflow, run this in a step named `factory-agent-run` of a job whose name
starts with `factory-agent`: run limits are counted from those names.
factory-proof.yml shows the steps around it. A re-run of a job is refused,
because it would reuse an approval and what earlier jobs checked; dispatch anew.
"""

import argparse
import collections
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import proxy
from workspace_patch import Baseline, PatchRefused

MAX_TURNS = 100
TIME_CAP_SECONDS = 60 * 60
MODELS = ("claude-sonnet-5-5", "claude-opus-5-5")
MAX_TRANSCRIPT, MAX_STDERR = 64 * 1024 * 1024, 1024 * 1024
MAX_LINES = 200_000
FILES = ("agent.jsonl", "agent.stderr", "agent.patch", "proxy-events.jsonl", "result.json")
# Not a credential. It makes Claude Code send subscription-style requests, whose
# Authorization header the model proxy replaces.
PLACEHOLDER = "factory-placeholder-replaced-by-proxy"
EGRESS_URL = "http://127.0.0.1:8081"
ENVIRONMENT = {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
    "CLAUDE_CODE_OAUTH_TOKEN": PLACEHOLDER,
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",  # See model_request.py.
    "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1",  # 1M context can draw on usage credits.
    # Compilers can join the pieces of pretend tokens in tests, which the probe would report.
    "PYTHONDONTWRITEBYTECODE": "1",
    "BASH_DEFAULT_TIMEOUT_MS": "1800000",
    "BASH_MAX_TIMEOUT_MS": "3000000",
    "HTTPS_PROXY": EGRESS_URL,
    "https_proxy": EGRESS_URL,
    "HTTP_PROXY": EGRESS_URL,
    "http_proxy": EGRESS_URL,
    "NO_PROXY": "127.0.0.1,localhost",
    "no_proxy": "127.0.0.1,localhost",
}
UPSTREAM_FAILURES = {
    "throttled", "overloaded", "auth_failed", "upstream_error", "upstream_unreachable",
}  # fmt: skip


def cancel_on_signals(cancelled):
    """Note a cancel instead of raising, so it can never interrupt the token search."""
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda *_: cancelled.set())


def report(**values):
    """Set step outputs. A later value replaces an earlier one."""
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a") as stream:
            stream.write("".join(f"{name}={value}\n" for name, value in values.items()))


class EventLog:
    """Proxy events, bounded because the agent can cause refusals at will.

    Each kind, reason and allowed host has its own room, so noise cannot push out
    an event that decides the outcome. All come from fixed text, so there are few.
    """

    def __init__(self, limit=1000):
        self.limit, self.events, self.lock = limit, [], threading.Lock()
        self.counts = collections.Counter()

    def record(self, event):
        key = event["kind"], event.get("reason"), event.get("host")
        with self.lock:
            self.counts[key] += 1
            if self.counts[key] <= self.limit:
                self.events.append({"time": round(time.time(), 3), **event})
        if event["kind"] == "usage_limit":
            report(usage_limit="true")  # Now, in case this process is killed.


def sandbox_command(name, workspace, sockets):
    """The `docker run` prefix shared by every container that touches agent work."""
    command = [
        "docker", "run", "--rm", "--init", "--name", name,
        "--network", "none", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--ipc", "private", "--log-driver", "none",
        "--pids-limit", "2048", "--memory", "8g", "--memory-swap", "8g", "--cpus", "3",
        "--volume", f"{workspace}:/workspace",
        "--volume", f"{sockets}:/run/factory:ro",
    ]  # fmt: skip
    for variable, value in ENVIRONMENT.items():
        command += ["--env", f"{variable}={value}"]
    return command


def container_command(image, name, workspace, sockets, prompt, model):
    return sandbox_command(name, workspace, sockets) + [
        "--env", f"ANTHROPIC_DEFAULT_HAIKU_MODEL={model}",  # Background requests too.
        "--volume", f"{prompt}:/prompt:ro",
        image,
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--max-turns", str(MAX_TURNS), "--model", model,
        "--tools", "Bash,Read,Edit,Write", "--dangerously-skip-permissions",
        "--setting-sources", "user", "--strict-mcp-config", "--no-session-persistence",
    ]  # fmt: skip


def stopped(name, kill):
    """Make sure a container is gone. False means it may still be running."""
    try:
        if kill:
            done = subprocess.run(["docker", "kill", name], capture_output=True, timeout=60)
            if done.returncode:
                return False
        listed = subprocess.run(
            ["docker", "ps", "--quiet", "--filter", f"name=^/?{name}$"],
            capture_output=True,
            timeout=60,
        )
        return listed.returncode == 0 and not listed.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False


def run_container(command, name, seconds, out, err, cancelled=None):
    """Run a container, bounded in time and output.

    Returns (exit code or None, "time_cap" / "output_overflow" / "cancelled" / None,
    whether it is gone).
    """
    overflow = threading.Event()

    def pump(source, path, limit):
        with path.open("wb") as target:
            while data := source.read1(65536):
                if limit < len(data):
                    overflow.set()
                    break
                target.write(data)
                limit -= len(data)
            # Keep reading so the container cannot block before it is killed.
            while source.read1(65536):
                pass

    process, pumps, capped, gone = None, [], None, False
    deadline = time.monotonic() + seconds
    try:
        process = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        for arguments in (
            (process.stdout, out, MAX_TRANSCRIPT),
            (process.stderr, err, MAX_STDERR),
        ):
            pumps.append(threading.Thread(target=pump, args=arguments, daemon=True))
            pumps[-1].start()
        while process.poll() is None and not capped:
            if cancelled and cancelled.is_set():
                capped = "cancelled"
            elif overflow.is_set():
                capped = "output_overflow"
            elif time.monotonic() >= deadline:
                capped = "time_cap"
            else:
                time.sleep(0.1)
    finally:
        # A client that ended can leave its container running, so always check.
        gone = stopped(name, kill=process is None or process.poll() is None)
        if process and process.poll() is None:
            process.kill()
            process.wait()
        for thread in pumps:
            thread.join(10)
    if overflow.is_set() and not capped:
        capped = "output_overflow"
    return (None if capped else process.returncode), capped, gone


def parse(line):
    try:
        event = json.loads(line)
    except (ValueError, RecursionError):
        return {}
    return event if isinstance(event, dict) else {}


def classify(lines, events, capped, exit_code):
    """Name how a run ended.

    Anything about the subscription comes from the proxy, never from the agent's
    output, which the agent controls.
    """
    output = [event for event in map(parse, lines) if event]
    kinds = [event["kind"] for event in events]
    probes = [event for event in output if event.get("type") == "factory_probe"]
    results = [event for event in output if event.get("type") == "result"]
    result = results[-1] if results else {}
    if "token_echoed" in kinds:
        return "token_echoed"
    if "usage_credits" in kinds:
        return "usage_credits_on"
    if "usage_limit" in kinds:
        return "usage_limit"
    if capped:
        return capped
    # The entry point prints its probe before the agent exists to forge one.
    if not output or output[0].get("type") != "factory_probe":
        return "sandbox_failed"
    if not all(event.get("ok") is True for event in probes):
        return "sandbox_failed"
    capped = any(event.get("reason") == "model request cap reached" for event in events)
    if result.get("subtype") == "error_max_turns" or capped:
        return "turn_cap"
    responses = [kind for kind in kinds if kind in UPSTREAM_FAILURES | {"ok", "invalid_request"}]
    claimed = result.get("subtype") == "success" and result.get("is_error") is False
    if exit_code == 0 and claimed and "ok" in responses:
        return "success"
    if responses and responses[-1] in UPSTREAM_FAILURES:
        return responses[-1]
    return "agent_failed"


def publish(staging, output, result, search):
    """Move the known files to output, all at once, without any that holds the token.

    Writes exactly the bytes that were searched. Returns the final result.
    """
    partial = output.with_name(output.name + ".partial")
    partial.mkdir(parents=True)
    result = dict(result)
    for name in FILES:
        path = staging / name
        if not path.is_file() or path.is_symlink():
            continue
        data = path.read_bytes()
        if search.found(data):
            data = b"withheld: this file held a piece of the token\n"
            result = {"outcome": "token_echoed"}
        (partial / name).write_bytes(data)
    (partial / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    partial.rename(output)
    return result


def attempt(arguments, token, scratch, staging, log, cancelled):
    """Run the agent and write its files. Return the facts for result.json."""
    sockets = scratch / "s"
    sockets.mkdir(mode=0o700)
    try:
        baseline = Baseline(scratch / "base", arguments.workspace)
    except (PatchRefused, OSError, subprocess.CalledProcessError):
        return {"outcome": "workspace_refused"}
    model = proxy.ModelProxy(sockets / "model.sock", token, log.record, arguments.model)
    egress = proxy.EgressProxy(sockets / "egress.sock", log.record)
    for server in (model, egress):
        threading.Thread(target=server.serve_forever, daemon=True).start()

    name = f"factory-{secrets.token_hex(8)}"
    command = container_command(
        arguments.image, name, arguments.workspace, sockets, arguments.prompt, arguments.model
    )
    transcript = staging / "agent.jsonl"
    try:
        exit_code, capped, gone = run_container(
            command, name, arguments.time_cap, transcript, staging / "agent.stderr", cancelled
        )
    finally:
        model.stop("the run is over")
    if not gone:
        return {"outcome": "container_not_stopped"}

    raw = transcript.read_bytes()
    if raw.count(b"\n") > MAX_LINES:  # Parsing a flood of tiny lines takes minutes.
        capped, raw = capped or "output_overflow", b""
    lines = raw.decode(errors="replace").split("\n")
    results = [event for event in map(parse, lines) if event.get("type") == "result"]
    turns = results[-1].get("num_turns") if results else None
    facts = {
        "outcome": classify(lines, log.events, capped, exit_code),
        "exit_code": exit_code,
        "num_turns": turns if type(turns) is int and 0 <= turns < 10**6 else None,
    }
    if capped == "cancelled":
        return facts  # Little time is left; the search comes first.
    try:
        (staging / "agent.patch").write_bytes(baseline.patch())
    except PatchRefused as refusal:
        facts["patch_refused"] = str(refusal)  # Fixed text, safe to print.
        if facts["outcome"] == "success":
            facts["outcome"] = "patch_refused"
    return facts


def run(arguments, token, scratch):
    report(outcome="unfinished", usage_limit="false", searched="false")
    log, started, staging = EventLog(), time.monotonic(), scratch / "out"
    staging.mkdir(mode=0o700)
    result, searched = {"outcome": "internal_error"}, False
    cancelled = threading.Event()
    cancel_on_signals(cancelled)
    try:
        result = attempt(arguments, token, scratch, staging, log, cancelled)
    except Exception as error:  # The result and the token search must still happen.
        result["error"] = type(error).__name__
    result["seconds"] = round(time.monotonic() - started)
    try:
        (staging / "proxy-events.jsonl").write_text(
            "".join(json.dumps(event) + "\n" for event in list(log.events))
        )
        result = publish(staging, arguments.output, result, proxy.TokenSearch(token))
        searched = True
    except Exception as error:
        # Nothing unsearched may stay where an upload could find it.
        for name in (arguments.output.name, arguments.output.name + ".partial"):
            shutil.rmtree(arguments.output.with_name(name), ignore_errors=True)
        result = {"outcome": "internal_error", "error": type(error).__name__}
    # Not usage_limit: EventLog sets it to true, and a request may still be ending.
    report(outcome=result["outcome"], searched=json.dumps(searched))
    print(json.dumps(result))
    return {"success": 0, "usage_limit": 3}.get(result["outcome"], 1)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--image", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--prompt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", required=True, choices=MODELS)
    parser.add_argument("--time-cap", type=int, default=TIME_CAP_SECONDS)
    parser.add_argument(
        "--usage-credits-confirmed-off",
        action="store_true",
        help="a person checked that usage credits are off",
    )
    arguments = parser.parse_args()
    if "ANTHROPIC_API_KEY" in os.environ:
        parser.error("ANTHROPIC_API_KEY must not be set")
    if os.environ.get("GITHUB_RUN_ATTEMPT", "1") != "1":
        parser.error("re-runs are refused; start a new run")
    if not arguments.usage_credits_confirmed_off:
        parser.error("confirm that usage credits are off before running")
    if not 0 < arguments.time_cap <= TIME_CAP_SECONDS:
        parser.error(f"--time-cap must be at most {TIME_CAP_SECONDS}")
    token = sys.stdin.read(4096).strip()
    if not proxy.TOKEN_PATTERN.fullmatch(token):
        parser.error("stdin does not hold a `claude setup-token` token")
    arguments.workspace = arguments.workspace.resolve(strict=True)
    arguments.prompt = arguments.prompt.resolve(strict=True)
    if os.path.lexists(arguments.output):
        parser.error("--output already exists")  # No file in it may predate the run.
    # /tmp keeps the socket paths under the operating system's length limit.
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="factory-") as scratch:
        return run(arguments, token, Path(scratch))


if __name__ == "__main__":
    sys.exit(main())
