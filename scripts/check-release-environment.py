"""Fail unless a GitHub Environment holds a job for the maintainer.

GitHub silently creates a missing environment without protection rules, so a
job's `environment:` key alone does not prove that anything waits for approval.

--no-reviewer is for an environment that deliberately waits for no one, such as
factory-agent and factory-publish: it must then have no administrator bypass, a
branch policy and nothing else, and --branch is required.

--name fails unless the answer is for that environment. An answer that cannot be
read fails too.

This cannot stop another ref: a workflow there can skip the check, and a secret
also stored at repository or organization level needs no environment at all. Only
the environment's own branch policy and the absence of such a copy protect the
token, so the setup wizard verifies both.
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


def unattended_errors(environment):
    """Errors unless the only protection is the branch policy, without bypass."""
    errors = []
    if environment.get("can_admins_bypass") is not False:
        errors.append("administrator bypass is not disabled")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or [
        rule.get("type") if isinstance(rule, dict) else None for rule in rules
    ] != ["branch_policy"]:
        errors.append("protection is not exactly a branch policy")
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
    total = policies.get("total_count")
    if type(total) is not int or total != 1 or allowed != [("branch", branch)]:
        return [f"deployments are not limited to the {branch} branch"]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "environment", type=Path, help="JSON from the get-environment REST endpoint"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--reviewer")
    mode.add_argument("--no-reviewer", action="store_true", help="nothing may wait for a person")
    parser.add_argument("--name", help="the environment the answer must be for")
    parser.add_argument("--branch", help="the only branch that may deploy")
    parser.add_argument(
        "--branch-policies",
        type=Path,
        help="JSON from the list-deployment-branch-policies REST endpoint",
    )
    arguments = parser.parse_args()
    if (arguments.branch is None) != (arguments.branch_policies is None):
        parser.error("--branch and --branch-policies go together")
    if arguments.no_reviewer and arguments.branch is None:
        parser.error("--no-reviewer needs --branch")

    name = arguments.name or "unknown"
    try:
        environment = json.loads(arguments.environment.read_text(encoding="utf-8"))
        if not isinstance(environment, dict):
            environment = {}
        name = arguments.name or environment.get("name", "unknown")
        errors = []
        if arguments.name is not None and environment.get("name") != arguments.name:
            errors.append("is not the expected environment")
        if arguments.no_reviewer:
            errors += unattended_errors(environment)
        else:
            errors += environment_errors(environment, arguments.reviewer)
        if arguments.branch_policies:
            policies = json.loads(arguments.branch_policies.read_text(encoding="utf-8"))
            if not isinstance(policies, dict):
                policies = {}
            errors += branch_errors(environment, policies, arguments.branch)
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
        errors = [f"cannot be read ({type(error).__name__})"]
    for error in errors:
        print(f"{name} environment: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
