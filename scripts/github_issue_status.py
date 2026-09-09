#!/usr/bin/env python3

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


ACTIVE_STATUS_LABELS = frozenset(
    {"status:ready", "status:in-progress", "status:needs-review"}
)


def label_names(issue):
    return {
        label["name"] if isinstance(label, dict) else label
        for label in issue.get("labels", [])
    }


def plan_transition(issue, action):
    labels = label_names(issue)
    remove = sorted(labels & ACTIVE_STATUS_LABELS)
    add = []

    if action == "reopened":
        has_owner = any(
            label.startswith("squad:") and label != "squad:"
            for label in labels
        )
        if has_owner and "status:ready" not in labels:
            add.append("status:ready")
        elif not has_owner and "squad" not in labels:
            add.append("squad")
        remove = [label for label in remove if label != "status:ready"]
    elif action != "closed":
        raise ValueError(f"unsupported issue action: {action}")

    return {"add": add, "remove": remove}


class GitHubClient:
    def __init__(self, repository, token):
        self.repository = repository
        self.token = token
        self.api_root = f"https://api.github.com/repos/{repository}"

    def request(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            f"{self.api_root}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "redis-client-issue-status-workflow",
            },
        )
        try:
            with urllib.request.urlopen(request) as response:
                contents = response.read()
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"GitHub API {method} {path} failed: {error.code} {details}"
            ) from error
        return json.loads(contents) if contents else None

    def closed_issues(self):
        page = 1
        while True:
            query = urllib.parse.urlencode(
                {"state": "closed", "per_page": 100, "page": page}
            )
            issues = self.request("GET", f"/issues?{query}")
            if not issues:
                return
            for issue in issues:
                if "pull_request" not in issue:
                    yield issue
            if len(issues) < 100:
                return
            page += 1

    def get_issue(self, issue_number):
        return self.request("GET", f"/issues/{issue_number}")

    def add_labels(self, issue_number, labels):
        self.request("POST", f"/issues/{issue_number}/labels", {"labels": labels})

    def remove_label(self, issue_number, label):
        encoded_label = urllib.parse.quote(label, safe="")
        self.request("DELETE", f"/issues/{issue_number}/labels/{encoded_label}")


def print_plan(issue, action, plan, mode):
    print(
        json.dumps(
            {
                "action": action,
                "add": plan["add"],
                "issue": issue["number"],
                "mode": mode,
                "remove": plan["remove"],
            },
            sort_keys=True,
        )
    )


def apply_plan(client, issue, action, plan, dry_run):
    if dry_run:
        print_plan(issue, action, plan, "dry-run")
        return

    current_issue = client.get_issue(issue["number"])
    current_plan = plan_transition(current_issue, action)
    print_plan(current_issue, action, current_plan, "apply")
    if current_plan["add"]:
        client.add_labels(issue["number"], current_plan["add"])
    for label in current_plan["remove"]:
        client.remove_label(issue["number"], label)


def reconcile(client, dry_run):
    for issue in client.closed_issues():
        plan = plan_transition(issue, "closed")
        if plan["add"] or plan["remove"]:
            apply_plan(client, issue, "closed", plan, dry_run)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Keep GitHub issue workflow status labels consistent."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--event-file")
    mode.add_argument("--reconcile", action="store_true")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--confirm-repository",
        help="Required for live reconciliation; must exactly match --repository.",
    )
    args = parser.parse_args(argv)

    if not args.repository:
        parser.error("--repository or GITHUB_REPOSITORY is required")
    if not args.token:
        parser.error("--token or GITHUB_TOKEN is required")
    if args.reconcile and args.apply and args.confirm_repository != args.repository:
        parser.error(
            "live reconciliation requires --confirm-repository to exactly match "
            "--repository"
        )
    if args.event_file and args.confirm_repository:
        parser.error("--confirm-repository is only valid with --reconcile")
    return args


def main(argv=None):
    args = parse_args(argv)
    client = GitHubClient(args.repository, args.token)

    if args.reconcile:
        reconcile(client, dry_run=not args.apply)
        return 0

    with open(args.event_file, encoding="utf-8") as event_file:
        event = json.load(event_file)
    action = event.get("action")
    issue = event.get("issue")
    if action not in {"closed", "reopened"} or not issue:
        raise ValueError("event must be a closed or reopened issue event")
    plan = plan_transition(issue, action)
    apply_plan(client, issue, action, plan, dry_run=not args.apply)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
