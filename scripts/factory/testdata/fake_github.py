"""A stateful stand-in for the GitHub API used by the setup wizard's tests.

Run as `gh` (FAKE_GH_STATE names its JSON file), or used in process through
FakeGitHub.admin and FakeGitHub.token. `powers` holds what the token may wrongly do.
"""

import base64
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = "/repos/sspeaks/redis-client"
NOW = "2026-11-25T00:00:00Z"
DENIED = (403, {"message": "Resource not accessible by personal access token"})
BLOCKED = (422, {"message": "Repository rule violations found"})
RULES = [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "require_code_owner_review": False,
        "require_last_push_approval": False, "required_reviewers": [],
        "require_extra_approval_for_unattributed_changes": False,
        "allowed_merge_methods": ["merge", "squash", "rebase"]}},
    {"type": "required_status_checks",
     "parameters": {"required_status_checks": [{"context": "build", "integration_id": 15368}]}},
]
CUSTOM = {"protected_branches": False, "custom_branch_policies": True}
REVIEW = {
    "type": "required_reviewers",
    "prevent_self_review": False,
    "reviewers": [{"type": "User", "reviewer": {"login": "sspeaks"}}],
}


def environment(name, *rules, limited=True):
    return {
        "name": name,
        "can_admins_bypass": False,
        "protection_rules": [*rules, *([{"type": "branch_policy"}] if limited else [])],
        "deployment_branch_policy": CUSTOM if limited else None,
    }


def ruleset(identity, name, target, include, rules):
    return {
        "id": identity, "name": name, "target": target, "enforcement": "active",
        "bypass_actors": [], "rules": rules,
        "conditions": {"ref_name": {"include": [include], "exclude": []}},
    }


def ready():
    """Everything the maintainer sets by hand is done; no token is stored."""
    return {
        "powers": [], "log": [], "argv": [], "leaks": [], "stored": {},
        "variable": None, "variables": {"FACTORY_USAGE_CREDITS": "checked and off"},
        "checks": [{"name": "build", "app": {"id": 15368}, "conclusion": "success"}],
        "merge": {"allow_merge_commit": True, "allow_squash_merge": True, "allow_rebase_merge": True},
        "forks": "all_external_contributors", "secrets": {}, "labels": [],
        "environments": [
            environment("release", REVIEW, limited=False),
            environment("factory-model", REVIEW),
            environment("factory-publish"),
            environment("factory-resume", REVIEW),
            environment("factory-agent"),
        ],
        "rulesets": {
            "1": ruleset(1, "block-tags", "tag", "~ALL",
                         [{"type": kind} for kind in ("creation", "update", "deletion")]),
            "2": ruleset(2, "main", "branch", "~DEFAULT_BRANCH", RULES),
        },
        "refs": {"refs/heads/main": "c0"}, "commits": {"c0": "t0"}, "trees": {"t0": []},
        "runs": {"factory-resume": [], "factory-setup-test": []}, "jobs": [],
        "headers": {"github-authentication-token-expiration": "2027"},
    }


class FakeGitHub:
    def __init__(self, state=None):
        self.state = state or ready()

    def admin(self, method, path, body=None):
        return self.request("admin", method, path, body)

    def token(self, method, path, body=None):
        return self.request("token", method, path, body)

    def request(self, actor, method, path, body):
        from setup_github import Answer

        status, value = self.logged(actor, method, path, body)
        return Answer(status, value, dict(self.state["headers"]) if actor == "token" else {})

    def logged(self, actor, method, path, body):
        if method != "GET":
            self.state["log"].append([actor, method, path, body])
        return self.route(actor, method, path, body)

    def may(self, actor, power):
        return actor == "admin" or any(power.startswith(had) for had in self.state["powers"])

    def route(self, actor, method, path, body):
        s, url = self.state, urlsplit(path)
        if url.path == "/user":
            return 200, {"login": "sspeaks"}
        assert url.path.startswith(ROOT), path
        rest = url.path.removeprefix(ROOT)
        if rest == "":
            return 200, {
                "full_name": "sspeaks/redis-client", "permissions": {"admin": True},
                "default_branch": "main", "private": False, "owner": {"type": "User"},
                **s["merge"],
            }
        if rest == "/contents/.github/workflows":
            names = ("pause", "proof", "publish", "resume", "setup-test")
            return 200, [{"name": f"factory-{name}.yml"} for name in names]
        if rest.startswith("/actions/variables"):
            assert method == "GET" or "FACTORY_ENABLED" not in rest, "the switch is never written"
            name = rest.removeprefix("/actions/variables").strip("/")
            if actor == "admin" and method in ("POST", "PATCH"):
                assert body["name"] == "FACTORY_USAGE_CREDITS" and name in ("", body["name"])
                s["variables"][body["name"]] = body["value"]
                return 201, None
            if method != "GET":
                return (404, None) if self.may(actor, "variables") else DENIED
            if name == "FACTORY_ENABLED":
                return (200, {"value": s["variable"]}) if s["variable"] else (404, None)
            found = s["variables"].get(name)
            return (200, {"name": name, "value": found}) if found is not None else (404, None)
        if rest.startswith("/environments"):
            return self.environments(actor, method, rest)
        if re.fullmatch(r"/commits/c\d+/check-runs", rest):
            runs = [run for run in s["checks"] if run["name"] == parse_qs(url.query)["check_name"][0]]
            return 200, {"total_count": len(runs), "check_runs": runs}
        if re.fullmatch(r"/commits/c\d+/status", rest):
            return 200, {"state": "pending", "statuses": s.get("statuses", [])}
        if rest == "/actions/permissions/fork-pr-contributor-approval":
            return 200, {"approval_policy": s["forks"]}
        if rest == "/rules/branches/main":
            return 200, self.main_rules()
        if rest == "/branches/main/protection":
            return (200, s["protection"]) if s.get("protection") else (404, None)
        if rest == "/labels":
            if method == "POST":
                s["labels"].append(body["name"])
                return 201, {}
            return 200, [{"name": name} for name in s["labels"]]
        match = re.fullmatch(r"/(actions|dependabot|agents|codespaces)/secrets(/.+)?", rest)
        if match and match[2]:
            if not self.may(actor, "secrets"):
                return DENIED
            if match[1] in s.get("stuck", []):
                return 500, None
            found = s["secrets"].get(match[1], {}).pop(match[2][1:], None)
            return (204, None) if found else (404, None)
        if match:
            return self.secret_list(match[1])
        if rest.startswith("/rulesets"):
            return self.rulesets(actor, method, rest, body)
        if rest.startswith("/git/"):
            return self.git(actor, method, rest, body)
        if rest.startswith("/contents/"):
            return self.contents(actor, method, rest, parse_qs(url.query), body)
        match = re.fullmatch(r"/actions/workflows/([a-z0-9-]+)\.yml/(runs|dispatches)", rest)
        if match:
            return self.workflow(actor, match[1], match[2])
        if rest == "/actions/runs":
            return 200, {"total_count": 0, "workflow_runs": []}
        match = re.fullmatch(r"/actions/runs/(\d+)(/\w+)?", rest)
        if match:
            return self.run(actor, method, int(match[1]), match[2], body)
        if rest == "/deployments":
            return (422, None) if self.may(actor, "deployments") else DENIED
        if rest == "/issues":
            return (422, None) if method == "POST" else (200, [])
        if rest == "/issues/events":
            return 200, []
        if rest == "/pulls":
            return 422, None
        raise AssertionError(f"unexpected request {method} {path}")

    def contents(self, actor, method, rest, query, body):
        s = self.state
        name = rest.removeprefix("/contents/")
        ref = "refs/heads/" + (query["ref"][0] if method == "GET" else body["branch"])
        tree = s["trees"][s["commits"][s["refs"][ref]]]
        if method == "GET":
            return (200, {}) if name in tree else (404, None)
        if name.startswith(".github/") and not self.may(actor, "workflows-write"):
            return DENIED
        assert name.endswith(".txt") or "if: false" in base64.b64decode(body["content"]).decode()
        s["refs"][ref] = self.add("commits", self.add("trees", [*tree, name]))
        return 201, {}

    def environments(self, actor, method, rest):
        parts = rest.split("/")[2:]
        found = {entry["name"]: entry for entry in self.state["environments"]}
        if not parts:
            return 200, {"total_count": len(found), "environments": list(found.values())}
        if method == "DELETE" and len(parts) == 1:
            assert parts[0] not in found
            return (404, None) if self.may(actor, "administration") else DENIED
        if parts[0] not in found:
            return 404, None
        if parts[1:] == ["deployment-branch-policies"]:
            return 200, {"total_count": 1, "branch_policies": [{"type": "branch", "name": "main"}]}
        if parts[1:2] == ["secrets"] and method == "DELETE":
            del self.state["secrets"][parts[0]][parts[2]]
            return 204, None
        if parts[1:2] == ["secrets"]:
            return self.secret_list(parts[0])
        return 200, found[parts[0]]

    def secret_list(self, place):
        names = self.state["secrets"].get(place, {})
        secrets = [{"name": name, "updated_at": date} for name, date in names.items()]
        return 200, {"total_count": len(names), "secrets": secrets}

    def main_rules(self):
        return [
            {**rule, "ruleset_id": entry["id"], "ruleset_source_type": "Repository",
             "ruleset_source": "sspeaks/redis-client"}
            for entry in self.state["rulesets"].values()
            if entry["target"] == "branch" and entry["enforcement"] == "active"
            and {"~DEFAULT_BRANCH", "~ALL", "refs/heads/ma*"} & set(entry["conditions"]["ref_name"]["include"])
            for rule in entry["rules"]
        ]

    def rulesets(self, actor, method, rest, body):
        rulesets = self.state["rulesets"]
        if method == "POST":
            assert actor == "admin"
            identity = str(max(map(int, rulesets)) + 1)
            rulesets[identity] = {**body, "id": int(identity)}
            return 201, rulesets[identity]
        if rest == "/rulesets":
            return 200, list(rulesets.values())
        identity = rest.split("/")[2]
        if method == "GET":
            return (200, rulesets[identity]) if identity in rulesets else (404, None)
        assert identity not in ("1", "2"), "a real ruleset must never be touched"
        if not self.may(actor, "administration"):
            return DENIED
        if rulesets.pop(identity, None) is None:
            return 404, None
        return 204, None

    def add(self, kind, value):
        store = self.state[kind]
        key = f"{kind[0]}{len(store)}"
        store[key] = value
        return key

    def protected(self, ref):
        for entry in self.state["rulesets"].values():
            included = entry["conditions"]["ref_name"]["include"]
            if ref in included or ("~ALL" in included and ref.startswith("refs/tags/")):
                return True
        return False

    def git(self, actor, method, rest, body):
        s = self.state
        _, _, kind, *parts = rest.split("/")
        name = "refs/" + "/".join(parts)
        if method == "GET" and kind == "ref":
            sha = s["refs"].get(name)
            return (200, {"object": {"sha": sha}}) if sha else (404, None)
        if method == "GET" and kind == "matching-refs":
            return 200, [{"ref": ref} for ref in s["refs"] if ref.startswith(name)]
        if method == "GET":
            return 200, {"tree": {"sha": s["commits"][parts[0]]}}
        if kind == "trees":
            files = [entry["path"] for entry in body["tree"]]
            workflow = any(file.startswith(".github/workflows/") for file in files)
            if workflow and not self.may(actor, "workflows-push"):
                return DENIED
            return 201, {"sha": self.add("trees", [*s["trees"][body["base_tree"]], *files])}
        if kind == "commits":
            assert "[skip ci]" in body["message"]
            return 201, {"sha": self.add("commits", body["tree"])}
        assert kind == "refs"
        assert not name.endswith("heads/main"), "main must never be written"
        if actor == "token" and "contents" in s.get("denied", []):
            return DENIED
        if method == "POST":
            if body["sha"] not in s["commits"]:
                return 422, None
            if body["ref"].startswith("refs/tags/") and not self.may(actor, "tags"):
                return BLOCKED
            s["refs"][body["ref"]] = body["sha"]
            return 201, {}
        bypass = actor == "token" and {"rules", "tags"} & set(s["powers"])
        if self.protected(name) and not bypass:
            return BLOCKED
        if method == "PATCH":
            s["refs"][name] = body["sha"]
            return 200, {}
        del s["refs"][name]
        return 204, None

    def workflow(self, actor, name, action):
        if name not in self.state["runs"]:
            return (404, None) if self.may(actor, "actions") else DENIED
        runs = self.state["runs"][name]
        if action == "runs":
            return 200, {"total_count": len(runs), "workflow_runs": runs}
        assert actor == "admin"
        runs.insert(0, {
            "id": 900 + len(runs), "head_branch": "main", "html_url": "https://github.com/run",
            "status": "waiting" if name == "factory-resume" else "completed",
            "conclusion": None, "path": f".github/workflows/{name}.yml",
            "event": "workflow_dispatch", "created_at": NOW, "updated_at": NOW,
        })
        return 204, None

    def run(self, actor, method, identity, part, body):
        if part == "/jobs":
            return 200, {"total_count": len(self.state["jobs"]), "jobs": self.state["jobs"]}
        every = [run for runs in self.state["runs"].values() for run in runs]
        run = next(run for run in every if run["id"] == identity)
        if part != "/pending_deployments":
            return 200, run
        if method == "GET":
            return 200, [{"environment": {"id": 77, "name": "factory-resume"},
                          "current_user_can_approve": self.state.get("can_approve", True)}]
        if not self.may(actor, "approve"):
            return DENIED
        assert body["state"] == "rejected"
        if body["environment_ids"] != [77]:
            return 422, None
        assert actor == "token", "the maintainer's login must never decide the run"
        run["status"] = "completed"
        return 200, []


def as_gh(arguments):
    path = Path(os.environ["FAKE_GH_STATE"])
    fake = FakeGitHub(json.loads(path.read_text()))
    state = fake.state
    state["argv"].append(arguments)
    state["leaks"] += [key for key, value in os.environ.items() if "dummydummy" in value]
    state["leaks"] += [key for key in ("GH_DEBUG", "GH_HOST") if key in os.environ]
    status = 200
    if arguments[0] == "git":
        answers = {
            "rev-parse": state.get("head", "c0"), "symbolic-ref": state.get("branch", "refs/heads/main"),
            "status": state.get("dirty", ""),
        }
        print(next(value for key, value in answers.items() if key in arguments))
        return 0
    if arguments[0] == "api":
        method = arguments[arguments.index("--method") + 1]
        body = json.loads(sys.stdin.read()) if "--input" in arguments else None
        target = next(argument for argument in arguments if argument.startswith("/"))
        status, value = fake.logged("admin", method, target, body)
        print(f"HTTP/2.0 {status} X\r\nX-A: b\r\n\r")
        print("" if value is None else json.dumps(value))
    else:
        assert arguments[:2] == ["secret", "set"] and "--body" not in arguments
        place = arguments[arguments.index("--env") + 1] if "--env" in arguments else "actions"
        state["stored"][f"{place}/{arguments[2]}"] = sys.stdin.read()
        state["secrets"].setdefault(place, {})[arguments[2]] = NOW
    path.write_text(json.dumps(state))
    return 0 if status < 300 else 1


if __name__ == "__main__":
    sys.exit(as_gh(sys.argv[1:]))
