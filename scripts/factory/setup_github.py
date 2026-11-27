"""GitHub access and read-only checks for the setup wizard (setup_steps.py).

An `api` here is a callable (method, path, body=None) -> Answer. `gh_api` uses the
maintainer's `gh` login; `token_api` holds a token in memory only and cannot send
it anywhere but api.github.com. `check` runs a check and returns its problems; an
empty list means verified. Anything unreadable is a problem.
"""

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gate  # noqa: E402
from github_http import api_request, open_api  # noqa: E402

MAINTAINER = "sspeaks"
REPO = "sspeaks/redis-client"
ROOT = f"/repos/{REPO}"
FACTORY = Path(__file__).resolve().parent
RELEASE_CHECKER = FACTORY.parent / "check-release-environment.py"

NEW_LABELS = {
    "factory-approved": "Maintainer admitted this outside ticket to the factory",
    "factory-filed": "Filed by the factory",
    "factory-paused": "Stops all factory work until an approved resume",
}
LABELS = (
    *NEW_LABELS, "needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix",
    "priority:p0", "priority:p1", "priority:p2", "priority:p3", "type:bug", "type:correctness",
    "type:performance", "type:docs", "type:testing", "type:maintenance", "type:security",
)
REPOSITORY = "repository Actions"
# Where each secret may be, exactly. A called workflow gets no repository secret
# unless its caller passes it, so the gate token is also in factory-publish.
SECRETS = {
    "FACTORY_GATE_TOKEN": {REPOSITORY, "environment factory-publish"},
    "FACTORY_PUBLISH_TOKEN": {"environment factory-publish"},
    # Two separate tokens of one name. UNGATED_CLAUDE_TOKEN is only a name workflows
    # pass between themselves, never a stored secret.
    "CLAUDE_CODE_OAUTH_TOKEN": {"environment factory-model", "environment factory-agent"},
    "ANTHROPIC_API_KEY": set(),
}
FIXED_PATHS = {
    REPOSITORY: f"{ROOT}/actions/secrets",
    "repository Dependabot": f"{ROOT}/dependabot/secrets",
    "repository agents": f"{ROOT}/agents/secrets",
    "repository Codespaces": f"{ROOT}/codespaces/secrets",
}
WORKFLOWS = (
    "factory-pause", "factory-proof", "factory-publish", "factory-resume", "factory-setup-test",
)


class Problem(Exception):
    """The step cannot go on; the message never holds a secret."""


@dataclass(frozen=True)
class Answer:
    status: int
    body: object = None
    headers: dict = field(default_factory=dict)


def gh_environment():
    """No debug output, and no other host or repository."""
    dropped = ("GH_DEBUG", "DEBUG", "GH_HOST", "GH_REPO", "GH_ENTERPRISE_TOKEN")
    return {key: value for key, value in os.environ.items() if key not in dropped}


def gh_api(method, path, body=None):
    command = ["gh", "api", "--hostname", "github.com", "--include", "--method", method, path]
    if body is not None:
        command += ["--input", "-"]
    ran = subprocess.run(
        command, input="" if body is None else json.dumps(body), text=True,
        capture_output=True, env=gh_environment(), check=False,
        start_new_session=True,  # Ctrl-C or a closed terminal must not cut it short.
    )
    head, _, text = ran.stdout.replace("\r\n", "\n").partition("\n\n")
    try:
        status = int(head.split()[1])
        fields = (line.partition(":") for line in head.splitlines()[1:])
        headers = {key.lower(): value.strip() for key, _, value in fields}
        return Answer(status, json.loads(text) if text.strip() else None, headers)
    except (IndexError, ValueError):
        raise Problem(f"gh api {method} {path} gave no readable answer") from None


def token_api(token):
    def api(method, path, body=None):
        request = api_request(
            path, token, "factory-setup", method=method,
            data=None if body is None else json.dumps(body).encode(),
        )
        try:
            with open_api(request) as response:
                return _answer(response)
        except urllib.error.HTTPError as error:
            with error:
                return _answer(error)
        except (OSError, ValueError) as error:
            raise Problem(f"{method} {path}: {type(error).__name__}") from None

    return api


def _answer(response):
    text = response.read()
    try:
        body = json.loads(text) if text.strip() else None
    except ValueError:
        body = None
    return Answer(response.status, body, {k.lower(): v for k, v in response.headers.items()})


def get(api, path):
    answer = api("GET", path)
    if answer.status != 200:
        raise Problem(f"GET {path} answered {answer.status}")
    return answer.body


def everything(api, path, key=None):
    found = []
    for page in range(1, 101):
        body = get(api, f"{path}?per_page=100&page={page}")
        items = body[key] if key else body
        if not isinstance(items, list):
            raise Problem(f"{path} is not a list")
        found += items
        if len(items) < 100:
            if key and body["total_count"] != len(found):
                raise Problem(f"{path} is incomplete")
            return found
    raise Problem(f"{path} has too many pages")


def check(function, api, *arguments):
    try:
        return list(function(api, *arguments))
    except Problem as error:
        return [str(error)]
    except Exception as error:  # Anything unexpected is not verified.
        return [f"{function.__name__} could not read the answer ({type(error).__name__})"]


def preflight(api):
    if get(api, "/user")["login"] != MAINTAINER:
        yield f"gh is not signed in as {MAINTAINER}"
    repository = get(api, ROOT)
    if repository["full_name"] != REPO or repository["permissions"]["admin"] is not True:
        yield f"gh has no admin access to {REPO}"
    if repository["default_branch"] != "main" or repository["private"] is not False:
        yield "the repository is not public with default branch main"
    if repository["owner"]["type"] != "User":
        yield "the repository has an organization, whose secrets this wizard cannot check"


def checkout(api):
    """This wizard's own files are main's, so a stale or edited copy cannot vouch for anything."""
    def git(*arguments):
        ran = subprocess.run(
            ["git", "-C", str(FACTORY), *arguments], capture_output=True, text=True, check=True,
            env={key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
        )
        return ran.stdout.strip()

    main = get(api, f"{ROOT}/git/ref/heads/main")["object"]["sha"]
    if git("symbolic-ref", "HEAD") != "refs/heads/main":
        yield "the checkout is not on branch main"
    if git("rev-parse", "HEAD") != main:
        yield "the checkout is not at GitHub's main; pull it"
    if git("status", "--porcelain", "--untracked-files=all"):
        yield "the checkout has local changes or untracked files"


def workflows_on_main(api):
    files = {f["name"] for f in get(api, f"{ROOT}/contents/.github/workflows?ref=main")}
    for name in WORKFLOWS:
        if f"{name}.yml" not in files:
            yield f"{name}.yml is not on main"


def switch_off(api):
    answer = api("GET", f"{ROOT}/actions/variables/FACTORY_ENABLED")
    if answer.status == 404:
        return
    if answer.status != 200 or answer.body["value"] != "false":
        yield "FACTORY_ENABLED is on, or neither unset nor exactly false; setup needs the factory off"


def environment(api, name):
    """The same checkers, run the same way, as the workflows."""
    path = f"{ROOT}/environments/{name}"
    value = get(api, path)
    if value["name"] != name:
        yield f"{name} environment: GitHub answered for another one"
    with tempfile.TemporaryDirectory() as directory:
        files = [Path(directory, "environment.json"), Path(directory, "policies.json")]
        files[0].write_text(json.dumps(value), encoding="utf-8")
        if name != "release":
            policies = get(api, f"{path}/deployment-branch-policies")
            files[1].write_text(json.dumps(policies), encoding="utf-8")
        # The same command lines as the workflows that use each environment.
        if name == "factory-publish":
            command = [RELEASE_CHECKER, files[0], "--name", name, "--no-reviewer",
                       "--branch", "main", "--branch-policies", files[1]]
        elif name == "factory-agent":
            command = [RELEASE_CHECKER, files[0], "--no-reviewer", "--branch", "main",
                       "--branch-policies", files[1]]
        else:
            command = [RELEASE_CHECKER, files[0], "--reviewer", MAINTAINER]
            if name != "release":
                command += ["--branch", "main", "--branch-policies", files[1]]
        ran = subprocess.run(
            [sys.executable, "-I", *command], capture_output=True, text=True, check=False
        )
    if ran.returncode:
        yield from ran.stderr.strip().splitlines()[-5:] or [f"{name}: the checker failed"]


def fork_approval(api):
    """Outsiders must not be able to flood the run list the gate reads."""
    answer = get(api, f"{ROOT}/actions/permissions/fork-pr-contributor-approval")
    if answer["approval_policy"] != "all_external_contributors":
        yield "workflows of external contributors can run without approval"


def labels(api, wanted=LABELS):
    present = {label["name"] for label in everything(api, f"{ROOT}/labels")}
    for name in wanted:
        if name not in present:
            yield f"label {name} is missing (names are case-sensitive)"


def secret_paths(api):
    """{place: path of its secret list}. The environments themselves may be unreadable."""
    paths = dict(FIXED_PATHS)
    for found in everything(api, f"{ROOT}/environments", "environments"):
        name = urllib.parse.quote(found["name"], safe="")
        paths[f"environment {found['name']}"] = f"{ROOT}/environments/{name}/secrets"
    return paths


def secret_places(api):
    """{secret name: {place: when it was last set}} for everything readable."""
    places = {}
    for place, path in secret_paths(api).items():
        for secret in everything(api, path, "secrets"):
            places.setdefault(secret["name"].upper(), {})[place] = secret["updated_at"]
    return places


def secret_copies(api):
    """Organization secrets need no check: preflight proved there is no organization."""
    places = secret_places(api)
    for name, allowed in SECRETS.items():
        for place in places.get(name, {}):
            if place not in allowed:
                yield f"{name} must not exist in: {place}"


# Each token by kind: its secret name and where it is stored. The two subscription
# tokens are separate: factory-model for the reviewed proof, factory-agent for
# unattended agent jobs.
KINDS = {
    "gate": ("FACTORY_GATE_TOKEN", {REPOSITORY, "environment factory-publish"}),
    "publish": ("FACTORY_PUBLISH_TOKEN", {"environment factory-publish"}),
    "subscription": ("CLAUDE_CODE_OAUTH_TOKEN", {"environment factory-model"}),
    "agent": ("CLAUDE_CODE_OAUTH_TOKEN", {"environment factory-agent"}),
}
USAGE_CREDITS = ("FACTORY_USAGE_CREDITS", "checked and off")
ACTIONS_APP = 15368  # GitHub Actions' app id, which reports the build check.


def secret_missing(api, kind):
    name, places = KINDS[kind]
    for place in sorted(places - set(secret_places(api).get(name, {}))):
        yield f"{name} is missing from: {place}"


def usage_credits(api):
    name, value = USAGE_CREDITS
    answer = api("GET", f"{ROOT}/actions/variables/{name}")
    if answer.status != 200 or answer.body["value"] != value:
        yield f"repository variable {name} is not exactly {value!r}"


def rulesets(api, target):
    for summary in everything(api, f"{ROOT}/rulesets"):
        if summary["target"] == target and summary["enforcement"] == "active":
            yield get(api, f"{ROOT}/rulesets/{summary['id']}")


def _gaps(ruleset, included, rules):
    names = ruleset["conditions"]["ref_name"]
    if not included & set(names["include"]) or names["exclude"]:
        yield "does not cover every intended ref"
    missing = sorted(rules - {rule["type"] for rule in ruleset["rules"]})
    if missing:
        yield "lacks: " + ", ".join(missing)
    # GitHub shows bypass_actors only to administrators; a missing key is unreadable.
    if ruleset["bypass_actors"] != []:
        yield "has a bypass actor"


def _one_complete(found, what, gaps):
    problems = []
    for ruleset in found:
        wrong = list(gaps(ruleset))
        if not wrong:
            return
        problems += [f"ruleset {ruleset['name']}: {problem}" for problem in wrong]
    yield from problems or [f"no active {what} ruleset"]


def tag_ruleset(api):
    yield from _one_complete(
        rulesets(api, "tag"), "tag",
        lambda ruleset: _gaps(ruleset, {"~ALL"}, {"creation", "update", "deletion"}),
    )


def _covering_main(api):
    """[(ruleset, the rules it puts on main)] for every active ruleset that covers main."""
    rules = {}
    for rule in everything(api, f"{ROOT}/rules/branches/main"):
        if rule["ruleset_source_type"] != "Repository":
            raise Problem("a ruleset from outside the repository covers main")
        kept = {key: value for key, value in rule.items() if not key.startswith("ruleset_")}
        rules.setdefault(rule["ruleset_id"], []).append(kept)
    if not rules:
        raise Problem("no active ruleset covers main")
    return [(get(api, f"{ROOT}/rulesets/{identity}"), found) for identity, found in rules.items()]


def _merge_methods(api):
    every = ["merge", "rebase", "squash"]
    repository = get(api, ROOT)
    allowed = {method for method in every if repository[f"allow_{method}_{'commit' if method == 'merge' else 'merge'}"] is True}
    for ruleset, rules in _covering_main(api):
        for rule in rules:
            if rule["type"] == "pull_request" and sorted(rule["parameters"]["allowed_merge_methods"] or []) != every:
                yield f"ruleset {ruleset['name']} restricts merge methods"
            if rule["type"] == "required_linear_history":
                yield f"ruleset {ruleset['name']} requires linear history, which conflicts with merge commits"
    if not allowed:
        yield "the repository allows no merge method"


def _checks_reported(api):
    """Every required check must have succeeded on main's head, from the app it is required from."""
    head = get(api, f"{ROOT}/git/ref/heads/main")["object"]["sha"]
    statuses = None
    for ruleset, rules in _covering_main(api):
        for rule in rules:
            if rule["type"] != "required_status_checks":
                continue
            for required in rule["parameters"]["required_status_checks"]:
                context, app = required["context"], required.get("integration_id")
                if context == "build" and app != ACTIONS_APP:
                    yield f"ruleset {ruleset['name']} requires build from another app, or any app"
                query = urllib.parse.urlencode({"check_name": context, "per_page": 100})
                runs = get(api, f"{ROOT}/commits/{head}/check-runs?{query}")["check_runs"]
                passed = any(run["conclusion"] == "success" and app in (None, run["app"]["id"])
                             for run in runs)
                if not passed and app is None:
                    if statuses is None:
                        statuses = get(api, f"{ROOT}/commits/{head}/status")["statuses"]
                    passed = any(s["context"] == context and s["state"] == "success" for s in statuses)
                if not passed:
                    yield f"required check {context} has not passed on main; you could not merge"


def main_rules(api):
    """The rules on main, one list for each ruleset."""
    return [rules for _, rules in _covering_main(api)]


def main_ruleset(api):
    required = {"deletion", "non_fast_forward", "pull_request", "required_status_checks"}
    contexts = []
    for ruleset, rules in _covering_main(api):
        # GitHub shows bypass_actors only to administrators; a missing key is unreadable.
        if ruleset["bypass_actors"] != []:
            yield f"ruleset {ruleset['name']} has a bypass actor"
        required -= {rule["type"] for rule in rules}
        contexts += [
            entry["context"]
            for rule in rules
            if rule["type"] == "required_status_checks"
            for entry in rule["parameters"]["required_status_checks"]
        ]
    if required:
        yield "main lacks: " + ", ".join(sorted(required))
    if "build" not in contexts:
        yield "main does not require build"


def main_mergeable(api):
    """One person can still merge to main when nobody can bypass its rules."""
    known = {
        "deletion", "non_fast_forward", "pull_request", "required_linear_history",
        "required_status_checks",
    }
    for ruleset, rules in _covering_main(api):
        for rule in rules:
            if rule["type"] not in known:
                yield f"ruleset {ruleset['name']} has the rule {rule['type']}, which may lock you out"
            if rule["type"] != "pull_request":
                continue
            wanted = rule["parameters"]
            if type(wanted["required_approving_review_count"]) is not int or (
                wanted["required_approving_review_count"] != 0
            ):
                yield f"ruleset {ruleset['name']} requires approvals"
            for key in ("require_code_owner_review", "require_last_push_approval"):
                if wanted[key] is not False:
                    yield f"ruleset {ruleset['name']}: {key} is not off"
            if wanted.get("require_extra_approval_for_unattributed_changes", False) is not False:
                yield f"ruleset {ruleset['name']} requires an extra approval"
            if wanted.get("required_reviewers", []) != []:
                yield f"ruleset {ruleset['name']} requires reviewers"
    yield from _merge_methods(api)
    yield from _checks_reported(api)
    if api("GET", f"{ROOT}/branches/main/protection").status != 404:
        yield "classic branch protection also covers main, or cannot be read; remove it"


def latest_run(api, workflow):
    path = f"{ROOT}/actions/workflows/{workflow}.yml/runs?event=workflow_dispatch&per_page=1"
    runs = get(api, path)["workflow_runs"]
    return runs[0] if runs else None


def waiting_resume(api):
    """(run id, environment id) of a Factory resume run waiting for approval, or None."""
    run = latest_run(api, "factory-resume")
    if not run or run["status"] != "waiting" or run["head_branch"] != "main":
        return None
    pending = get(api, f"{ROOT}/actions/runs/{run['id']}/pending_deployments")
    if [entry["environment"]["name"] for entry in pending] != ["factory-resume"]:
        return None
    if pending[0]["current_user_can_approve"] is not True:
        return None
    return run["id"], pending[0]["environment"]["id"]


def _gate_reader(api):
    def read(path):
        if path == f"{ROOT}/actions/variables/FACTORY_ENABLED":
            return {"value": "true"}, None
        answer = api("GET", path)
        if answer.status != 200:
            raise ValueError(f"{path} answered {answer.status}")
        link = answer.headers.get("link")
        return answer.body, None if link is None else gate._next_path(link)

    return read


def gate_if_enabled(api):
    """What gate.py publish would answer if FACTORY_ENABLED were on. Changes nothing."""
    return gate.check(
        "publish", REPO, _gate_reader(api), now=datetime.now(timezone.utc), run_id=0
    )


def resumed(api):
    if gate._last_resume(REPO, _gate_reader(api)) is None:
        yield "no Factory resume run has been approved"
    decision = gate_if_enabled(api)
    if not decision.allowed:
        yield f"with the switch on, the gate would still refuse: {decision.reason}"


def setup_test(api, run):
    """Problems with how GitHub recorded a factory-setup-test run."""
    if run["status"] != "completed":
        yield "the run is not finished"
        return
    path = f"{ROOT}/actions/runs/{run['id']}/jobs"
    jobs = {job["name"]: job for job in everything(api, path, "jobs")}
    expected = {"observe": "success", "call-failed / factory-pause": "failure"}
    for name, conclusion in expected.items():
        if jobs.get(name, {}).get("conclusion") != conclusion:
            yield f"job {name!r} is not recorded as {conclusion}"
    for name, job in jobs.items():
        if name in expected:
            continue
        if not name.startswith("call-skipped"):
            yield f"unexpected job {name!r}"
        elif name.endswith("/ factory-pause") or job["conclusion"] != "skipped":
            yield f"a skipped call is recorded as {name!r} ({job['conclusion']})"
    steps = [
        step["conclusion"]
        for step in jobs.get("observe", {}).get("steps", [])
        if step["name"] == gate.PAUSE_FAILED_STEP
    ]
    if steps != ["skipped"]:
        yield "an unreached factory-pause-failed step is not recorded as skipped"
