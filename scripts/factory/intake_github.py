#!/usr/bin/env python3
"""Read tickets from GitHub for intake.py. Read-only.

    intake_github.py next --output FILE [--assessments FILE] [--repository O/R]
        Writes intake.next_step as JSON. Agent output in FILE is data: never
        interpolate it into a shell, workflow expression, or GITHUB_OUTPUT.
    intake_github.py verify --ticket N --assessments FILE --work-digest HEX
                            [--repository O/R]
        Exits 0 only if the ticket and its one assessment in FILE still give the
        selected work. Take HEX from a trusted job output, not from an agent.

A ticket is skipped as unreadable with more than 100 labels, comments, body
edits, blockers, or events listed in EVENT_TYPES, more than 50 edits of one
comment, or more than MAX_PAGES timeline pages.

GITHUB_TOKEN needs issues and pull-requests read. Any lookup failure exits 1
and writes nothing.
"""

import argparse
import contextlib
import http.client
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import github_http
import intake

MAX_PAGES = 50
# REST timeline events that matter, and their GraphQL names.
EVENT_TYPES = {
    "labeled": "LABELED_EVENT",
    "unlabeled": "UNLABELED_EVENT",
    "renamed": "RENAMED_TITLE_EVENT",
    "comment_deleted": "COMMENT_DELETED_EVENT",
    "transferred": "TRANSFERRED_EVENT",
    "blocked_by_added": "BLOCKED_BY_ADDED_EVENT",
    "blocked_by_removed": "BLOCKED_BY_REMOVED_EVENT",
}
# GraphQL cannot list this one.
EVENTS = frozenset({*EVENT_TYPES, "converted_from_discussion"})
EDITS = "totalCount nodes{editedAt editor{...actor}}"
QUERY = f"""query($owner:String!,$name:String!,$number:Int!){{
  repository(owner:$owner,name:$name){{issue(number:$number){{
    number state title body createdAt lastEditedAt author{{...actor}}
    labels(first:100){{totalCount nodes{{name}}}}
    userContentEdits(first:100){{{EDITS}}}
    blockedBy(first:100){{totalCount nodes{{state}}}}
    issueDependenciesSummary{{blockedBy totalBlockedBy}}
    timelineItems(first:100,itemTypes:[{",".join(EVENT_TYPES.values())}]){{
      totalCount nodes{{...on Node{{id}}}}
    }}
    comments(first:100){{totalCount nodes{{
      id body createdAt lastEditedAt author{{...actor}}
      userContentEdits(first:50){{{EDITS}}}
    }}}}
  }}}}
}}
fragment actor on Actor{{...on User{{databaseId}} ...on Bot{{databaseId}}}}"""
class LookupFailed(Exception):
    """GitHub could not be read completely. The message has no ticket text."""


class Unreadable(LookupFailed):
    """One ticket could not be read reliably. Other tickets are unaffected."""


def http_transport(token):
    def send(method, path, body=None):
        # A plain path cannot change the host that API names.
        if not re.fullmatch(r"/[\w.-][\w./?=&%-]*", path, re.A):
            raise LookupFailed("refused an unexpected GitHub path")
        request = github_http.api_request(
            path, token, "redis-client-factory-intake", method=method,
            data=None if body is None else json.dumps(body).encode("utf-8"),
        )
        try:
            with github_http.open_api(request) as response:
                return json.load(response)
        except (OSError, ValueError, http.client.HTTPException):
            raise LookupFailed("GitHub request failed") from None

    return send


def _pages(send, path, query=""):
    for number in range(1, MAX_PAGES + 1):
        batch = send("GET", f"{path}?{query}per_page=100&page={number}")
        if not isinstance(batch, list):
            raise LookupFailed("GitHub returned an unexpected page")
        yield from batch
        # GitHub may return a short page that is not the last one.
        if not batch:
            return
    raise Unreadable("GitHub returned too many pages")


def _nodes(connection):
    if connection["totalCount"] != len(connection["nodes"]):
        raise Unreadable("GitHub returned a truncated list")
    return connection["nodes"]


def _actor(actor, key):
    return actor[key] if actor else None


def _edits(item):
    return [
        {
            "edited_at": entry["editedAt"],
            "editor_id": _actor(entry["editor"], "databaseId"),
        }
        for entry in _nodes(item["userContentEdits"])
    ]


def _issue(send, repository, number):
    owner, _, name = repository.partition("/")
    response = send(
        "POST",
        "/graphql",
        {
            "query": QUERY,
            "variables": {"owner": owner, "name": name, "number": number},
        },
    )
    if response.get("errors"):
        raise LookupFailed("GitHub query failed")
    issue = response["data"]["repository"]["issue"]
    if issue is None:
        raise Unreadable("GitHub returned no issue")
    return issue


def _event(entry):
    result = {
        "id": entry["id"],
        "event": entry["event"],
        "created_at": entry["created_at"],
        "actor_id": _actor(entry["actor"], "id"),
        # Absent is unknown, which intake refuses. Null means no app was used.
        "via_app": None,
    }
    if "performed_via_github_app" in entry:
        result["via_app"] = entry["performed_via_github_app"] is not None
    if entry["event"] in ("labeled", "unlabeled"):
        result["label"] = entry["label"]["name"]
    return result


def _events(send, path, issue):
    """The REST events, which alone name the app, checked against GraphQL's list."""
    events, ids = [], []
    for entry in _pages(send, path):
        if not isinstance(entry["event"], str) or not entry["event"]:
            raise Unreadable("GitHub returned an unknown event")
        if entry["event"] in EVENTS:
            events.append(_event(entry))
        if entry["event"] in EVENT_TYPES:
            ids.append(entry["node_id"])
    if sorted(ids) != sorted(node["id"] for node in _nodes(issue["timelineItems"])):
        raise Unreadable("GitHub returned an incomplete event history")
    return events


def _open_blockers(issue, events):
    """How many blockers are open, or None if any may be hidden from this token."""
    blockers = _nodes(issue["blockedBy"])
    count = sum(b is None or b["state"] != "CLOSED" for b in blockers)
    summary = issue["issueDependenciesSummary"]
    kinds = [entry["event"] for entry in events]
    recorded = kinds.count("blocked_by_added") - kinds.count("blocked_by_removed")
    if (
        summary["totalBlockedBy"] != len(blockers)
        or summary["blockedBy"] != count
        or recorded > len(blockers)
    ):
        return None
    return count


def fetch_ticket(send, repository, number):
    """The ticket as intake.py expects it, or LookupFailed."""
    try:
        issue = _issue(send, repository, number)
        path = f"/repos/{repository}/issues"
        events = _events(send, f"{path}/{number}/timeline", issue)
        states = {}
        # A state left out reads as blocked.
        for blocker in intake.blocker_numbers(
            f"{issue['title']}\n{issue['body']}"
        )[:20]:
            with contextlib.suppress(LookupFailed):
                states[blocker] = send("GET", f"{path}/{blocker}")["state"]
        ticket = {
            "number": issue["number"],
            "state": issue["state"].lower(),
            # GraphQL issue() never returns a pull request.
            "is_pull_request": False,
            "author_id": _actor(issue["author"], "databaseId"),
            "title": issue["title"],
            "body": issue["body"],
            "labels": [label["name"] for label in _nodes(issue["labels"])],
            "created_at": issue["createdAt"],
            "last_edited_at": issue["lastEditedAt"],
            "edits": _edits(issue),
            "comments": [
                {
                    "id": comment["id"],
                    "author_id": _actor(comment["author"], "databaseId"),
                    "body": comment["body"],
                    "created_at": comment["createdAt"],
                    "last_edited_at": comment["lastEditedAt"],
                    "edits": _edits(comment),
                }
                for comment in _nodes(issue["comments"])
            ],
            "events": events,
            "open_blockers": _open_blockers(issue, events),
            "blocker_states": states,
        }
        # Text and label history come from separate requests.
        if _issue(send, repository, number) != issue:
            raise Unreadable("ticket changed while it was being read")
        return ticket
    except (KeyError, TypeError, ValueError, AttributeError):
        raise Unreadable("GitHub returned an unexpected response") from None


def fetch_ready_tickets(send, repository):
    """Every open ready-for-agent ticket, and the numbers that were unreadable."""
    try:
        numbers = [
            entry["number"]
            for entry in _pages(send, f"/repos/{repository}/issues", "state=open&")
            if "pull_request" not in entry
            and intake.READY in {label["name"].casefold() for label in entry["labels"]}
        ]
    except (KeyError, TypeError, AttributeError):
        raise LookupFailed("GitHub returned an unexpected response") from None
    tickets, unreadable = [], []
    for number in numbers:
        try:
            tickets.append(fetch_ticket(send, repository, number))
        except Unreadable:
            unreadable.append(number)
    return tickets, unreadable


def _read_assessments(path):
    try:
        assessments = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):
        raise LookupFailed("the assessments file is unreadable") from None
    fields = {"ticket", "source_digest", "output"}
    if not isinstance(assessments, list) or not all(
        isinstance(entry, dict) and set(entry) == fields for entry in assessments
    ):
        raise LookupFailed("the assessments file is malformed")
    return assessments


def main(argv=None):
    parser = argparse.ArgumentParser(description="Factory ticket intake.")
    commands = parser.add_subparsers(dest="command", required=True)
    choose = commands.add_parser("next")
    choose.add_argument("--output", required=True)
    choose.add_argument("--assessments")
    check = commands.add_parser("verify")
    check.add_argument("--ticket", type=int, required=True)
    check.add_argument("--assessments", required=True)
    check.add_argument("--work-digest", required=True)
    for command in (choose, check):
        command.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    args = parser.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN")
    if not args.repository or not token:
        parser.error("--repository and GITHUB_TOKEN are required")
    send = http_transport(token)
    try:
        assessments = _read_assessments(args.assessments) if args.assessments else []
        if args.command == "verify":
            mine = [a for a in assessments if a["ticket"] == args.ticket]
            if len(mine) != 1:
                raise LookupFailed("expected one assessment of the ticket")
            ticket = fetch_ticket(send, args.repository, args.ticket)
            intake.verify(ticket, mine[0], args.work_digest)
            return 0
        tickets, unreadable = fetch_ready_tickets(send, args.repository)
        step = intake.next_step(tickets, assessments)
        step["skipped"] += [{"ticket": n, "reason": "unreadable"} for n in unreadable]
        Path(args.output).write_text(json.dumps(step), encoding="utf-8")
    except (LookupFailed, intake.Refused) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
