#!/usr/bin/env python3
"""Work one ticket: the decisions between the jobs of factory-work.yml.

    work.py select --output DIR
    work.py plan --ticket N --digest HEX --assessments FILE --output DIR
    work.py prompt --stage STAGE --step FILE --output FILE
    work.py collect --stage STAGE --step FILE --agent DIR --output DIR [--assessments FILE]
    work.py apply --patch FILE --root DIR
    work.py settle --output DIR
    work.py failures

STAGE is assessment or implementation. Run from a trusted checkout of main with
python3 -I. Ticket and agent text goes only into files. Step outputs (GITHUB_OUTPUT)
hold fixed codes, numbers and digests.

select and plan  GITHUB_TOKEN reads issues and pull requests. They write step.json
                 (intake.next_step). Tickets with an open factory pull request are
                 left out, and nothing is chosen while three are open. plan accepts
                 only the ticket that was assessed.
collect          What an agent made, or exit 1: run_agent.py's outcome must be
                 success, and the agent's last message one JSON object. For the
                 implementation, the patch must parse and not be empty, and the
                 summary must repeat every Performance-claim of the ticket. Its
                 output `digest` covers the three files (artifact_digest);
                 settle's `comment_digest` covers the comment.
apply            Write the patch into a checkout as the publisher would, in a job
                 without secrets.
settle           The run's verdict from the results of its jobs (NEEDS, the needs
                 context as JSON), and the failure comment.
failures         Whether three consecutive tickets failed. FACTORY_GATE_TOKEN.

Verdicts: `published` (the publisher said so and its job succeeded), `neutral`
(stopped by the gate, the usage limit or intake, or overtaken by a change on
GitHub), and `failed` for everything else, including whatever is missing.

Consecutive failures are counted from GitHub's job records, not from comments or
counters, newest first, back to the last success or approved resume. A workflow may
call factory-work.yml several times; each call is one attempt, told apart by the
caller prefix of its job names. These names are part of the ledger:
  * `factory-agent-assessment`, `factory-agent-implementation`: the agent jobs.
  * `publish-pull-request / publish`: success means published.
  * `factory-ticket-verdict`: runs whenever a ticket was chosen.
  * `factory-ticket-neutral`: a step of that job, for a neutral verdict.
An attempt without a success or a recorded neutral verdict is a failure, also if it
was cancelled, its approval was rejected or expired, or its records are incomplete.
A re-run stays in the same attempt, so it counts once. A missing run, failed lookup,
or too many runs makes `failures` fail, and the workflow then pauses.

Residual risks: those of gate.py's records. Code under test in the checks job could
replace the run's artifacts or fake that job's success: the publisher compares the
artifact with the digest made before that job ran, and Tests CI runs again on the
pull request. A publisher killed between its writes may leave a branch or an
unrecorded pull request.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import gate  # noqa: E402
import intake  # noqa: E402
import intake_github  # noqa: E402
import patch_file  # noqa: E402
import performance_gate  # noqa: E402

HERE = Path(__file__).resolve().parent
STAGES = ("assessment", "implementation")
TEMPLATE = HERE.parents[1] / ".github/pull_request_template.md"
MAX_OPEN_PULL_REQUESTS = 3
MAX_ROUTES = 5
MAX_MESSAGE = 200_000
FAILURES_TO_PAUSE = 3
MAX_RUNS = 1000
ARTIFACT_FILES = ("agent.patch", "assessments.json", "output.json")
AGENT_JOBS = ("factory-agent-assessment", "factory-agent-implementation")
VERDICT_JOB = "factory-ticket-verdict"
NEUTRAL_STEP = "factory-ticket-neutral"
PUBLISH_JOB = ("publish-pull-request", "publish")
BRANCH = re.compile(r"factory/ticket-([1-9][0-9]{0,8})-[1-9][0-9]{0,15}")
TAKEN = re.compile(r"factory/ticket-([1-9][0-9]{0,8})-")
# These workflows work no ticket, and run often. test_work.py checks the first.
NO_TICKETS = frozenset(
    f".github/workflows/factory-{name}.yml"
    for name in (
        "performance-baseline", "performance-calibrate", "proof", "resume", "setup-test",
    )
)  # fmt: skip
# The publisher's codes for a change on GitHub since the ticket was chosen.
OVERTAKEN = frozenset(
    {"ticket-ineligible", "open-pull-request-limit", "ticket-already-published", "gate-refused"}
)
REASONS = {
    "usage-limit": "The subscription's usage limit was reached. This does not count as a failure.",
    "overtaken": "The ticket or the repository changed while the work was running. "
    "This does not count as a failure.",
    "assessment-failed": "The assessment did not finish with a usable answer.",
    "plan-failed": "The assessed ticket could not be confirmed.",
    "implementation-failed": "The implementation did not finish with a usable change.",
    "checks-failed": "The change did not pass the tests.",
    "too-large": "The change is too large to publish. Split this ticket.",
    "publish-failed": "The change was not confirmed as published.",
}


class Failed(Exception):
    """The message is a fixed code."""


def output(**values):
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a", encoding="ascii") as stream:
            stream.write("".join(f"{name}={value}\n" for name, value in values.items()))
    print(json.dumps(values))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="ascii")


# Choosing


def open_factory_tickets(send, repository):
    """(open factory pull requests, tickets that have one)"""
    count, tickets = 0, set()
    for pull in intake_github._pages(send, f"/repos/{repository}/pulls", "state=open&"):
        source = pull["head"]["repo"]
        # Anyone can name a fork's branch; only this repository's are the factory's.
        if source is None or source["full_name"].casefold() != repository.casefold():
            continue
        branch = pull["head"]["ref"].casefold()
        count += branch.startswith("factory/")
        # The publisher refuses a ticket with any branch of this prefix.
        if found := TAKEN.match(branch):
            tickets.add(int(found[1]))
    return count, tickets


def choose(send, repository, assessments=()):
    count, taken = open_factory_tickets(send, repository)
    tickets, unreadable = intake_github.fetch_ready_tickets(send, repository)
    step = intake.next_step([t for t in tickets if t["number"] not in taken], assessments)
    step["skipped"] += [{"ticket": number, "reason": "unreadable"} for number in unreadable]
    if count >= MAX_OPEN_PULL_REQUESTS:
        step["skipped"].append({"ticket": None, "reason": "open-pull-request-limit"})
        step["action"] = "none"
    return step


def route_numbers(step):
    return json.dumps([entry["ticket"] for entry in step["routes"]][:MAX_ROUTES])


def select(send, repository, directory):
    step = choose(send, repository)
    write_json(directory / "step.json", step)
    chosen = step["action"] == "assess"
    output(
        ticket=step["ticket"] if chosen else "",
        digest=step["digest"] if chosen else "",
        routes=route_numbers(step),
    )


def plan(send, repository, ticket, digest, assessments, directory):
    step = choose(send, repository, assessments)
    work = step["action"] == "work" and step["ticket"] == ticket and step["digest"] == digest
    write_json(directory / "step.json", step)
    output(
        work=json.dumps(work),
        work_digest=step["work_digest"] if work else "",
        routes=route_numbers(step),
    )


# Agents


def prompt(stage, step):
    """Trusted rules first, then the ticket as JSON data."""
    if step["action"] != {"assessment": "assess", "implementation": "work"}[stage]:
        raise Failed("wrong-step")
    if stage == "assessment":
        parts = [(HERE / "assess-prompt.md").read_text(encoding="utf-8")]
        if step["origin"] == "outside":
            parts.append((HERE / "rewrite-prompt.md").read_text(encoding="utf-8"))
        data = step["source"]
    else:
        rows = re.findall(r"^\| ([^|]+) \| _", TEMPLATE.read_text(encoding="utf-8"), re.M)
        parts = [
            (HERE / "implement-prompt.md").read_text(encoding="utf-8"),
            "Rows for `paths`:\n\n" + "".join(f"    {row}\n" for row in rows),
            (HERE / "publish-text-rules.md").read_text(encoding="utf-8"),
        ]
        data = step["brief"]
    return "\n".join([*parts, "Ticket:\n", json.dumps(data, indent=1), ""])


def last_message(agent):
    """The JSON object in the agent's last message, and its exact text."""
    try:
        outcome = json.loads((agent / "result.json").read_text(encoding="utf-8"))["outcome"]
        if outcome != "success":
            raise Failed("agent-failed")
        results = []
        for line in (agent / "agent.jsonl").read_text("utf-8", errors="replace").split("\n"):
            try:
                event = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if isinstance(event, dict) and event.get("type") == "result":
                results.append(event)
        text = results[-1]["result"]
        if not isinstance(text, str) or len(text) > MAX_MESSAGE:
            raise ValueError("length")
        fenced = re.fullmatch(r"\s*```(?:json)?\n(.*)\n```\s*", text, re.S)
        text = fenced[1] if fenced else text.strip()
        value = json.loads(text)
    except (OSError, ValueError, KeyError, IndexError, TypeError, RecursionError):
        raise Failed("output-malformed") from None
    if not isinstance(value, dict):
        raise Failed("output-malformed")
    return value, text


def collect_assessment(step, agent, directory):
    _, text = last_message(agent)
    if step["action"] != "assess":
        raise Failed("wrong-step")
    entry = {"ticket": step["ticket"], "source_digest": step["digest"], "output": text}
    write_json(directory / "assessments.json", [entry])


def collect_implementation(step, agent, assessments, directory):
    value, _ = last_message(agent)
    if set(value) != {"title", "summary", "paths"} or not isinstance(value["summary"], str):
        raise Failed("output-malformed")
    try:
        required = set(performance_gate.parse_claims(step["brief"].get("body", "")))
        written = set(performance_gate.parse_claims(value["summary"]))
    except performance_gate.GateError:
        raise Failed("claim-malformed") from None
    if not required <= written:
        raise Failed("claim-missing")
    try:
        patch = (agent / "agent.patch").read_bytes()
        patch_file.parse(patch)
    except (OSError, patch_file.Rejected):
        raise Failed("patch-malformed") from None
    write_json(directory / "output.json", value)
    (directory / "agent.patch").write_bytes(patch)
    (directory / "assessments.json").write_bytes(assessments.read_bytes())
    output(digest=artifact_digest(directory))


def artifact_digest(directory, names=ARTIFACT_FILES):
    """As `sha256sum NAMES | sha256sum`, by default agent.patch assessments.json output.json."""
    lines = "".join(
        f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
        for name in names
    )
    return hashlib.sha256(lines.encode("ascii")).hexdigest()


def apply(patch, root):
    listing = subprocess.run(
        ["git", "ls-tree", "-r", "-z", "HEAD"], cwd=root, check=True, capture_output=True
    ).stdout
    tree = {}
    for entry in filter(None, listing.split(b"\0")):
        facts, _, path = entry.partition(b"\t")
        mode, _, blob = facts.decode("ascii").split(" ")
        tree[os.fsdecode(path)] = mode, blob
    try:
        changes = patch_file.parse(patch)
        patch_file.check_paths(changes, tree)
        contents = [
            (change, patch_file.apply(change, change.old and (root / change.old).read_bytes()))
            for change in changes
        ]
    except patch_file.Rejected as error:
        raise Failed(str(error)) from None
    for change, _ in contents:
        if change.old is not None and change.old != change.new:
            (root / change.old).unlink()
    for change, content in contents:
        if change.new is not None:
            path = root / change.new
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)  # Keeps an existing file's mode.
            if change.old not in (None, change.new) and tree[change.old][0] == "100755":
                path.chmod(0o755)


# The end of a run


def verdict(needs):
    """(verdict, reason) from the needs context. Whatever is missing is a failure."""

    def result(name):
        return needs.get(name, {}).get("result")

    def value(name, key):
        return needs.get(name, {}).get("outputs", {}).get(key) or ""

    publisher = "publish-pull-request"
    outcome, code = value(publisher, "outcome"), value(publisher, "code")
    if result(publisher) == "success" and outcome == "published":
        return "published", "published"
    if value(publisher, "branch-left"):
        return "failed", "publish-failed"
    for name in ("assess", "implement"):
        if result(name) != "success" and value(name, "usage_limit") == "true":
            return "neutral", "usage-limit"
    for name in ("assess", "plan", "implement", "permit"):
        gates = value(name, "gate"), value(name, "gate_again")
        if result(name) == "failure" and "failure" in gates:
            return "neutral", "gate-refused"
    if result("plan") == "success" and value("plan", "work") == "false":
        return "neutral", "not-work"
    if outcome == "refused" and code in OVERTAKEN:
        return "neutral", "overtaken"
    if outcome == "split":
        return "failed", "too-large"
    for name, reason in (
        ("assess", "assessment-failed"),
        ("plan", "plan-failed"),
        ("implement", "implementation-failed"),
        ("permit", "publish-failed"),
        ("checks", "checks-failed"),
    ):
        if result(name) != "success":
            return "failed", reason
    return "failed", "publish-failed"


def settle(needs, repository, run_id, directory):
    decided, reason = verdict(needs)
    if reason in REASONS:
        body = f"The factory did not finish this ticket. {REASONS[reason]}"
        publisher = needs.get("publish-pull-request", {}).get("outputs", {})
        left = publisher.get("branch-left") or ""
        if BRANCH.fullmatch(left):
            body += f" The branch `{left}` could not be removed."
        body += f"\n\nSee [the run](https://github.com/{repository}/actions/runs/{run_id}).\n"
        write_json(directory / "output.json", {"body": body})
    digest = artifact_digest(directory, ("output.json",)) if reason in REASONS else ""
    output(
        verdict=decided, reason=reason, comment=json.dumps(reason in REASONS), comment_digest=digest
    )


def consecutive_failures(repo, get, *, now, run_id):
    """How many tickets failed in a row, newest first. This run's must be among them."""
    resumed = gate._last_resume(repo, get)
    oldest = resumed or gate._BEGINNING
    runs = gate._factory_runs(repo, get, oldest, now)
    gate._require_no_missing_run(repo, runs, oldest, now)
    jobs = gate._job_reader(repo, get)
    order = sorted(runs, key=lambda run: (gate._timestamp(run["created_at"]), run["id"]))
    failures, lookups, seen, ended = 0, 0, False, False
    for run in reversed(order):
        if gate._from_outsider(repo, run) or run["path"] in NO_TICKETS:
            continue
        if run["status"] == "completed" and gate._timestamp(run["updated_at"]) < oldest:
            continue
        lookups += 1
        if lookups > MAX_RUNS:
            raise Failed("too-many-runs")
        for outcome in reversed(attempts(jobs(run["id"]), oldest)):
            if outcome == "published":
                ended = True
                break
            failures += 1
            seen = seen or run["id"] == run_id
        if ended or (failures >= FAILURES_TO_PAUSE and seen):
            break
    if not seen:
        raise Failed("run-not-recorded")  # The records do not show this failure yet.
    return failures


def attempts(jobs, since):
    """published or failed for each ticket tried since then, oldest first."""
    groups = {}
    for job in jobs:
        parts = tuple(job["name"].split(" / "))
        if parts[-1] in (*AGENT_JOBS, VERDICT_JOB):
            groups.setdefault(parts[:-1], []).append((parts[-1], job))
        elif parts[-2:] == PUBLISH_JOB:
            groups.setdefault(parts[:-2], []).append(("publish", job))
    found = []
    for members in groups.values():
        ended = [job["completed_at"] for _, job in members]
        if None not in ended and max(map(gate._timestamp, ended)) < since:
            continue
        if any(kind == "publish" and job["conclusion"] == "success" for kind, job in members):
            outcome = "published"
        elif all(_not_tried(kind, job) for kind, job in members) or _neutral(members):
            continue
        else:
            outcome = "failed"
        started = min(gate._timestamp(job["started_at"]) for _, job in members)
        found.append((started, outcome))
    return [outcome for _, outcome in sorted(found)]


def _not_tried(kind, job):
    if job["conclusion"] == "skipped":
        return True
    return kind in AGENT_JOBS and any(
        step["name"] == gate.AGENT_STEP and step["conclusion"] == "skipped"
        for step in job["steps"]
    )


def _neutral(members):
    """Every run of the verdict job recorded a neutral verdict."""
    verdicts = [job for kind, job in members if kind == VERDICT_JOB]
    return bool(verdicts) and all(
        any(
            step["name"] == NEUTRAL_STEP and step["conclusion"] == "success"
            for step in job["steps"]
        )
        for job in verdicts
    )


# Command line


def main(argv=None):
    parser = argparse.ArgumentParser(description="Work one ticket.")
    commands = parser.add_subparsers(dest="command", required=True)
    special = {"ticket": {"type": int}, "stage": {"choices": STAGES}, "digest": {}}
    for name, options in {
        "select": ["output"],
        "plan": ["ticket", "digest", "assessments", "output"],
        "prompt": ["stage", "step", "output"],
        "collect": ["stage", "step", "agent", "output"],
        "apply": ["patch", "root"],
        "settle": ["output"],
        "failures": [],
    }.items():
        command = commands.add_parser(name)
        for option in options:
            kind = special.get(option, {"type": Path})
            command.add_argument(f"--{option}", required=True, **kind)
        if name == "collect":
            command.add_argument("--assessments", type=Path)
    arguments = parser.parse_args(argv)
    try:
        run(arguments, os.environ)
    except Exception as error:  # A traceback could carry agent text into the log.
        code = str(error) if isinstance(error, Failed) else type(error).__name__
        print(f"error: {arguments.command} failed ({code})", file=sys.stderr)
        return 1
    return 0


def run(arguments, environment):
    command, repository = arguments.command, environment.get("GITHUB_REPOSITORY", "")
    if command in ("select", "plan"):
        send = intake_github.http_transport(environment["GITHUB_TOKEN"])
        if command == "select":
            return select(send, repository, arguments.output)
        assessments = intake_github._read_assessments(arguments.assessments)
        return plan(
            send, repository, arguments.ticket, arguments.digest, assessments, arguments.output
        )
    if command in ("prompt", "collect"):
        step = json.loads(arguments.step.read_text(encoding="ascii"))
    if command == "prompt":
        arguments.output.write_text(prompt(arguments.stage, step), encoding="utf-8")
    elif command == "collect" and arguments.stage == "assessment":
        collect_assessment(step, arguments.agent, arguments.output)
    elif command == "collect":
        arguments.output.mkdir(parents=True, exist_ok=True)
        collect_implementation(step, arguments.agent, arguments.assessments, arguments.output)
    elif command == "apply":
        apply(arguments.patch.read_bytes(), arguments.root)
    elif command == "settle":
        run_id = int(environment["GITHUB_RUN_ID"])
        settle(json.loads(environment["NEEDS"]), repository, run_id, arguments.output)
    elif command == "failures":
        count = consecutive_failures(
            repository,
            gate._github(environment["FACTORY_GATE_TOKEN"]),
            now=datetime.now(timezone.utc),
            run_id=int(environment["GITHUB_RUN_ID"]),
        )
        output(pause=json.dumps(count >= FAILURES_TO_PAUSE))


if __name__ == "__main__":
    raise SystemExit(main())
