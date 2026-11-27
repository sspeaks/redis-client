"""Fail unless a GitHub Environment holds a job for the maintainer.

GitHub silently creates a missing environment without protection rules, so a
job's `environment:` key alone does not prove that anything waits for approval.
"""

import argparse
import json
import sys
from pathlib import Path


def environment_errors(environment, reviewer):
    errors = []
    if environment.get("can_admins_bypass") is not False:
        errors.append("administrator bypass is not disabled")

    rules = [
        rule
        for rule in environment.get("protection_rules", [])
        if rule.get("type") == "required_reviewers"
    ]
    reviewers = [
        (entry.get("type"), entry.get("reviewer", {}).get("login"))
        for rule in rules
        for entry in rule.get("reviewers", [])
    ]
    if reviewers != [("User", reviewer)]:
        errors.append(f"{reviewer} is not the only required reviewer")
    if any(rule.get("prevent_self_review") for rule in rules):
        errors.append(
            "self-review is prevented, so the maintainer cannot approve their own run"
        )
    return errors


def branch_errors(environment, policies, branch):
    """Errors unless the environment admits that one branch and nothing else."""
    if environment.get("deployment_branch_policy") != {
        "protected_branches": False,
        "custom_branch_policies": True,
    }:
        return ["deployments are not limited to selected branches"]
    allowed = [
        (policy.get("type"), policy.get("name"))
        for policy in policies.get("branch_policies", [])
    ]
    if policies.get("total_count") != 1 or allowed != [("branch", branch)]:
        return [f"deployments are not limited to the {branch} branch"]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "environment", type=Path, help="JSON from the get-environment REST endpoint"
    )
    parser.add_argument("--reviewer", required=True)
    parser.add_argument("--branch", help="the only branch that may deploy")
    parser.add_argument(
        "--branch-policies",
        type=Path,
        help="JSON from the list-deployment-branch-policies REST endpoint",
    )
    arguments = parser.parse_args()
    if (arguments.branch is None) != (arguments.branch_policies is None):
        parser.error("--branch and --branch-policies go together")

    environment = json.loads(arguments.environment.read_text(encoding="utf-8"))
    errors = environment_errors(environment, arguments.reviewer)
    if arguments.branch_policies:
        policies = json.loads(arguments.branch_policies.read_text(encoding="utf-8"))
        errors += branch_errors(environment, policies, arguments.branch)
    name = environment.get("name", "unknown")
    for error in errors:
        print(f"{name} environment: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
