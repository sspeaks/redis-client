#!/usr/bin/env python3
"""Validate agent output and publish it. The only holder of the factory token.

    publish.py pull-request --ticket N --work-digest HEX --assessments FILE
               --patch FILE --text FILE --result FILE
    publish.py ticket --text FILE --result FILE
    publish.py comment --number N --text FILE --result FILE
    publish.py route --ticket N --result FILE        ready-for-agent to ready-for-human
    publish.py pause --reason REASON --result FILE

Run it from a trusted checkout of main, through factory-publish.yml, which allows
one publisher at a time (pause: factory-pause.yml). Exit 0 published, 1 refused,
3 too large: return the work for splitting. FILE for --result gets JSON with fixed
codes and numbers only; nothing printed ever contains agent text.

Agent text is one JSON object:
  pull-request  {"title": "", "summary": "", "paths": null}
                paths is null for a narrow or docs-only change, or an object with
                one line of text for every row of the pull request template.
  ticket        {"kind": "", "title": "", "body": "", "labels": []}
                kind is one of intake.py's; labels may be type:* and one priority:*.
                The triage label and factory-filed are set here, not by the agent.
  comment       {"body": ""}
Numbers come from the trusted caller, never from the agent.
publish-text-rules.md states what agent text may hold, for use in agent prompts.

Nothing from an agent is executed, interpolated into a command, or checked out.
The patch is parsed as data (patch_file.py) and applied in memory to the current
main, and the result goes to GitHub as one commit whose parent is that main. The
published tree must equal the one computed here.

Writes are the POSTs in _CREATES, adding ready-for-human, removing ready-for-agent,
commenting, and deleting a branch this same call created when its pull request
could not be opened. The gate is the last call before every one. Where the limits,
the current main, or the branch to delete must be read just before, the gate also
runs before those lookups. The senders themselves refuse any other method, path,
or body (_check_request) and call the gate, so a caller of a lower-level helper
cannot skip either. What such a caller can skip: the patch rules other than paths
and modes, the secret scan of file contents, the limits, and intake's checks of a
ticket. So import only the publish_* functions.
There is no operation for tags, Releases, variables, environments, workflows, or
label definitions, nor for editing, closing, transferring, or deleting an issue.
Labels must already exist, because GitHub creates unknown ones when an issue is
opened.

Exception to the gate: pause. Pausing must work when the gate refuses, so it is
the one write without it. It can only open an issue with a fixed title, a fixed
body, and the one label factory-paused. No other operation can set that label,
and none can remove it. No agent text reaches it. It is tried three times, which
can open more than one issue; a resume closes them all. A missing label refuses,
as does the gate then; if the lookup fails the pause is still tried.

A caller must treat anything but success and outcome `paused` from
factory-pause.yml as a stop, including skipped and cancelled. The gate refuses
after a failed or skipped factory-pause job, or a factory-pause-failed step, until
the next resume.

A ticket is created with the factory marker and the factory-filed label in one
request. Unless GitHub's answer confirms both, the factory pauses.

Any failed, truncated, or unexpected lookup refuses.

Environment: GITHUB_REPOSITORY, GITHUB_RUN_ID, FACTORY_PUBLISH_TOKEN (a
fine-grained token, because pull requests opened with GITHUB_TOKEN do not trigger
Tests CI), and FACTORY_GATE_TOKEN for gate.py.

Residual risks:
  * GitHub has no conditional writes, so anything that changes between the last
    lookup and the write is missed: a stop (see gate.py), main moving, another
    pull request or ticket, or a push to the branch about to be deleted.
  * A stop between creating the branch and opening the pull request leaves the
    branch, because deleting it would be another write; the result names it.
  * A killed process skips its cleanup and writes no result. It may leave a branch
    without a pull request, or a pull request nobody recorded. A ticket run without
    a result runs the factory-pause-failed step, unless the whole runner is lost.
    The ticket request always holds the marker and labels.
  * Deleting an issue, or editing one to remove both its label and its marker,
    lowers the daily count. This program can do neither.
  * secret_scan.py is a screen, not a proof.
"""

import argparse
import base64
import contextlib
import html.entities
import json
import os
import re
import stat
import sys
import time
import unicodedata
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import commit_id  # noqa: E402
import gate  # noqa: E402
import github_http  # noqa: E402
import intake  # noqa: E402
import intake_github  # noqa: E402
import patch_file  # noqa: E402
import secret_scan  # noqa: E402

MAX_CHANGED_LINES = 800
MAX_TICKETS_A_DAY = 3
MAX_OPEN_PULL_REQUESTS = 3
MAX_TEXT_BYTES = 200_000
MAX_ASSESSMENT_BYTES = 1_000_000
MAX_PAGES = 1000
TEMPLATE = Path(__file__).resolve().parents[2] / ".github/pull_request_template.md"
_PAUSE_DELAYS = (0, 2, 8)
MAX_COMMIT_LOOKUPS = 10
BRANCH_PREFIX = "factory/"
PAUSE_REASONS = {
    "main-broken": "Tests CI on main failed after a factory merge.",
    "repeated-reverts": "Factory merges were reverted twice in seven days.",
    "repeated-failures": "Three consecutive tickets failed.",
    "unmarked-ticket": "GitHub did not confirm the marker and labels of a ticket the "
    "factory filed, so it may look like the maintainer's. Check the newest issues.",
}
# What an agent may ask for. The rest is set here and checked by intake.py.
AGENT_LABELS = intake.DESCRIPTIVE_LABELS
TICKET_LABELS = AGENT_LABELS | {intake.READY, intake.HUMAN, intake.FACTORY_LABEL}
_BRANCH = re.compile(r"factory/ticket-([1-9][0-9]{0,8})-[1-9][0-9]{0,15}")
_CREATES = {
    "/git/trees": {"base_tree", "tree"},
    "/git/commits": {"message", "tree", "parents"},
    "/git/refs": {"ref", "sha"},
    "/pulls": {"title", "head", "base", "body"},
    "/issues": {"title", "body", "labels"},
}
_SKIP_CI = re.compile(
    r"\[[\W_]{0,9}(?:skip[\W_]{1,9}ci|ci[\W_]{1,9}skip|no[\W_]{1,9}ci|skip[\W_]{1,9}actions"
    r"|actions[\W_]{1,9}skip)[\W_]{0,9}\]|skip-checks\s{0,9}:",
    re.I,
)
_CLOSES = re.compile(
    r"(?<![a-z0-9])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)(?![a-z0-9])[^a-z0-9#.,;!?]{0,400}"
    r"(?:[\w./:-]{0,200}#\s?\d|gh-\d|[\w./:-]{0,200}/(?:issues|pull)/\d)",
    re.I,
)
_HTML = re.compile(r"<[A-Za-z/]")
_ENTITY = re.compile(r"&(?:#|([A-Za-z][A-Za-z0-9]{0,40};))")
# An address, or alone between spaces.
_MENTION = re.compile(r"(?<![A-Za-z0-9])@(?![ \n]|\Z)|@(?![A-Za-z0-9 \n]|\Z)")
_LINK = re.compile(
    r"\]\((?!https://[^\s()<>\"'\\]+\)|[A-Za-z0-9][A-Za-z0-9_./-]*(?:#[A-Za-z0-9_-]*)?\))|!\[|\]:"
)
_SCHEME = re.compile(r"(?:javascript|vbscript)\s*:(?=\S)", re.I)
_FENCE_LANGUAGES = (
    "", "bash", "c", "cabal", "console", "diff", "haskell", "json", "nix", "python",
    "sh", "shell", "text", "yaml",
)  # fmt: skip
# The only long values a lock file holds.
_LOCKED = re.compile(
    rf'\s*"(?:narHash": "sha256-[A-Za-z0-9+/]{{43}}=|rev": "{commit_id.PATTERN})",?\n?'
)


class Refused(Exception):
    """Nothing may be published. The message is a fixed code."""


class TooLarge(Refused):
    """Valid work that must be split."""


# Agent text


def _unique(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate key")
    return result


def _constant(_):
    raise ValueError("not JSON")


def _parse_text(data, fields):
    if len(data) > MAX_TEXT_BYTES:
        raise Refused("text-too-long")
    try:
        output = json.loads(
            data.decode("utf-8"), object_pairs_hook=_unique, parse_constant=_constant
        )
    except (ValueError, RecursionError):
        raise Refused("text-malformed") from None
    if not isinstance(output, dict) or set(output) != fields:
        raise Refused("text-malformed")
    return output


def _text(value, limit, known=None, *, one_line=False):
    if not isinstance(value, str) or not value.strip():
        raise Refused("text-malformed")
    if len(value) > limit or (one_line and ("\n" in value or "\t" in value)):
        raise Refused("text-malformed")
    _screen(value, known)
    return value


def _screen(value, known=None):
    """Refuse text that hides, notifies, links elsewhere, or drives GitHub.

    known(sha) tells whether a full commit id is this repository's.
    """
    if patch_file.hidden(value):
        raise Refused("text-hidden-characters")
    for text in (value, unicodedata.normalize("NFKC", value)):
        if re.search(r"<[!?]", text) or re.search(r"factory-(?:ticket|comment):", text, re.I):
            raise Refused("text-hidden-markup")
        if _SKIP_CI.search(text):
            raise Refused("text-skips-ci")
        spaced = re.sub(r"\s+", " ", text)
        if _CLOSES.search(spaced) or _CLOSES.search(re.sub(r"[*_~`\\]", "", spaced)):
            raise Refused("text-closes-issue")
        prose = _without_code(text)
        if _HTML.search(prose):
            raise Refused("text-html")
        if any(not name or name in html.entities.html5 for name in _ENTITY.findall(prose)):
            raise Refused("text-entity")
        if _MENTION.search(prose):
            raise Refused("text-mention")
        if _LINK.search(prose) or _SCHEME.search(prose):
            raise Refused("text-link")
    if secret_scan.found(value, known):
        raise Refused("secret-like")


def _without_code(text):
    """Drop code blocks in the one form accepted, and unambiguous code spans."""
    lines, kept, index = text.split("\n"), [], 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("```") and line[3:] in _FENCE_LANGUAGES:
            end = index + 1
            while end < len(lines) and "```" not in lines[end] and "~~~" not in lines[end]:
                end += 1
            if end >= len(lines) or lines[end] != "```":
                raise Refused("text-fence")
            kept.append("")
            index = end
        elif "```" in line or "~~~" in line:
            raise Refused("text-fence")
        else:
            kept.append(line)
        index += 1
    paragraphs = re.split(r"\n[ \t]*(?=\n)", "\n".join(kept))
    return "\n".join(map(_without_spans, paragraphs))


def _without_spans(paragraph):
    """Drop `code` where no other reading is possible.

    Every line must hold whole spans of one backtick each. Escapes, longer runs,
    and math move where spans begin; a bar inside one may split a table cell.
    """
    if any(sign in paragraph for sign in ("``", "\\`", "$")):
        return paragraph
    for line in paragraph.split("\n"):
        parts = line.split("`")
        if len(parts) % 2 == 0 or any("|" in span for span in parts[1::2]):
            return paragraph
    return re.sub(r"`[^`\n]*`", "`", paragraph)


def _comment_text(data, known):
    body = _text(_parse_text(data, {"body"})["body"], 40_000, known)
    try:
        return intake.render_factory_comment(body)
    except Exception:
        raise Refused("text-malformed") from None


def _pull_request_text(data, ticket, template, known):
    output = _parse_text(data, {"title", "summary", "paths"})
    title = _text(output["title"], 120, known, one_line=True).strip()
    summary = _text(output["summary"], 20_000, known)
    paths = output["paths"]
    if paths is not None:
        if not isinstance(paths, dict):
            raise Refused("text-malformed")
        paths = {
            row: _text(value, 1_000, known, one_line=True).replace("|", "\\|")
            for row, value in paths.items()
        }
    written = "\n".join([title, summary, *(paths or {}).values()])
    body = _fill_template(template, ticket, summary, paths)
    _screen(_without_first_line(body), known)
    return title, body, written


def _without_first_line(body):
    return body.partition("\n")[2]


def _fill_template(template, ticket, summary, paths):
    """Fill the trusted template line by line; agent text is never rescanned."""
    marked = "Narrow or docs-only change" if paths is None else "Cross-cutting change"
    lines, filled, rows, marks = [], 0, set(), 0
    for line in template.splitlines():
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if line == "Closes #":
            line, filled = f"Closes #{ticket}", filled + 1
        elif line.startswith("<!--") and line.endswith("-->"):
            line, filled = summary, filled + 1
        elif line.startswith(f"- [ ] **{marked}:**"):
            line, marks = line.replace("- [ ]", "- [x]", 1), marks + 1
        elif line.startswith("| ") and len(cells) == 2 and cells[1].startswith("_"):
            rows.add(cells[0])
            if paths is not None:
                line = f"| {cells[0]} | {paths.get(cells[0], '')} |"
        lines.append(line)
    if filled != 2 or marks != 1 or not rows:
        raise Refused("template-unexpected")
    if paths is not None and set(paths) != rows:
        raise Refused("text-malformed")
    return "\n".join(lines) + "\n"


def _ticket_text(data, known):
    output = _parse_text(data, {"kind", "title", "body", "labels"})
    kind, labels = output["kind"], output["labels"]
    if kind not in (*intake.SELF_APPROVED_KINDS, *intake.HUMAN_REVIEWED_CLASSES):
        raise Refused("text-malformed")
    title = _text(output["title"], 120, known, one_line=True).strip()
    body = _text(output["body"], 40_000, known)
    if secret_scan.found(f"{title}\n{body}", known):
        raise Refused("secret-like")
    if not isinstance(labels, list) or len(labels) > 6:
        raise Refused("text-malformed")
    if not all(isinstance(label, str) and label in AGENT_LABELS for label in labels):
        raise Refused("label-forbidden")
    if len(set(labels)) != len(labels):
        raise Refused("text-malformed")
    if sum(label in intake.PRIORITIES for label in labels) > 1:
        raise Refused("text-malformed")
    try:
        triage = intake.factory_triage_label(kind, title, body)
        if "type:security" in labels:
            triage = intake.HUMAN
        labels = [intake.FACTORY_LABEL, triage, *labels]
        _check_new_ticket(kind, title, body, labels)
        return title, intake.render_factory_ticket(kind, body), labels
    except Refused:
        raise
    except Exception:
        raise Refused("text-malformed") from None


def _check_new_ticket(kind, title, text, labels):
    """The one place intake's label policy is called."""
    try:
        verdict = intake.check_new_ticket_labels(kind, title, text, labels)
    except Exception:
        raise Refused("label-forbidden") from None
    if verdict is not None:
        raise Refused("label-forbidden")


# Patch


def _parse_patch(data, text="", known=None):
    """The changes. `text` is published with them, so a value may not span both."""
    try:
        changes = patch_file.parse(data)
    except patch_file.Rejected as error:
        raise Refused(str(error)) from None
    added = [
        line
        for change in changes
        for line in change.added()
        if change.new != "flake.lock" or not _LOCKED.fullmatch(line)
    ]
    if any(secret_scan.found(change.new or "") for change in changes):
        raise Refused("secret-like")
    # All at once, so that a value split between files is seen whole.
    if secret_scan.found(f"{text}\n{''.join(added)}", known):
        raise Refused("secret-like")
    if patch_file.changed_lines(changes) > MAX_CHANGED_LINES:
        raise TooLarge("too-many-changed-lines")
    return changes


# GitHub


def _require_known_labels(labels):
    """A second check of a new ticket's labels, at the write itself."""
    if type(labels) is not list or len(set(map(str, labels))) != len(labels):
        raise Refused("label-forbidden")
    if not all(type(label) is str and label in TICKET_LABELS for label in labels):
        raise Refused("label-forbidden")
    states = [label for label in labels if label in (intake.READY, intake.HUMAN)]
    if intake.FACTORY_LABEL not in labels or len(states) != 1:
        raise Refused("label-forbidden")


def _require_marker(body):
    """A ticket without intake's mark would be read as the maintainer's own."""
    marker = intake.MARKER.fullmatch(body.partition("\n")[0]) if isinstance(body, str) else None
    if not marker:
        raise Refused("ticket-unmarked")


def _restricted(send, repository, gate_check):
    """A sender that refuses requests without a use here, and gates every write.

    Only the fixed pause content is sent without the gate.
    """
    if getattr(send, "restricted_by", None) == (repository, gate_check):
        return send

    def restricted(method, path, body):
        try:
            permitted = _check_request(repository, method, path, body)
        except (KeyError, TypeError, AttributeError, ValueError):
            permitted = False
        except (Refused, patch_file.Rejected):
            permitted = False
        if permitted is not True:
            raise Refused("operation-forbidden")
        if method != "GET" and path != "/graphql" and not _is_pause_issue(body):
            try:
                gate_check()
            except Exception:
                raise Refused("gate-refused") from None
        return send(method, path, body)

    restricted.restricted_by = (repository, gate_check)
    return restricted


def _is_pause_issue(body):
    return body in [_pause_content(reason) for reason in PAUSE_REASONS]


_READ = re.compile(r"/(?:issues|pulls|labels|git)(?:[/?](?:[A-Za-z0-9/_.=&?-]|%3A)*)?")
_ISSUE = r"/issues/[1-9][0-9]{0,8}"


def _check_request(repository, method, path, body):
    if method == "POST" and path == "/graphql":
        owner, _, name = repository.partition("/")
        variables = body["variables"]
        return (
            set(body) == {"query", "variables"}
            and body["query"] == intake_github.QUERY
            and variables == {"owner": owner, "name": name, "number": variables["number"]}
            and type(variables["number"]) is int
        )
    root = f"/repos/{repository}"
    if not path.startswith(f"{root}/"):
        return False
    path = path.removeprefix(root)
    if method == "GET":
        return body is None and ".." not in path and bool(_READ.fullmatch(path))
    if method == "DELETE":
        branch = path.removeprefix("/git/refs/heads/")
        return body is None and bool(
            (branch != path and _BRANCH.fullmatch(branch))
            or re.fullmatch(rf"{_ISSUE}/labels/{intake.READY}", path)
        )
    if method != "POST":
        return False
    if re.fullmatch(rf"{_ISSUE}/labels", path):
        return body == {"labels": [intake.HUMAN]}
    if re.fullmatch(rf"{_ISSUE}/comments", path):
        mark, _, text = body["body"].partition("\n")
        _screen(text, _any_commit)
        return set(body) == {"body"} and mark == intake.COMMENT_MARKER
    if path not in _CREATES or set(body) != _CREATES[path]:
        return False
    if path == "/issues":
        if _is_pause_issue(body):
            return True
        _require_known_labels(body["labels"])
        _require_marker(body["body"])
        _screen(body["title"], _any_commit)
        _screen(_without_first_line(body["body"]), _any_commit)
        return True
    if path == "/git/refs":
        branch = body["ref"].removeprefix("refs/heads/")
        return branch != body["ref"] and bool(_BRANCH.fullmatch(branch)) and _is_sha(body["sha"])
    if path == "/pulls":
        _screen(body["title"], _any_commit)
        _screen(_without_first_line(body["body"]), _any_commit)
        branch = _BRANCH.fullmatch(body["head"])
        return (
            body["base"] == "main"
            and bool(branch)
            and body["body"].startswith(f"Closes #{branch[1]}\n")
        )
    if path == "/git/commits":
        message = re.fullmatch(r"([^\n]+)\n\nFor #[1-9][0-9]{0,8}\n", body["message"])
        _screen(message[1], _any_commit)
        return (
            type(body["parents"]) is list
            and len(body["parents"]) == 1
            and _is_sha(body["parents"][0])
            and _is_sha(body["tree"])
        )
    for entry in body["tree"]:
        patch_file.check_path(entry["path"])
        if entry["mode"] not in patch_file.REGULAR or entry["type"] != "blob":
            return False
        if set(entry) == {"path", "mode", "type", "sha"}:
            if entry["sha"] is not None:
                return False
        elif set(entry) != {"path", "mode", "type", "content"}:
            return False
    return bool(body["tree"]) and _is_sha(body["base_tree"])


def _any_commit(sha):
    return True  # Already checked; only other secrets are looked for again.


def _pause_content(reason):
    return {
        "title": "Factory paused",
        "body": f"{PAUSE_REASONS[reason]}\n\nFactory work stays stopped until the "
        "maintainer approves a Factory resume run.\n",
        "labels": [gate.PAUSE_LABEL],
    }


class _GitHub:
    """Reads are public; every write but the pause goes through _write."""

    def __init__(self, send, repository, gate_check, branch=None):
        self._send = _restricted(send, repository, gate_check)
        self.repository = repository
        self.root = f"/repos/{repository}"
        self.gate_check = gate_check
        self.branch_name = branch  # The only branch this run may touch.
        self.commit = None  # The only commit it may put there.
        self.sent = False
        self.commits = {}

    def read(self, path):
        try:
            return self._send("GET", self.root + path, None)
        except Exception:
            raise Refused("lookup-failed") from None

    def pages(self, path):
        """Every item. Only an empty page proves the end of a list."""
        short = False
        for number in range(1, MAX_PAGES + 1):
            page = self.read(f"{path}&per_page=100&page={number}")
            if not isinstance(page, list) or len(page) > 100:
                raise Refused("lookup-failed")
            if not page:
                return
            if short:
                raise Refused("lookup-failed")
            short = len(page) < 100
            yield from page
        raise Refused("lookup-failed")

    def known_commit(self, sha):
        if sha not in self.commits and len(self.commits) < MAX_COMMIT_LOOKUPS:
            try:
                self.commits[sha] = self.read(f"/git/commits/{_sha(sha)}")["sha"] == sha
            except (Refused, KeyError, TypeError):
                self.commits[sha] = False
        return self.commits.get(sha, False)

    def _create(self, path, body, recheck=None):
        if path not in _CREATES or set(body) != _CREATES[path]:
            raise Refused("operation-forbidden")
        if path == "/issues":
            _require_known_labels(body["labels"])
            _require_marker(body["body"])
        answer = self._write("POST", path, body, recheck)
        if path == "/git/commits":
            self.commit = _sha(answer["sha"])
        return answer

    def _delete_branch(self, branch, commit):
        if branch != self.branch_name or not commit or commit != self.commit:
            raise Refused("operation-forbidden")

        def recheck():
            if self.branch(branch) != commit:
                raise Refused("branch-moved")

        self._write("DELETE", f"/git/refs/heads/{branch}", None, recheck)

    def _comment(self, number, text):
        return self._write("POST", f"/issues/{_number(number)}/comments", {"body": text})

    def _route_to_human(self, ticket):
        """`ticket` is a fresh one from intake_github."""
        try:
            number = _number(ticket["number"])
            if ticket["is_pull_request"] is not False or intake.READY not in ticket["labels"]:
                raise ValueError("not a ready ticket")
            verdict = intake.check_label_change(ticket, add=[intake.HUMAN], remove=[intake.READY])
        except Exception:
            raise Refused("label-forbidden") from None
        if verdict is not None:
            raise Refused("label-forbidden")
        # Added first, so a failure between the writes leaves it ineligible.
        path = f"/issues/{number}/labels"
        self._write("POST", path, {"labels": [intake.HUMAN]})
        self._write("DELETE", f"{path}/{intake.READY}", None)

    def _open_pause(self, reason):
        """The one write without the gate. Everything sent is fixed here."""
        for delay in _PAUSE_DELAYS:
            time.sleep(delay)
            with contextlib.suppress(Exception):
                return self._send("POST", f"{self.root}/issues", _pause_content(reason))
        raise Refused("write-failed")

    def _owns(self, path, body):
        """Whether this run may touch the branch a request names."""
        if path == "/git/refs":
            ref = {"ref": f"refs/heads/{self.branch_name}", "sha": self.commit}
            return bool(self.commit) and body == ref
        if path == "/pulls":
            return bool(self.commit) and body["head"] == self.branch_name
        if path.startswith("/git/refs/"):
            return bool(self.commit) and path == f"/git/refs/heads/{self.branch_name}"
        return True

    def _write(self, method, path, body, recheck=None):
        # Checked here too, so that nothing is looked up for a forbidden request.
        try:
            permitted = _check_request(self.repository, method, self.root + path, body)
        except Exception:
            permitted = False
        if permitted is not True or not self._owns(path, body) or _is_pause_issue(body):
            raise Refused("operation-forbidden")
        if recheck:
            try:
                self.gate_check()
            except Exception:
                raise Refused("gate-refused") from None
            recheck()
        try:
            answer = self._send(method, self.root + path, body)
        except Refused:
            raise  # Before anything was sent.
        except Exception:
            self.sent = True
            raise Refused("write-failed") from None
        self.sent = True
        return answer

    def branch(self, name):
        ref = self.read(f"/git/ref/heads/{name}")
        if ref["ref"] != f"refs/heads/{name}" or ref["object"]["type"] != "commit":
            raise Refused("lookup-failed")
        return _sha(ref["object"]["sha"])

    def tree(self, sha):
        """{path: (mode, sha)} for every file, link, and submodule."""
        body = self.read(f"/git/trees/{sha}?recursive=1")
        if body["truncated"] is not False or body["sha"] != sha:
            raise Refused("lookup-failed")
        result = {}
        for entry in body["tree"]:
            if entry["type"] == "tree":
                continue
            if entry["path"] in result:
                raise Refused("lookup-failed")
            result[entry["path"]] = (entry["mode"], _sha(entry["sha"]))
        return result

    def blob(self, sha):
        body = self.read(f"/git/blobs/{sha}")
        if body["encoding"] != "base64":
            raise Refused("lookup-failed")
        content = base64.b64decode("".join(body["content"].split()), validate=True)
        if patch_file.blob_id(content) != sha:
            raise Refused("lookup-failed")
        return content

    def require_label(self, name):
        label = self.read(f"/labels/{urllib.parse.quote(name, safe='')}")
        if label["name"] != name:
            raise Refused("label-missing")


def _is_sha(value):
    return commit_id.is_commit_id(value)


def _sha(value):
    if not _is_sha(value):
        raise Refused("lookup-failed")
    return value


def _require_open_slot(github, ticket):
    count = 0
    numbers = set()
    for pull in github.pages("/pulls?state=open&sort=created&direction=desc"):
        if pull["state"] != "open" or pull["number"] in numbers:
            continue
        numbers.add(pull["number"])
        repository = pull["head"]["repo"]
        # Anyone can name a fork's branch; only this repository's are ours.
        if repository is None:
            continue
        if f"/repos/{repository['full_name']}".casefold() != github.root.casefold():
            continue
        branch = pull["head"]["ref"].casefold()
        if branch.startswith(f"{BRANCH_PREFIX}ticket-{ticket}-"):
            raise Refused("ticket-already-published")
        count += branch.startswith(BRANCH_PREFIX)
    if count >= MAX_OPEN_PULL_REQUESTS:
        raise Refused("open-pull-request-limit")


def _require_ticket_quota(github, now):
    pacific = ZoneInfo("America/Los_Angeles")
    today = now.astimezone(pacific).date()
    filed, empty = set(), True
    for issue in github.pages("/issues?state=all&sort=created&direction=desc"):
        empty = False
        if "pull_request" in issue:
            continue
        created = datetime.fromisoformat(issue["created_at"].replace("Z", "+00:00"))
        if created.astimezone(pacific).date() < today:
            continue
        labels = {label["name"].casefold() for label in issue["labels"]}
        marked = "factory-ticket:" in (issue["body"] or "")
        author = issue["user"]["id"] if issue["user"] else None
        # Others can copy the marker into their own issues; only labels are trusted there.
        if intake.FACTORY_LABEL in labels or (marked and author == intake.MAINTAINER_ID):
            filed.add(issue["number"])
    if empty:  # This repository has issues, so the answer is incomplete.
        raise Refused("lookup-failed")
    if len(filed) >= MAX_TICKETS_A_DAY:
        raise Refused("ticket-limit")


def _issue_number(issue, labels):
    if {label["name"] for label in issue["labels"]} != set(labels):
        raise Refused("write-unexpected")
    if type(issue["number"]) is not int:
        raise Refused("write-unexpected")
    return issue["number"]


def _commit(github, changes, title, ticket):
    main = github.branch("main")
    commit = github.read(f"/git/commits/{main}")
    if commit["sha"] != main:
        raise Refused("lookup-failed")
    base_tree = _sha(commit["tree"]["sha"])
    tree = github.tree(base_tree)
    try:
        patch_file.check_paths(changes, tree)
        expected, entries = dict(tree), []
        for change in changes:
            base = None if change.old is None else github.blob(tree[change.old][1])
            content = patch_file.apply(change, base)
            mode = "100644" if change.old is None else tree[change.old][0]
            if change.old is not None and change.old != change.new:
                del expected[change.old]
                entries.append({"path": change.old, "mode": mode, "type": "blob", "sha": None})
            if change.new is not None:
                expected[change.new] = (mode, patch_file.blob_id(content))
                entries.append(
                    {
                        "path": change.new,
                        "mode": mode,
                        "type": "blob",
                        "content": content.decode("utf-8"),
                    }
                )
    except patch_file.Rejected as error:
        raise Refused(str(error)) from None
    except UnicodeDecodeError:
        raise Refused("patch-not-utf8") from None
    created = github._create("/git/trees", {"base_tree": base_tree, "tree": entries})
    new_tree = _sha(created["sha"])
    if new_tree == base_tree or github.tree(new_tree) != expected:
        raise Refused("write-unexpected")
    message = f"{title}\n\nFor #{ticket}\n"
    created = github._create(
        "/git/commits", {"message": message, "tree": new_tree, "parents": [main]}
    )
    parents = [parent["sha"] for parent in created["parents"]]
    if parents != [main] or created["tree"]["sha"] != new_tree:
        raise Refused("write-unexpected")
    return main, _sha(created["sha"])


def _guarded(operation):
    def guarded(*arguments, **options):
        try:
            return operation(*arguments, **options)
        except Refused:
            raise
        except Exception:  # Any response that is not as expected.
            raise Refused("lookup-failed") from None

    return guarded


@_guarded
def publish_pull_request(
    send,
    repository,
    gate_check,
    verify_ticket,
    *,
    ticket,
    run_id,
    patch,
    text,
    template,
    on_branch=lambda name: None,
):
    """Open one pull request.

    verify_ticket() raises unless the ticket still gives the selected work.
    on_branch hears the branch's name while it may remain without a pull request.
    """
    _number(ticket)
    if type(run_id) is not int:
        raise Refused("input-malformed")
    branch = f"{BRANCH_PREFIX}ticket-{ticket}-{run_id}"
    github = _GitHub(send, repository, gate_check, branch)
    title, body, written = _pull_request_text(text, ticket, template, github.known_commit)
    changes = _parse_patch(patch, written, github.known_commit)
    _require_open_slot(github, ticket)
    main, commit = _commit(github, changes, title, ticket)

    def recheck():
        _require_open_slot(github, ticket)
        if github.branch("main") != main:
            raise Refused("main-moved")

    recheck()
    try:
        verify_ticket()
    except Exception:
        raise Refused("ticket-ineligible") from None
    try:
        ref = github._create(
            "/git/refs", {"ref": f"refs/heads/{branch}", "sha": commit}, recheck
        )
    except Refused as error:
        if str(error) == "write-failed":  # The answer may be what was lost.
            on_branch(branch)
        raise
    on_branch(branch)
    try:
        if ref["ref"] != f"refs/heads/{branch}" or ref["object"]["sha"] != commit:
            raise Refused("write-unexpected")
        pull = github._create(
            "/pulls", {"title": title, "head": branch, "base": "main", "body": body}, recheck
        )
        if (
            pull["head"]["sha"] != commit
            or pull["head"]["ref"] != branch
            or pull["base"]["ref"] != "main"
            or type(pull["number"]) is not int
        ):
            raise Refused("write-unexpected")
    except Exception:
        # The first failure is the one to report.
        with contextlib.suppress(Exception):
            github._delete_branch(branch, commit)
            on_branch(None)
        raise
    on_branch(None)
    return pull["number"], branch, commit


@_guarded
def publish_ticket(send, repository, gate_check, *, text, now):
    github = _GitHub(send, repository, gate_check)
    title, body, labels = _ticket_text(text, github.known_commit)
    for label in labels:
        github.require_label(label)
    _require_ticket_quota(github, now)
    content = {"title": title, "body": body, "labels": labels}
    try:
        issue = github._create("/issues", content, lambda: _require_ticket_quota(github, now))
        _require_marker(issue["body"].replace("\r\n", "\n"))
        return _issue_number(issue, labels)
    except Exception:
        if not github.sent:
            raise
        # There may now be a ticket that looks like the maintainer's.
        try:
            publish_pause(send, repository, reason="unmarked-ticket")
        except Exception:
            raise Refused("ticket-unverified-not-paused") from None
        raise Refused("ticket-unverified-paused") from None


@_guarded
def publish_comment(send, repository, gate_check, *, number, text):
    github = _GitHub(send, repository, gate_check)
    body = _comment_text(text, github.known_commit)
    issue = github.read(f"/issues/{_number(number)}")
    if issue["number"] != number or issue["locked"] is not False:
        raise Refused("comment-forbidden")
    if any(label["name"].casefold() == gate.PAUSE_LABEL for label in issue["labels"]):
        raise Refused("comment-forbidden")
    return github._comment(number, body)["id"]


@_guarded
def publish_route(send, repository, gate_check, *, ticket, fetch):
    """Move a ticket to ready-for-human. fetch() gives a fresh intake ticket."""
    _number(ticket)
    github = _GitHub(send, repository, gate_check)
    github.require_label(intake.HUMAN)
    try:
        current = fetch()
        if current["number"] != ticket:
            raise ValueError("another issue")
    except Exception:
        raise Refused("label-forbidden") from None
    github._route_to_human(current)
    return ticket


@_guarded
def publish_pause(send, repository, *, reason):
    if reason not in PAUSE_REASONS:
        raise Refused("input-malformed")
    github = _GitHub(send, repository, _never_allowed)
    try:
        missing = not gate.pause_label_exists(
            repository, lambda path: (github._send("GET", path, None), None)
        )
    except Exception:
        missing = False  # Unknown, and a pause matters more.
    if missing:  # Opening the issue would create the label.
        raise Refused("label-missing")
    issue = github._open_pause(reason)
    names = [label["name"].casefold() for label in issue["labels"]]
    if names != [gate.PAUSE_LABEL] or type(issue["number"]) is not int:
        raise Refused("write-unexpected")
    return issue["number"]


def _never_allowed():
    raise Refused("operation-forbidden")  # A pause has no other write.


def _number(value):
    if type(value) is not int or not 0 < value < 10**9:
        raise Refused("input-malformed")
    return value


# Command line


def _transport(token, repository, gate_check):
    def send(method, path, body):
        request = github_http.api_request(
            path, token, "factory-publisher", method=method,
            data=None if body is None else json.dumps(body).encode("ascii"),
            headers={"Cache-Control": "no-cache", "Content-Type": "application/json"},
        )
        with github_http.open_api(request, timeout=60) as response:
            return None if method == "DELETE" else json.load(response)

    return _restricted(send, repository, gate_check)


def _read_file(path, limit):
    """Read a regular file, not a link or device the artifact may contain."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Refused("input-missing")
            data = stream.read(limit + 1)
    except OSError:
        raise Refused("input-missing") from None
    if len(data) > limit:
        raise Refused("input-too-long")
    return data


def _ticket_verifier(send, repository, arguments):
    """Check the ticket afresh against the assessment it was selected under."""
    if not re.fullmatch(r"[0-9a-f]{64}", arguments.work_digest):
        raise Refused("input-malformed")
    try:
        assessments = json.loads(
            _read_file(arguments.assessments, MAX_ASSESSMENT_BYTES), object_pairs_hook=_unique
        )
        (assessment,) = [a for a in assessments if a["ticket"] == arguments.ticket]
        if set(assessment) != {"ticket", "source_digest", "output"}:
            raise ValueError("fields")
    except Refused:
        raise
    except Exception:
        raise Refused("assessment-malformed") from None

    def verify():
        ticket = _fetch_ticket(send, repository, arguments.ticket)
        intake.verify(ticket, assessment, arguments.work_digest)

    return verify


def _fetch_ticket(send, repository, number):
    return intake_github.fetch_ticket(
        lambda method, path, body=None: send(method, path, body), repository, number
    )


def _run(arguments, environment, result):
    repository = environment.get("GITHUB_REPOSITORY", "")
    token = environment.get("FACTORY_PUBLISH_TOKEN", "")
    run_id = environment.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+", repository):
        raise Refused("environment-malformed")
    if not re.fullmatch(r"[1-9][0-9]{0,15}", run_id):
        raise Refused("environment-malformed")
    # GITHUB_TOKEN's events do not start workflows, so Tests CI would not run.
    if not re.fullmatch(r"github_pat_[A-Za-z0-9_]+", token):
        raise Refused("environment-malformed")

    def gate_check():
        gate.require("publish")

    send = _transport(token, repository, gate_check)

    if arguments.operation == "pull-request":
        number, branch, commit = publish_pull_request(
            send,
            repository,
            gate_check,
            _ticket_verifier(send, repository, arguments),
            ticket=arguments.ticket,
            run_id=int(run_id),
            patch=_read_file(arguments.patch, patch_file.MAX_BYTES),
            text=_read_file(arguments.text, MAX_TEXT_BYTES),
            template=TEMPLATE.read_text(encoding="utf-8"),
            on_branch=lambda name: result.update(branch_left=name),
        )
        result.update(number=number, branch=branch, commit=commit)
    elif arguments.operation == "ticket":
        text = _read_file(arguments.text, MAX_TEXT_BYTES)
        result["number"] = publish_ticket(
            send, repository, gate_check, text=text, now=datetime.now(timezone.utc)
        )
    elif arguments.operation == "comment":
        text = _read_file(arguments.text, MAX_TEXT_BYTES)
        publish_comment(send, repository, gate_check, number=arguments.number, text=text)
        result["number"] = arguments.number
    elif arguments.operation == "route":
        result["number"] = publish_route(
            send,
            repository,
            gate_check,
            ticket=arguments.ticket,
            fetch=lambda: _fetch_ticket(send, repository, arguments.ticket),
        )
    else:
        result["number"] = publish_pause(send, repository, reason=arguments.reason)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Publish validated factory output.")
    operations = parser.add_subparsers(dest="operation", required=True)
    pull = operations.add_parser("pull-request")
    pull.add_argument("--ticket", type=int, required=True)
    pull.add_argument("--work-digest", required=True)
    pull.add_argument("--assessments", required=True)
    pull.add_argument("--patch", required=True)
    ticket = operations.add_parser("ticket")
    comment = operations.add_parser("comment")
    comment.add_argument("--number", type=int, required=True)
    route = operations.add_parser("route")
    route.add_argument("--ticket", type=int, required=True)
    pause = operations.add_parser("pause")
    pause.add_argument("--reason", choices=sorted(PAUSE_REASONS), required=True)
    for operation in (pull, ticket, comment):
        operation.add_argument("--text", required=True)
    for operation in (pull, ticket, comment, route, pause):
        operation.add_argument("--result", required=True)
    arguments = parser.parse_args(argv)
    result = {"outcome": "refused", "code": "internal-error"}
    status = 1
    try:
        _run(arguments, os.environ, result)
        result.update(outcome="published", code="ok")
        status = 0
    except TooLarge as error:
        result.update(outcome="split", code=str(error))
        status = 3
    except Refused as error:
        result["code"] = str(error)
    except Exception:  # A traceback could carry agent text into the log.
        pass
    if arguments.operation == "ticket":
        # Whether the factory-pause-failed step must run.
        result["pause"] = {
            "ticket-unverified-paused": "done",
            "ticket-unverified-not-paused": "failed",
            "internal-error": "failed",
        }.get(result["code"], "unneeded")
    Path(arguments.result).write_text(json.dumps(result) + "\n", encoding="ascii")
    print(f"Factory publisher: {result['outcome']} ({result['code']})")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
