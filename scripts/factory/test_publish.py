import contextlib
import hashlib
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
import urllib.error
from base64 import b64encode
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import classify
import gate
import intake
import patch_file
import publish
from test_patch_file import edit, new_file, rename
from test_secret_scan import TOKEN

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
REPO = "owner/repo"
publish._PAUSE_DELAYS = (0, 0, 0)
NOW = datetime(2026, 11, 25, 6, 0, tzinfo=timezone.utc)  # 22:00 on the 24th, Pacific
TODAY, YESTERDAY = "2026-11-24T09:00:00Z", "2026-11-24T07:59:59Z"
MAIN = "a" * 40
BASE_TREE = "b" * 40
FILES = {
    "docs/a.md": ("100644", b"one\n"),
    "LICENSE-link": ("120000", b"LICENSE"),
    "run.sh": ("100755", b"x\n"),
}


TICKET = {
    "number": 9,
    "is_pull_request": False,
    "labels": ["ready-for-agent"],
    "author_id": 3,
    "title": "T",
    "body": "B",
    "events": [],
    "edits": [],
    "last_edited_at": None,
}


def text(**fields):
    return json.dumps({"title": "Say two", "summary": "Because.", "paths": None, **fields}).encode()


def ticket_text(**fields):
    return json.dumps(
        {
            "kind": "tests",
            "title": "Cover retries",
            "body": "Nothing covers it.",
            "labels": ["type:testing", "priority:p2"],
            **fields,
        }
    ).encode()


class FakeGitHub:
    """Enough of GitHub's API to hold objects, refs, pulls, issues and labels."""

    def __init__(self):
        self.log, self.trees, self.blobs, self.commits = [], {}, {}, {}
        self.refs = {"main": MAIN}
        self.pulls, self.issues = [], [self.issue(1, YESTERDAY)]
        self.labels = {*publish.TICKET_LABELS, "factory-paused", "factory-approved"}
        self.override = {}
        for _, content in FILES.values():
            self.blobs[patch_file.blob_id(content)] = content
        self.trees[BASE_TREE] = {p: (m, patch_file.blob_id(c)) for p, (m, c) in FILES.items()}
        self.commits[MAIN] = {"sha": MAIN, "tree": {"sha": BASE_TREE}, "parents": []}

    @staticmethod
    def issue(number, created, labels=(), body="", author=intake.MAINTAINER_ID):
        return {
            "number": number,
            "created_at": created,
            "body": body,
            "user": {"id": author},
            "labels": [{"name": label} for label in labels],
        }

    @staticmethod
    def pull(number, ref, repo=REPO):
        head = {"ref": ref, "repo": {"full_name": repo}}
        return {"number": number, "state": "open", "head": head}

    def gate(self):
        self.log.append("gate")

    def writes(self):
        return [entry for entry in self.log if entry != "gate" and entry[0] != "GET"]

    def send(self, method, path, body):
        assert path.startswith(f"/repos/{REPO}/"), path
        path = path.removeprefix(f"/repos/{REPO}")
        self.log.append((method, path, body))
        for pattern, answer in self.override.items():
            if re.fullmatch(pattern, f"{method} {path}"):
                return answer(body) if callable(answer) else answer
        return self.get(path) if method == "GET" else self.write(method, path, body)

    def get(self, path):
        if match := re.fullmatch(r"/(pulls|issues)\?.*&per_page=100&page=(\d+)", path):
            items, start = getattr(self, match[1]), (int(match[2]) - 1) * 100
            return items[start : start + 100]
        if path.startswith("/labels/"):
            name = path.removeprefix("/labels/").replace("%3A", ":")
            if name not in self.labels:
                raise urllib.error.HTTPError(path, 404, "Not Found", {}, None)
            return {"name": name}
        if path.startswith("/git/ref/heads/"):
            return self.ref(path.removeprefix("/git/ref/heads/"))
        if path.startswith("/git/commits/"):
            return self.commits[path[-40:]]
        if path.startswith("/git/blobs/"):
            return {"encoding": "base64", "content": b64encode(self.blobs[path[-40:]]).decode()}
        if match := re.fullmatch(r"/git/trees/(\w{40})\?recursive=1", path):
            entries = [
                {"path": p, "mode": m, "sha": s, "type": "blob"}
                for p, (m, s) in self.trees[match[1]].items()
            ]
            return {"sha": match[1], "truncated": False, "tree": entries}
        if match := re.fullmatch(r"/issues/(\d+)", path):
            return next(i for i in self.issues if i["number"] == int(match[1]))
        raise AssertionError(path)

    def ref(self, name):
        return {"ref": f"refs/heads/{name}", "object": {"type": "commit", "sha": self.refs[name]}}

    def write(self, method, path, body):
        if path == "/git/trees":
            tree = dict(self.trees[body["base_tree"]])
            for entry in body["tree"]:
                if "content" in entry:
                    content = entry["content"].encode()
                    self.blobs[patch_file.blob_id(content)] = content
                    tree[entry["path"]] = (entry["mode"], patch_file.blob_id(content))
                else:
                    del tree[entry["path"]]
            sha = hashlib.sha1(repr(sorted(tree.items())).encode()).hexdigest()
            self.trees[sha] = tree
            return {"sha": sha}
        if path == "/git/commits":
            sha = hashlib.sha1(repr(body).encode()).hexdigest()
            parents = [{"sha": parent} for parent in body["parents"]]
            self.commits[sha] = {"sha": sha, "tree": {"sha": body["tree"]}, "parents": parents}
            return self.commits[sha]
        if path == "/git/refs":
            name = body["ref"].removeprefix("refs/heads/")
            self.refs[name] = body["sha"]
            return self.ref(name)
        if path == "/pulls":
            head = {"ref": body["head"], "sha": self.refs[body["head"]]}
            return {"number": 77, "head": head, "base": {"ref": body["base"]}}
        if path == "/issues":
            labels = [{"name": label} for label in body["labels"]]
            return {**body, "number": 88, "labels": labels}
        if path.endswith("/comments"):
            return {"id": 5}
        if method == "DELETE" and path.startswith("/git/refs/heads/"):
            del self.refs[path.removeprefix("/git/refs/heads/")]
            return None
        if re.fullmatch(r"/issues/\d+/labels(/ready-for-agent)?", path):
            return []
        raise AssertionError(path)


def refuse():
    raise gate.Refused("FACTORY_ENABLED is off")


class Case(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.branches = []
        self.verified = 0

    def verify(self):
        self.verified += 1

    def pull_request(self, patch=None, body=None, gate_check=None, verify=None):
        return publish.publish_pull_request(
            self.github.send,
            REPO,
            gate_check or self.github.gate,
            verify or self.verify,
            ticket=9,
            run_id=123,
            patch=edit() if patch is None else patch,
            text=text() if body is None else body,
            template=(ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8"),
            on_branch=self.branches.append,
        )

    def ticket(self, body=None, gate_check=None):
        return publish.publish_ticket(
            self.github.send,
            REPO,
            gate_check or self.github.gate,
            text=ticket_text() if body is None else body,
            now=NOW,
        )

    def assertRefused(self, code, operation, *arguments, kind=publish.Refused, **options):
        with self.assertRaises(publish.Refused) as caught:
            operation(*arguments, **options)
        self.assertEqual((str(caught.exception), type(caught.exception)), (code, kind))

    def assertNothingWritten(self):
        self.assertEqual(self.github.writes(), [])


class PullRequestTest(Case):
    def test_one_commit_on_current_main_becomes_a_pull_request(self):
        number, branch, commit = self.pull_request(edit() + new_file("docs/b.md"))
        self.assertEqual((number, branch), (77, "factory/ticket-9-123"))
        self.assertEqual(self.github.refs[branch], commit)
        made = self.github.commits[commit]
        self.assertEqual([p["sha"] for p in made["parents"]], [MAIN])
        tree = self.github.trees[made["tree"]["sha"]]
        self.assertEqual(self.github.blobs[tree["docs/a.md"][1]], b"two\n")
        self.assertEqual(self.github.blobs[tree["docs/b.md"][1]], b"text\n")
        self.assertEqual(set(tree), {*FILES, "docs/b.md"})
        self.assertEqual(self.branches[-1], None)
        self.assertEqual(self.verified, 1)
        sent = self.github.writes()[-1]
        self.assertEqual(sent[:2], ("POST", "/pulls"))
        self.assertEqual(sent[2]["base"], "main")
        # Nothing that could make it a draft, which would change its checks.
        self.assertEqual(set(sent[2]), {"title", "head", "base", "body"})

    def test_renames_deletions_and_executable_files_keep_their_modes(self):
        self.pull_request(rename("run.sh", "bin/run.sh"))
        tree = self.github.trees[self.github.writes()[1][2]["tree"]]
        self.assertEqual(tree["bin/run.sh"], ("100755", patch_file.blob_id(b"x\n")))
        self.assertNotIn("run.sh", tree)

    def test_the_gate_runs_immediately_before_every_write(self):
        self.pull_request()
        log = self.github.log
        for index, entry in enumerate(log):
            if entry != "gate" and entry[0] != "GET":
                self.assertEqual(log[index - 1], "gate")
        # Creating the branch and the pull request have lookups with a gate on each side.
        self.assertEqual(log.count("gate"), 6)

    def test_a_gate_that_refuses_stops_everything(self):
        self.assertRefused("gate-refused", self.pull_request, gate_check=refuse)
        self.assertRefused("gate-refused", self.ticket, gate_check=refuse)
        self.assertNothingWritten()

    def test_a_stop_in_flight(self):
        for allowed, writes in enumerate((0, 1, 2, 2, 3, 3)):
            self.setUp()
            calls = []

            def gate_check():
                calls.append(1)
                if len(calls) > allowed:
                    refuse()

            with self.subTest(allowed):
                self.assertRefused("gate-refused", self.pull_request, gate_check=gate_check)
                self.assertEqual(len(self.github.writes()), writes)
                # A branch that could not be removed either is reported.
                left = ["factory/ticket-9-123"] if writes == 3 else []
                self.assertEqual(self.branches, left)

    def test_body_follows_the_template(self):
        summary = "Line.\nClosing nothing\n- [ ] **Narrow or docs-only change:**"
        self.pull_request(body=text(summary=summary))
        body = self.github.writes()[-1][2]["body"]
        self.assertTrue(body.startswith("Closes #9\n"))
        self.assertIn("- [x] **Narrow or docs-only change:** the entire", body)
        self.assertIn("- [ ] **Cross-cutting change:**", body)
        self.assertIn(summary, body)

    def test_cross_cutting_rows_must_be_exactly_the_template_rows(self):
        template = (ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8")
        rows = dict.fromkeys(re.findall(r"^\| ([^|]+?) \| _", template, re.M), "done | N/A")
        self.assertEqual(len(rows), 13)
        self.pull_request(body=text(paths=rows))
        body = self.github.writes()[-1][2]["body"]
        self.assertIn("| Keyed paths | done \\| N/A |", body)
        self.assertNotIn("Impact/evidence", body)
        for bad in ({}, {**rows, "Extra": "x"}, {**rows, "Keyed paths": "a\nb"}, [], "x"):
            self.assertRefused("text-malformed", self.pull_request, body=text(paths=bad))

    def test_a_branch_is_removed_when_the_pull_request_fails(self):
        def fail(body):
            raise OSError("500")

        self.github.override["POST /pulls"] = fail
        self.assertRefused("write-failed", self.pull_request)
        self.assertEqual(set(self.github.refs), {"main"})
        self.assertEqual(self.branches, ["factory/ticket-9-123", None])

    def test_someone_elses_branch_is_not_removed(self):
        def fail(body):
            self.github.refs["factory/ticket-9-123"] = "c" * 40
            raise OSError("500")

        self.github.override["POST /pulls"] = fail
        self.assertRefused("write-failed", self.pull_request)
        self.assertIn("factory/ticket-9-123", self.github.refs)

    def test_a_branch_that_may_exist_is_reported(self):
        def fail(body):
            raise OSError("timeout")

        self.github.override["POST /git/refs"] = fail
        self.assertRefused("write-failed", self.pull_request)
        self.assertEqual(self.branches, ["factory/ticket-9-123"])

    def test_main_moving_refuses(self):
        def move(body):
            self.github.refs["main"] = "c" * 40
            return self.github.write("POST", "/git/commits", body)

        self.github.override["POST /git/commits"] = move
        self.assertRefused("main-moved", self.pull_request)
        self.assertEqual(set(self.github.refs), {"main"})

    def test_an_ineligible_ticket_refuses_before_the_branch(self):
        self.assertRefused("ticket-ineligible", self.pull_request, verify=refuse)
        self.assertEqual(set(self.github.refs), {"main"})

    def test_a_commit_or_tree_that_is_not_what_was_asked_for(self):
        def commit(tree, *parents):
            return {"sha": "c" * 40, "tree": {"sha": tree}, "parents": [{"sha": p} for p in parents]}

        for pattern, answer in (
            ("POST /git/commits", lambda body: commit(body["tree"], MAIN, "d" * 40)),
            ("POST /git/commits", lambda body: commit(body["tree"])),
            ("POST /git/commits", lambda body: commit(body["tree"], "d" * 40)),
            ("POST /git/commits", lambda body: commit(BASE_TREE, MAIN)),
            ("POST /git/trees", {"sha": BASE_TREE}),
        ):
            self.setUp()
            self.github.override[pattern] = answer
            with self.subTest(pattern):
                self.assertRefused("write-unexpected", self.pull_request)
                self.assertEqual(set(self.github.refs), {"main"})

    def test_a_tree_with_anything_else_in_it(self):
        def add(body):
            sha = self.github.write("POST", "/git/trees", body)["sha"]
            self.github.trees[sha][".github/workflows/x.yml"] = ("100644", "d" * 40)
            return {"sha": sha}

        self.github.override["POST /git/trees"] = add
        self.assertRefused("write-unexpected", self.pull_request)
        self.assertEqual(set(self.github.refs), {"main"})

    def test_incomplete_lookups(self):
        tree = {"sha": BASE_TREE, "tree": []}
        for pattern, answer in (
            (r"GET /git/trees/b+\?.*", {**tree, "truncated": True}),
            (r"GET /git/trees/b+\?.*", tree),
            (r"GET /git/trees/b+\?.*", {**tree, "sha": "c" * 40, "truncated": False}),
            (r"GET /git/blobs/.*", {"encoding": "base64", "content": "b25"}),
            (r"GET /git/blobs/.*", {"encoding": "none", "content": ""}),
            (r"GET /git/ref/heads/main", {"ref": "refs/heads/main-2", "object": {}}),
            (r"GET /git/commits/.*", {}),
            (r"GET /git/commits/.*", None),
            (r"GET /pulls.*", {"message": "Not Found"}),
            (r"GET /pulls.*", [{}]),
            (r"GET /pulls.*", [FakeGitHub.pull(1, "x")] * 101),
            (r"GET /pulls.*page=[12]", [FakeGitHub.pull(1, "x")] * 99),
        ):
            self.setUp()
            self.github.override[pattern] = answer
            with self.subTest(pattern, answer=str(answer)[:60]):
                self.assertRefused("lookup-failed", self.pull_request)
                self.assertNothingWritten()

    def test_three_open_factory_pull_requests(self):
        two = [FakeGitHub.pull(n, f"factory/ticket-{n}-1") for n in (1, 2)]
        others = [FakeGitHub.pull(3, "factory/ticket-3-1", "fork/repo"), FakeGitHub.pull(4, "fix")]
        self.github.pulls = two + others
        self.pull_request()
        for ref in ("factory/ticket-5-1", "Factory/x", "factory/revert-5"):
            self.setUp()
            self.github.pulls = [*two, FakeGitHub.pull(5, ref)]
            self.assertRefused("open-pull-request-limit", self.pull_request)
            self.assertNothingWritten()

    def test_factory_pull_requests_on_later_pages_count(self):
        self.github.pulls = [FakeGitHub.pull(n, "fix") for n in range(1, 101)]
        self.github.pulls += [FakeGitHub.pull(200 + n, f"factory/{n}") for n in range(3)]
        self.assertRefused("open-pull-request-limit", self.pull_request)

    def test_one_open_pull_request_for_a_ticket(self):
        self.github.pulls = [FakeGitHub.pull(5, "factory/ticket-9-4")]
        self.assertRefused("ticket-already-published", self.pull_request)
        self.github.pulls = [FakeGitHub.pull(5, "factory/ticket-99-4")]
        self.pull_request()


class PatchRejectionTest(Case):
    def check(self, code, patch, kind=publish.Refused):
        self.assertRefused(code, self.pull_request, patch, kind=kind)
        self.assertNothingWritten()

    def test_each_rejection(self):
        for code, patch in (
            ("patch-file-mode", new_file(mode="120000")),
            ("patch-file-mode", new_file(mode="160000")),
            ("patch-file-mode", edit("LICENSE-link", b"LICENSE\n", b"x\n")),
            ("patch-binary", new_file(lines=("a\0",))),
            ("patch-workflow", new_file(".GitHub/Workflows/x.yml")),
            ("patch-workflow", rename(".github/workflows/x.yml", "x")),
            ("patch-path", new_file("../x")),
            ("patch-mode-change", b"diff --git a/run.sh b/run.sh\nold mode 100755\nnew mode 100644\n"),
            ("patch-malformed", b"rm -rf /\n"),
            ("patch-empty", b""),
            ("patch-truncated", new_file()[:-1]),
            ("patch-stale", edit(old=b"zero\n")),
            ("patch-stale", edit("missing")),
            ("patch-path-collision", new_file("Docs/b.md")),
        ):
            with self.subTest(code, patch=patch[:60]):
                self.check(code, patch)

    def test_secrets_in_lines_paths_and_across_files(self):
        self.check("secret-like", new_file(lines=("ok", f"t = {TOKEN}")))
        self.check("secret-like", new_file(lines=(b64encode(TOKEN.encode()).decode(),)))
        self.check("secret-like", new_file(f"docs/{TOKEN}"))
        self.check("secret-like", new_file("x1", (TOKEN[:9],)) + new_file("x2", (TOKEN[9:],)))
        body = text(title=f"x {TOKEN[:9]}", summary=TOKEN[9:])
        self.assertRefused("secret-like", self.pull_request, body=body)
        aws = "AK" + "IAIOSFODNN7EXAMPLQ"
        self.assertRefused(
            "secret-like",
            self.pull_request,
            new_file(lines=(aws[10:],)),
            text(summary=f"x {aws[:10]}"),
        )
        self.assertNothingWritten()

    def test_only_a_lock_file_hash_is_exempt(self):
        nar = '"narHash": "sha256-' + "l0KFg5HjrsfsO/JpG+r7" + "fRrqm12kzFHyUHqHCVpMMbI" + '=",'
        rev = '"rev": "' + "1b61536aa59821c49713" + "d6d0f8de7d687e197cc8" + '",'
        publish._parse_patch(new_file("flake.lock", (nar, rev)))
        self.check("secret-like", new_file("x.lock", (rev,)))
        self.check("secret-like", new_file("docs/flake.lock", (nar,)))
        self.check("secret-like", new_file("flake.lock", (nar + " " + TOKEN,)))

    def test_size_boundary(self):
        def lines(count):
            return tuple(f"line {n}" for n in range(count))

        self.pull_request(new_file("big", lines(800)))
        self.setUp()
        for patch in (
            new_file("big", lines(801)),
            new_file("x1", lines(400)) + new_file("x2", lines(401)),
        ):
            self.check("too-many-changed-lines", patch, kind=publish.TooLarge)
        (generated,) = patch_file.GENERATED
        self.pull_request(new_file(generated, lines(5000)) + new_file("x3", lines(800)))


class TextRejectionTest(Case):
    def test_malformed(self):
        for body in (
            b"",
            b"null",
            b"[]",
            b"{",
            b"\xff",
            b"NaN",
            b"[" * 100_000,
            text()[:-1],
            text(extra=1),
            text(title=1),
            text(title=" "),
            text(title="a\nb"),
            text(title="x" * 121),
            text(summary=""),
            text(summary=None),
            text(summary="x" * 20_001),
            text().replace(b"{", b'{"title":"a",', 1),
            b'{"title":"x","summary":Infinity,"paths":null}',
        ):
            with self.subTest(body[:40]):
                self.assertRefused("text-malformed", self.pull_request, body=body)
        self.assertRefused("text-too-long", self.pull_request, body=b" " * 200_001)
        self.assertNothingWritten()

    def test_content(self):
        for code, values in {
            "text-hidden-characters": ("a\u202eb", "a\u200bb", "a\x00b", "a\ud800b", "a\rb"),
            "text-hidden-markup": (
                "<!-- x",
                "\uff1c!-- x",
                "<?x",
                "<![CDATA[",
                "factory-ticket:v1",
                "Factory-Ticket:v1",
                "factory-comment:v1",
            ),
            "text-skips-ci": (
                "[skip ci]",
                "[CI Skip]",
                "x [no ci]",
                "[ skip  actions ]",
                "[actions skip]",
                "skip-checks: true",
                "\uff3bskip ci\uff3d",
                "[ci\u2010skip]",
                "[skip_ci]",
            ),
            "text-closes-issue": (
                "Closes #5",
                "fixed: #5",
                "RESOLVES o/r#5",
                "fix \uff035",
                "closes https://github.com/o/r/issues/5",
                "close GH-5",
                "Fixes **#5**",
                "_Fixes #5_",
                "__fixes #5__",
                "x_fixes #5",
                "Fixes" + " " * 11 + "#5",
                "Fixes" + "\n " * 90 + "#5",
                "Fixes" + " " * 900 + "#5",
                "Fixes (#5)",
                "Fixe**s** #5",
                "Closes #\u0665",
                "closes [#5](https://e.example)",
                "Closes # 5",
                "fixes _o/r#5_",
                "Fix:\u3000#5",
            ),
            "text-mention": (
                "hi @someone",
                "\uff20someone",
                "\u00aa@someone",
                "\\`@someone\\`",
                "\\@someone",
                "`@someone",
                "``@someone``",
                "`a\n`@user`b`",
                "`a`@someone",
                "@`someone`",
                "\\`a` `@someone`",
                "`a\\` `@someone`",
                "a` | `b` | `@someone` ` c",
                "` | ` `@someone`",
                "$`$ a` `@someone` `b`",
                "$a\n` ` `@someone` $",
                "_@someone_",
                ".@someone",
                "a\u2026@someone",
                "a/@someone",
                "a-@someone",
                "é@someone",
                ":+1:@someone",
                "xs@(x:_)",
            ),
            "text-entity": ("&#64;user", "&commat;user", "&lt;!-- x", "&#x40;user", "`a` &amp;"),
            "text-html": (
                "<b>x</b>",
                "<details>",
                "</p>",
                "<div hidden>x</div>",
                "<img src=x>",
                "\uff1cb>",
                "<https://example.com>",
                "`a` <b>",
                "<a title=`x`>",
            ),
            "text-link": (
                "![x](https://e.example/x.png)",
                "![x][y]",
                "[x](javascript:a)",
                "[x]( javascript:a)",
                "[x](JAVASCRIPT:a)",
                "[x](java\tscript:a)",
                "[x](http://e.example)",
                "[x](//e.example)",
                "[x](/relative)",
                "[x](../up)",
                "[x](a:b)",
                "[x](docs/a.md \"hidden\")",
                '[x](https://e.example "hidden")',
                "a javascript:b",
                "\n\n[a]: # (hidden)",
                "\n\n[^1]: note",
                "\n\n> [a]: https://e.example",
                "[x\n]: y",
            ),
            "text-fence": (
                "``` @x",
                "```\n@user\n```",
                "\n\n~~~\n```\n~~~\n@user\n```",
                "\n\n    ```\n\n@user\n\n```",
                "\n\n```\n@user",
                "\n\n````\n@user\n````",
                "\n\n```mermaid\nx\n```",
                "\n\n- ```\n@user\n  ```",
                "\n\n```\na\n``` \n@user",
                "\n\n ```\n@user\n ```",
                "\n\n```math\n@user\n```",
            ),
            "secret-like": (TOKEN, b64encode(TOKEN.encode()).decode()),
        }.items():
            for value in values:
                value = f"x {value}"
                with self.subTest(value):
                    self.assertRefused(code, self.pull_request, body=text(summary=value))
                    line = not re.search("[\n\t]", value) and len(value) <= 120
                    title = code if line else "text-malformed"
                    self.assertRefused(title, self.pull_request, body=text(title=value))
                    self.assertRefused(code, self.ticket, ticket_text(body=value))
                    self.assertRefused(title, self.ticket, ticket_text(title=value))
                    self.assertRefused(code, self.comment, value)
        self.assertNothingWritten()

    def comment(self, value):
        body = json.dumps({"body": value}).encode()
        publish.publish_comment(self.github.send, REPO, self.github.gate, number=1, text=body)

    def test_shell_and_workflow_syntax_is_only_data(self):
        value = "$(touch /tmp/x) `id` ${{ secrets.X }} %s {0} \\1 ::set-output name=a::b"
        self.pull_request(body=text(title=value, summary=value))
        self.assertIn(value, self.github.writes()[-1][2]["body"])

    def test_ordinary_haskell_and_markdown(self):
        for value in (
            "Use `fromIntegral @Word8 x`.",
            "`go xs@(x:_) = x` and `</>` and `Maybe<a>` and `&lt;` and `arr[i](x)`",
            "`f $ g`, then plain",
            "a < b && b > c, AT&T; R&D; `&mut`",
            "version @ 0.1, a@b.c, git@github.com:o/r",
            "[x](https://e.example/y) and [guide](docs/guide.md#part)",
            "Run:\n```haskell\nf @Int <x> ![1] xs[0](y) &amp;\n```\nDone",
            "```bash\ncabal test\n```",
            "This fix follows #12. Errors are fixed. #12 tracks docs.",
            "the factory ticket: x",
            "javascript: no, data: [], data:text",
            f"See commit {MAIN}.",
        ):
            with self.subTest(value):
                self.setUp()
                self.pull_request(body=text(summary=value))
                self.ticket(ticket_text(body=value))

    def test_only_commits_of_this_repository_may_be_written_in_full(self):
        unknown = "3f9a1c77e0b24d58" + "3f9a1c77e0b24d583f9a1c77"
        self.github.commits[unknown.replace("3", "4")] = {"sha": "other"}
        for value in (unknown, unknown.replace("3", "4"), MAIN.upper(), MAIN + "a", "0x" + unknown):
            if len(set(value)) < 6:
                continue
            with self.subTest(value):
                self.assertRefused("secret-like", self.pull_request, body=text(summary=f"see {value}"))
        known = unknown.replace("3", "5")
        self.github.commits[known] = {"sha": known}
        self.pull_request(new_file("docs/n.md", (f"pin {known}",)), text(summary=f"see {known}"))

    def test_commit_lookups_are_bounded(self):
        for number in range(11):
            sha = hashlib.sha1(b"%d" % number).hexdigest()
            self.github.commits[sha] = {"sha": sha}
        shas = [sha for sha in self.github.commits if sha != MAIN]
        self.pull_request(body=text(summary=" ".join(shas[:10])))
        self.setUp()
        self.github.commits.update({sha: {"sha": sha} for sha in shas})
        self.assertRefused("secret-like", self.pull_request, body=text(summary=" ".join(shas)))

    def test_the_written_rules_follow_themselves(self):
        rules = (ROOT / "scripts/factory/publish-text-rules.md").read_text(encoding="utf-8")
        publish._screen(rules)
        self.assertIn("```haskell", rules)

    def test_hostile_text_is_screened_quickly(self):
        for value in ("[_" * 19_000, "[" * 39_000, "[" + "_" * 39_000, "fix " * 9_000, "fix" + " " * 39_000,
                      "`a" * 19_000, "`" * 39_000, "$" * 39_000, "](" * 19_000, "a@" * 19_000,
                      "fixes " + "a." * 19_000, "&a" * 15_000, "\n\n" * 15_000, "![" * 19_000,
                      "```\n" * 9_000, "factory-" * 4_000, "eyJ" * 12_000, "a://" * 9_000):  # fmt: skip
            started = time.monotonic()
            with contextlib.suppress(publish.Refused):
                publish._screen(value)
            with self.subTest(value[:8]):
                self.assertLess(time.monotonic() - started, 5)


class TicketTest(Case):
    def test_filed_with_its_labels_in_one_request(self):
        self.assertEqual(self.ticket(), 88)
        (write,) = self.github.writes()
        self.assertEqual(write[:2], ("POST", "/issues"))
        self.assertEqual(
            set(write[2]["labels"]),
            {"factory-filed", "ready-for-agent", "type:testing", "priority:p2"},
        )
        self.assertTrue(write[2]["body"].startswith("<!-- factory-ticket:v1 kind=tests -->\n"))

    def test_triage_follows_intake(self):
        for fields in (
            {"kind": "releases"},
            {"kind": "bug-fix"},
            {"body": "Rotate credentials"},
            {"labels": ["type:security"]},
        ):
            self.setUp()
            self.ticket(ticket_text(**fields))
            self.assertIn("ready-for-human", self.github.writes()[0][2]["labels"])

    def test_forbidden_labels(self):
        for label in (
            "factory-approved",
            "Factory-Approved",
            "factory\u2010approved",
            "factory-paused",
            "factory-filed",
            "ready-for-agent",
            "ready-for-human",
            "needs-triage",
            "new",
            "type:security ",
            "",
            None,
            1,
            ["x"],
            {"name": "factory-approved"},
        ):
            with self.subTest(label):
                self.assertRefused("label-forbidden", self.ticket, ticket_text(labels=[label]))
        for labels in ("factory-approved", None, {}, ["priority:p0", "priority:p1"], ["type:bug"] * 2):
            with self.subTest(labels):
                self.assertRefused("text-malformed", self.ticket, ticket_text(labels=labels))
        self.assertRefused("text-malformed", self.ticket, ticket_text(kind="other"))
        self.assertRefused("text-malformed", self.ticket, ticket_text(kind=["tests"]))
        self.assertNothingWritten()

    def test_intake_decides(self):
        for answer in (
            {"side_effect": intake.Refused("no")},
            {"side_effect": TypeError()},
            {"return_value": False},
        ):
            with mock.patch.object(intake, "check_new_ticket_labels", **answer):
                self.assertRefused("label-forbidden", self.ticket)
        self.assertNothingWritten()

    def test_a_missing_label_would_be_created_so_it_refuses(self):
        self.github.labels.discard("factory-filed")
        self.assertRefused("lookup-failed", self.ticket)
        self.github.override["GET /labels/factory-filed"] = {"name": "Factory-Filed"}
        self.assertRefused("label-missing", self.ticket)
        self.assertNothingWritten()

    def test_an_unconfirmed_ticket_pauses(self):
        def drop(**changes):
            def answer(body):
                if body["labels"] == ["factory-paused"]:
                    return self.github.write("POST", "/issues", body)
                return {**self.github.write("POST", "/issues", body), **changes}

            return answer

        def lost(body):
            if body["labels"] == ["factory-paused"]:
                return self.github.write("POST", "/issues", body)
            raise OSError("timeout")

        real = [{"name": n} for n in ("factory-filed", "ready-for-agent", "type:testing", "priority:p2")]
        for answer in (
            drop(labels=[]),
            drop(labels=real[1:]),
            drop(labels=[*real, {"name": "factory-approved"}]),
            drop(body="Nothing covers it."),
            drop(body=None),
            drop(labels=None),
            drop(number="88"),
            lost,
        ):
            self.setUp()
            self.github.override["POST /issues"] = answer
            self.assertRefused("ticket-unverified-paused", self.ticket)
            created, paused = self.github.writes()
            self.assertIn("factory-filed", created[2]["labels"])
            self.assertTrue(created[2]["body"].startswith("<!-- factory-ticket:v1"))
            self.assertEqual(paused[2]["labels"], ["factory-paused"])

    def test_a_pause_that_also_fails_is_reported(self):
        self.github.override["POST /issues"] = {}
        self.assertRefused("ticket-unverified-not-paused", self.ticket)

    def test_a_refusal_before_sending_does_not_pause(self):
        self.assertRefused("gate-refused", self.ticket, gate_check=refuse)
        self.assertNothingWritten()

    def test_no_ticket_without_the_marker(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate)
        for body in ("x", "", None, "x\n<!-- factory-ticket:v1 kind=tests -->", "<!-- factory-ticket:v1 kind= -->"):
            content = {"title": "x", "body": body, "labels": ["factory-filed", "ready-for-human"]}
            self.assertRefused("ticket-unmarked", github._create, "/issues", content)
        with mock.patch.object(intake, "render_factory_ticket", lambda kind, text: text):
            self.assertRefused("ticket-unmarked", self.ticket)
        self.assertNothingWritten()

    def filed(self, number, created=TODAY, **options):
        return FakeGitHub.issue(number, created, **{"labels": ["factory-filed"], **options})

    def test_three_a_pacific_day(self):
        self.github.issues += [
            self.filed(2),
            self.filed(3),
            self.filed(4, YESTERDAY),
            {**self.filed(6), "pull_request": {}},
            self.filed(7, labels=[]),
            self.filed(8, labels=[], body="factory-ticket:v1", author=3),
        ]
        self.ticket()
        for extra in (
            self.filed(9),
            self.filed(9, labels=["Factory-Filed"]),
            self.filed(9, labels=[], body="<!-- factory-ticket:v1 kind=x -->"),
            self.filed(9, "2026-11-25T05:00:00Z"),
        ):
            self.setUp()
            self.github.issues = [extra, self.filed(2), self.filed(3)]
            self.assertRefused("ticket-limit", self.ticket)
            self.assertNothingWritten()

    def test_incomplete_issue_lists(self):
        for answer in (
            [],
            {"message": "x"},
            [{}],
            None,
            [FakeGitHub.issue(1, TODAY)] * 50,
            [FakeGitHub.issue(1, "soon")],
            [FakeGitHub.issue(1, YESTERDAY)] * 100,  # Never ends.
        ):
            self.github.override["GET /issues.*"] = answer
            with self.subTest(str(answer)[:40]):
                self.assertRefused("lookup-failed", self.ticket)
        self.assertNothingWritten()

    def test_later_pages_count(self):
        self.github.issues = [FakeGitHub.issue(n, TODAY) for n in range(1000, 1100)]
        self.github.issues += [self.filed(n) for n in range(3)]
        self.assertRefused("ticket-limit", self.ticket)


class CommentAndRouteTest(Case):
    def comment(self, number=1):
        return publish.publish_comment(
            self.github.send, REPO, self.github.gate, number=number, text=b'{"body": "It failed."}'
        )

    def test_comment_is_marked_and_gated(self):
        self.github.issues[0]["locked"] = False
        self.comment()
        (write,) = self.github.writes()
        self.assertEqual(write[2]["body"], intake.render_factory_comment("It failed."))
        self.assertEqual(self.github.log[-2], "gate")

    def test_comment_refusals(self):
        self.assertRefused("lookup-failed", self.comment)  # No locked field.
        self.github.issues[0]["locked"] = True
        self.assertRefused("comment-forbidden", self.comment)
        self.github.issues[0].update(locked=False, labels=[{"name": "Factory-Paused"}])
        self.assertRefused("comment-forbidden", self.comment)
        for number in (0, -1, "1", True, 10**9, "1/../../labels"):
            self.assertRefused("input-malformed", self.comment, number)
        self.assertNothingWritten()

    def route(self, gate_check=None, **fields):
        ticket = {**TICKET, **fields}
        return publish.publish_route(
            self.github.send,
            REPO,
            gate_check or self.github.gate,
            ticket=9,
            fetch=lambda: ticket,
        )

    def test_route_adds_before_removing(self):
        self.route()
        self.assertEqual(
            self.github.writes(),
            [
                ("POST", "/issues/9/labels", {"labels": ["ready-for-human"]}),
                ("DELETE", "/issues/9/labels/ready-for-agent", None),
            ],
        )
        self.assertEqual(self.github.log.count("gate"), 2)

    def test_route_refusals(self):
        for fields in (
            {"number": 8},
            {"is_pull_request": True},
            {"labels": []},
            {"labels": ["ready-for-agent", "needs-info"]},
            {"events": None},
        ):
            with self.subTest(fields):
                self.assertRefused("label-forbidden", self.route, **fields)
        with mock.patch.object(intake, "check_label_change", side_effect=intake.Refused("no")):
            self.assertRefused("label-forbidden", self.route)
        self.assertRefused("gate-refused", self.route, gate_check=refuse)
        self.assertNothingWritten()


class PauseTest(Case):
    def pause(self, reason="main-broken"):
        return publish.publish_pause(self.github.send, REPO, reason=reason)

    def test_opens_one_fixed_issue_without_the_gate(self):
        self.assertEqual(self.pause(), 88)
        (write,) = self.github.writes()
        self.assertEqual(write[:2], ("POST", "/issues"))
        self.assertEqual(write[2]["labels"], ["factory-paused"])
        self.assertEqual(set(write[2]), {"title", "body", "labels"})
        self.assertEqual(write[2]["title"], "Factory paused")
        self.assertNotIn("gate", self.github.log)

    def test_every_reason_is_a_whole_fixed_text(self):
        bodies = set()
        for reason in publish.PAUSE_REASONS:
            self.setUp()
            self.pause(reason)
            bodies.add(self.github.writes()[0][2]["body"])
        self.assertEqual(len(bodies), 4)
        for reason in ("other", "", None, "main-broken\n"):
            self.assertRefused("input-malformed", self.pause, reason)

    def test_it_takes_no_text(self):
        for option in ("--text", "--number", "--ticket", "--patch"):
            arguments = ["pause", "--reason", "main-broken", "--result", "x", option, "1"]
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                publish.main(arguments)

    def test_a_missing_label_is_not_created(self):
        self.github.labels.discard("factory-paused")
        self.assertRefused("label-missing", self.pause)
        self.github.override["GET /labels/.*"] = {"name": "other"}
        self.assertRefused("label-missing", self.pause)
        self.assertNothingWritten()

    def test_the_label_matches_as_the_gate_matches_it(self):
        self.github.override["GET /labels/.*"] = {"name": "Factory-Paused"}
        self.github.override["POST /issues"] = {"number": 8, "labels": [{"name": "Factory-Paused"}]}
        self.assertEqual(self.pause(), 8)

    def test_a_failed_label_lookup_does_not_prevent_a_pause(self):
        def fail(body):
            raise OSError("500")

        for answer in (fail, None, {}, []):
            self.setUp()
            self.github.override["GET /labels/.*"] = answer
            self.assertEqual(self.pause(), 88)

    def test_a_failed_request_is_tried_again_and_then_reported(self):
        def fail(body):
            if len(self.github.writes()) < 3:
                raise OSError("502")
            return self.github.write("POST", "/issues", body)

        self.github.override["POST /issues"] = fail
        self.assertEqual(self.pause(), 88)
        self.setUp()
        self.github.override["POST /issues"] = lambda body: (_ for _ in ()).throw(OSError("502"))
        self.assertRefused("write-failed", self.pause)
        self.assertEqual(len(self.github.writes()), 3)

    def test_a_pause_without_its_label_is_a_failure(self):
        self.github.override["POST /issues"] = {"number": 88, "labels": []}
        self.assertRefused("write-unexpected", self.pause)

    def test_any_other_write_from_a_pause_is_refused(self):
        github = publish._GitHub(self.github.send, REPO, publish._never_allowed)
        ticket = {
            "title": "x",
            "body": intake.render_factory_ticket("tests", "x"),
            "labels": ["factory-filed", "ready-for-human"],
        }
        for write in (
            lambda: github._create("/issues", ticket),
            lambda: github._comment(1, intake.render_factory_comment("x")),
            lambda: github._route_to_human(TICKET),
        ):
            self.assertRefused("gate-refused", write)
        close = ("PATCH", "/issues/1", {"state": "closed"})
        self.assertRefused("operation-forbidden", github._write, *close)
        self.assertNothingWritten()

    def test_no_gated_operation_can_open_a_pause(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate)
        content = publish._pause_content("main-broken")
        self.assertRefused("operation-forbidden", github._write, "POST", "/issues", content)
        for labels in (["factory-paused"], ["factory-paused", "factory-filed", "ready-for-human"]):
            body = {"title": "x", "body": "x", "labels": labels}
            self.assertRefused("label-forbidden", github._create, "/issues", body)
        self.assertNothingWritten()


class BoundaryTest(Case):
    def test_operations_that_do_not_exist(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate)
        sha = {"sha": "c" * 40}
        pull = {"title": "x", "head": "factory/ticket-1-1", "base": "main", "body": ""}
        commit = {"message": "x", "tree": "x", "parents": [MAIN]}
        for path, body in (
            ("/git/refs", {"ref": "refs/tags/factory/ticket-1-1", **sha}),
            ("/git/refs", {"ref": "refs/tags/v1", **sha}),
            ("/git/refs", {"ref": "refs/heads/main", **sha}),
            ("/git/refs", {"ref": "refs/heads/factory/ticket-1-1/../../main", **sha}),
            ("/git/refs", {"ref": "factory/ticket-1-1", **sha}),
            ("/git/refs", {"ref": "refs/heads/factory/ticket-1-1\n", **sha}),
            ("/git/refs", {"ref": "refs/heads/factory/ticket-1-1", "force": True, **sha}),
            ("/git/tags", {"tag": "v1"}),
            ("/releases", {"tag_name": "v1"}),
            ("/labels", {"name": "factory-approved"}),
            ("/issues/1/labels", {"labels": ["factory-approved"]}),
            ("/issues/1/transfer", {}),
            ("/actions/variables", {"name": "FACTORY_ENABLED", "value": "true"}),
            ("/actions/variables/FACTORY_ENABLED", {"value": "true"}),
            ("/environments/factory-resume", {}),
            ("/merges", {"base": "main", "head": "x"}),
            ("/pulls/1/merge", {}),
            ("/pulls", {**pull, "head": "main"}),
            ("/pulls", {**pull, "base": "other"}),
            ("/pulls", {**pull, "head": "fork:factory/ticket-1-1"}),
            ("/pulls", {**pull, "draft": True}),
            ("/git/commits", {**commit, "parents": [MAIN, MAIN]}),
            ("/git/commits", {**commit, "parents": []}),
        ):
            with self.subTest(path, body=body):
                self.assertRefused("operation-forbidden", github._create, path, body)
        for labels in (
            ["factory-approved", "factory-filed", "ready-for-human"],
            [],
            ["factory-filed"],
            ["ready-for-human"],
            ["factory-filed", "ready-for-agent", "ready-for-human"],
        ):
            body = {"title": "x", "body": "x", "labels": labels}
            self.assertRefused("label-forbidden", github._create, "/issues", body)
        self.assertRefused("operation-forbidden", github._delete_branch, "main", MAIN)
        self.assertNothingWritten()

    def test_source_names_no_other_operation(self):
        source = Path(publish.__file__).read_text(encoding="utf-8")
        code = source.split('"""', 2)[2]
        self.assertEqual(code.count("self._send("), 3)
        for word in (
            "subprocess",
            "os.system",
            "eval(",
            "exec(",
            "PATCH",
            "PUT",
            "/releases",
            "/tags",
            "/variables",
            "/environments",
            "/transfer",
            "factory-approved",
            "APPROVED_LABEL",
        ):
            self.assertNotIn(word, code)


class RaceTest(Case):
    def gate_then(self, number, action):
        """A gate that runs `action` during its numbered call."""
        calls = []

        def gate_check():
            calls.append(1)
            if len(calls) == number:
                action()

        return gate_check

    def test_main_moving_during_the_gate(self):
        for number in (3, 5):
            self.setUp()
            move = self.gate_then(number, lambda: self.github.refs.update(main="c" * 40))
            self.assertRefused("main-moved", self.pull_request, gate_check=move)
            self.assertEqual(set(self.github.refs), {"main"})
            self.assertNotIn("/pulls", [path for _, path, _ in self.github.writes()])

    def test_pull_requests_opening_during_the_gate(self):
        def open_three():
            self.github.pulls += [FakeGitHub.pull(n, f"factory/ticket-{n}-1") for n in (50, 51, 52)]

        for number in (3, 5):
            self.setUp()
            gate_check = self.gate_then(number, open_three)
            self.assertRefused("open-pull-request-limit", self.pull_request, gate_check=gate_check)
            self.assertEqual(set(self.github.refs), {"main"})

    def test_tickets_filed_during_the_gate(self):
        def file_three():
            self.github.issues += [FakeGitHub.issue(n, TODAY, ["factory-filed"]) for n in (5, 6, 7)]

        self.assertRefused("ticket-limit", self.ticket, gate_check=self.gate_then(1, file_three))
        self.assertNothingWritten()  # Nothing was sent, so nothing to pause for.

    def test_a_branch_moved_during_the_gate_is_not_deleted(self):
        def fail(body):
            raise OSError("500")

        self.github.override["POST /pulls"] = fail
        move = self.gate_then(7, lambda: self.github.refs.update({"factory/ticket-9-123": "e" * 40}))
        self.assertRefused("write-failed", self.pull_request, gate_check=move)
        self.assertEqual(self.github.refs["factory/ticket-9-123"], "e" * 40)
        self.assertEqual(self.branches, ["factory/ticket-9-123"])

    def test_a_stop_during_the_last_lookups(self):
        for pattern, answer, operation, gates, path in (
            ("GET /pulls.*", [], self.pull_request, 3, "/git/refs"),
            ("GET /issues.*page=2", [], self.ticket, 1, "/issues"),
        ):
            self.setUp()
            stopped = []

            def gate_check():
                self.github.log.append("gate")
                if stopped:
                    refuse()

            def stop(body):
                if self.github.log.count("gate") >= gates:
                    stopped.append(1)
                return answer

            self.github.override[pattern] = stop
            with self.subTest(pattern):
                self.assertRefused("gate-refused", operation, gate_check=gate_check)
                self.assertTrue(stopped)
                self.assertNotIn(path, [write[1] for write in self.github.writes()])

    def test_the_branch_is_read_last_before_deletion(self):
        def fail(body):
            raise OSError("500")

        self.github.override["POST /pulls"] = fail
        self.assertRefused("write-failed", self.pull_request)
        self.assertEqual(
            [entry if entry == "gate" else entry[:2] for entry in self.github.log[-4:]],
            ["gate", ("GET", "/git/ref/heads/factory/ticket-9-123"), "gate", ("DELETE", "/git/refs/heads/factory/ticket-9-123")],
        )


class AllowlistTest(Case):
    ROOT = f"/repos/{REPO}"

    def attempt(self, method, path, body=None, root=None):
        sent = []
        guard = publish._restricted(lambda *request: sent.append(request), REPO, lambda: None)
        try:
            guard(method, (self.ROOT if root is None else root) + path, body)
        except publish.Refused as error:
            self.assertEqual((str(error), sent), ("operation-forbidden", []))
            return False
        self.assertEqual(len(sent), 1)
        return True

    def test_refused_requests(self):
        ref = {"ref": "refs/heads/factory/ticket-1-1", "sha": "c" * 40}
        issue = {"title": "x", "body": "<!-- factory-ticket:v1 kind=tests -->\nx",
                 "labels": ["factory-filed", "ready-for-agent"]}  # fmt: skip
        pause = {"title": "Factory paused", "body": "other", "labels": ["factory-paused"]}
        tree = {"path": "x", "mode": "100644", "type": "blob", "content": "x"}
        pull = {"title": "x", "head": "factory/ticket-1-1", "base": "main", "body": "x"}
        commit = {"message": "x\n\nFor #1\n", "tree": "c" * 40, "parents": [MAIN]}
        for method, path, body in (
            ("PATCH", "/issues/1", {"state": "closed"}),
            ("PUT", "/pulls/1/merge", {}),
            ("post", "/issues", issue),
            ("POST", "/issues/", issue),
            ("POST", "/issues?x=1", issue),
            ("POST", "/pulls/../issues", issue),
            ("POST", "/issues\n", issue),
            ("POST", "/issues/1/labels", {"labels": ["factory-approved"]}),
            ("POST", "/issues/1/labels", {"labels": ["ready-for-human", "factory-paused"]}),
            ("POST", "/issues/0/comments", {"body": intake.render_factory_comment("x")}),
            ("POST", "/issues/1/comments", {"body": "unmarked"}),
            ("POST", "/issues/1/comments", {"body": intake.render_factory_comment("_@user_")}),
            ("POST", "/issues", {**issue, "labels": ["factory-filed", "ready-for-agent", "factory-approved"]}),
            ("POST", "/issues", {**issue, "labels": ["factory-filed", "ready-for-agent", "ready-for-agent"]}),
            ("POST", "/issues", {**issue, "labels": "factory-filed"}),
            ("POST", "/issues", {**issue, "assignees": ["x"]}),
            ("POST", "/issues", {**issue, "body": "x"}),
            ("POST", "/issues", pause),
            ("POST", "/issues", {**pause, "labels": ["factory-paused", "factory-approved"]}),
            ("POST", "/git/refs", {**ref, "ref": "refs/tags/v1"}),
            ("POST", "/git/refs", {**ref, "ref": "refs/heads/main"}),
            ("POST", "/git/refs", {**ref, "sha": "main"}),
            ("POST", "/git/tags", {}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": [{**tree, "path": ".github/workflows/x"}]}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": [{**tree, "path": "../x"}]}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": [{**tree, "mode": "120000"}]}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": [{**tree, "type": "commit"}]}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": [{**tree, "sha": "c" * 40}]}),
            ("POST", "/git/trees", {"base_tree": BASE_TREE, "tree": []}),
            ("POST", "/git/trees", {"tree": [tree]}),
            ("POST", "/git/commits", {**commit, "parents": [MAIN, MAIN]}),
            ("POST", "/git/commits", {**commit, "author": {}}),
            ("POST", "/pulls", {**pull, "head": "main"}),
            ("DELETE", "/git/refs/heads/main", None),
            ("DELETE", "/git/refs/tags/v1", None),
            ("DELETE", "/git/refs/heads/factory/ticket-1-1/../../main", None),
            ("DELETE", "/git/refs/heads/factory/ticket-1-1", {"x": 1}),
            ("DELETE", "/issues/1/labels/factory-paused", None),
            ("DELETE", "/issues/1/labels/factory-approved", None),
            ("DELETE", "/issues/1/labels", None),
            ("DELETE", "/issues/1", None),
            ("GET", "/../../user", None),
            ("GET", "/actions/secrets", None),
            ("GET", "/issues/../../../../user", None),
            ("GET", "/issues", {"x": 1}),
            ("GET", "/issues/1/%2e%2e/x", None),
        ):
            with self.subTest(method=method, path=path, body=body):
                self.assertFalse(self.attempt(method, path, body))
        for method, root, path, body in (
            ("POST", "/repos/other/repo", "/issues", issue),
            ("POST", "", "/user/repos", {}),
            ("GET", "https://e.example", "/issues", None),
            ("POST", "", "/graphql", {"query": "mutation{x}", "variables": {}}),
            ("POST", "", "/graphql", {"query": publish.intake_github.QUERY, "variables": {}, "operationName": "x"}),
        ):
            with self.subTest(root=root, path=path):
                self.assertFalse(self.attempt(method, path, body, root))

    def test_permitted_requests(self):
        for method, path, body in (
            ("GET", "/issues?state=all&sort=created&direction=desc&per_page=100&page=1", None),
            ("GET", "/issues/9/timeline?per_page=100&page=1", None),
            ("GET", "/labels/type%3Abug", None),
            ("POST", "/issues/9/labels", {"labels": ["ready-for-human"]}),
            ("DELETE", "/issues/9/labels/ready-for-agent", None),
        ):
            with self.subTest(method=method, path=path):
                self.assertTrue(self.attempt(method, path, body))
        query = {"query": publish.intake_github.QUERY, "variables": {"owner": "owner", "name": "repo", "number": 1}}
        self.assertTrue(self.attempt("POST", "/graphql", query, ""))
        self.assertFalse(self.attempt("POST", "/graphql", {**query, "query": "mutation{x}"}, ""))
        query["variables"]["name"] = "other"
        self.assertFalse(self.attempt("POST", "/graphql", query, ""))

    def test_the_real_transport_is_restricted(self):
        send = publish._transport("github" + "_pat_x", REPO, refuse)
        with mock.patch.object(publish.github_http.urllib.request.OpenerDirector, "open") as opened:
            with self.assertRaises(publish.Refused):
                send("PATCH", f"{self.ROOT}/issues/1", {"state": "closed"})
        opened.assert_not_called()

    def test_only_this_runs_branch(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate, branch="factory/ticket-9-123")
        self.github.refs["factory/ticket-2-2"] = "f" * 40
        other = {"ref": "refs/heads/factory/ticket-2-2", "sha": "f" * 40}
        self.assertRefused("operation-forbidden", github._create, "/git/refs", other)
        self.assertRefused("operation-forbidden", github._delete_branch, "factory/ticket-2-2", "f" * 40)
        # Nor with a commit this run did not make.
        own = {"ref": "refs/heads/factory/ticket-9-123", "sha": "f" * 40}
        self.assertRefused("operation-forbidden", github._create, "/git/refs", own)
        self.assertNothingWritten()

    def test_every_sender_is_gated(self):
        requests = (
            ("POST", "/issues/9/labels", {"labels": ["ready-for-human"]}),
            ("DELETE", "/issues/9/labels/ready-for-agent", None),
            ("POST", "/issues/9/comments", {"body": intake.render_factory_comment("x")}),
        )
        sent = []
        guard = publish._restricted(lambda *request: sent.append(request), REPO, refuse)
        github = publish._GitHub(self.github.send, REPO, refuse)
        for method, path, body in requests:
            with self.subTest(path):
                self.assertRefused("gate-refused", guard, method, self.ROOT + path, body)
                self.assertRefused("gate-refused", github._send, method, self.ROOT + path, body)
                self.assertRefused("gate-refused", github._write, method, path, body)
        self.assertEqual(sent, [])
        self.assertNothingWritten()

    def test_one_gate_for_each_write(self):
        guard = publish._restricted(self.github.send, REPO, self.github.gate)
        publish._GitHub(guard, REPO, self.github.gate)._comment(1, intake.render_factory_comment("x"))
        self.assertEqual(self.github.log.count("gate"), 1)

    def test_direct_writes_check_ownership_and_text(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate, branch="factory/ticket-9-123")
        pull = {"title": "x", "head": "factory/ticket-9-123", "base": "main", "body": "Closes #9\n\nx"}
        commit = {"message": "x\n\nFor #9\n", "tree": "c" * 40, "parents": [MAIN]}
        issue = {"title": "x", "body": intake.render_factory_ticket("tests", "x"),
                 "labels": ["factory-filed", "ready-for-agent"]}  # fmt: skip
        for path, body in (
            ("/git/refs", {"ref": "refs/heads/factory/ticket-9-123", "sha": "c" * 40}),
            ("/pulls", pull),
            ("/pulls", {**pull, "title": "@x"}),
            ("/pulls", {**pull, "body": "Closes #9\n\nfixes #5"}),
            ("/pulls", {**pull, "body": "x"}),
            ("/git/commits", {**commit, "message": "fixes #5\n\nFor #9\n"}),
            ("/git/commits", {**commit, "message": "x [skip ci]\n\nFor #9\n"}),
            ("/git/commits", {**commit, "message": "x"}),
            ("/git/commits", {**commit, "message": "x\n\nCloses #5\n\nFor #9\n"}),
            ("/issues", {**issue, "title": "@x"}),
            ("/issues", {**issue, "body": issue["body"] + " @x"}),
            ("/issues", {**issue, "title": TOKEN}),
        ):
            with self.subTest(path, body=body):
                self.assertRefused("operation-forbidden", github._write, "POST", path, body)
        other = "/git/refs/heads/factory/ticket-7-7"
        self.assertRefused("operation-forbidden", github._write, "DELETE", other, None)
        self.assertNothingWritten()

    def test_routing_checks_the_ticket_itself(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate)
        for changes in ({"labels": []}, {"is_pull_request": True}, {"number": "9"}):
            self.assertRefused("label-forbidden", github._route_to_human, {**TICKET, **changes})
        self.assertNothingWritten()

    def test_low_level_helpers_check_themselves(self):
        github = publish._GitHub(self.github.send, REPO, self.github.gate)
        self.assertRefused("operation-forbidden", github._comment, 1, "raw @x")
        self.assertRefused("operation-forbidden", github._write, "PATCH", "/issues/1", {})
        self.assertNothingWritten()


class ControlFileTest(unittest.TestCase):
    def test_permitted_control_files_wait_for_the_maintainer(self):
        for path in (
            ".gitattributes",
            "docs/.gitattributes",
            ".gitconfig",
            ".github/CODEOWNERS",
            "CODEOWNERS",
            "docs/CODEOWNERS",
            ".github/dependabot.yml",
            ".claude/settings.json",
            "app/.claude/x.hs",
            ".mcp.json",
            "AGENTS.md",
            "test/AGENTS.md",
            "Makefile",
            "cabal.project",
            "flake.nix",
            "renovate.json",
            ".envrc",
        ):
            with self.subTest(path):
                patch_file.check_path(path)
                self.assertEqual(classify.classify_path(path)[0], classify.MAINTAINER)


class CommandTest(unittest.TestCase):
    ENVIRONMENT = {
        "GITHUB_REPOSITORY": REPO,
        "GITHUB_RUN_ID": "123",
        "FACTORY_PUBLISH_TOKEN": "github" + "_pat_x",
    }
    PULL_REQUEST = (
        "pull-request", "--ticket", "9", "--work-digest", "a" * 64, "--patch", "DIR/agent.patch",
        "--text", "DIR/output.json", "--assessments", "DIR/assessments.json",
    )  # fmt: skip

    def run_main(self, arguments, send, environment=None, gate_refuses=False):
        self.kinds = []

        def require(kind):
            self.kinds.append(kind)
            if gate_refuses:
                refuse()

        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory, "result.json")
            for name, content in {
                "agent.patch": edit(),
                "output.json": text(),
                "ticket.json": ticket_text(),
                "assessments.json": b'[{"ticket": 9, "source_digest": "d", "output": "o"}]',
            }.items():
                Path(directory, name).write_bytes(content)
            Path(directory, "link.json").symlink_to(Path(directory, "ticket.json"))
            os.mkfifo(Path(directory, "pipe.json"))
            arguments = [a.replace("DIR", directory) for a in arguments]
            output = io.StringIO()
            with (
                mock.patch.dict(os.environ, environment or self.ENVIRONMENT, clear=True),
                mock.patch.object(publish, "_transport", lambda token, repository, gate_check: send),
                mock.patch.object(gate, "require", require),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(output),
            ):
                status = publish.main([*arguments, "--result", str(result)])
            return status, json.loads(result.read_text()), output.getvalue()

    def test_pull_request_checks_the_ticket_with_intake(self):
        with (
            mock.patch.object(publish.intake_github, "fetch_ticket", return_value="fresh"),
            mock.patch.object(intake, "verify") as verify,
        ):
            status, result, _ = self.run_main(self.PULL_REQUEST, FakeGitHub().send)
        self.assertEqual((status, result["outcome"], result["number"]), (0, "published", 77))
        self.assertIsNone(result["branch_left"])
        assessment = {"ticket": 9, "source_digest": "d", "output": "o"}
        verify.assert_called_once_with("fresh", assessment, "a" * 64)
        self.assertEqual(set(self.kinds), {"publish"})

    def test_intake_refusal(self):
        with (
            mock.patch.object(publish.intake_github, "fetch_ticket", return_value="fresh"),
            mock.patch.object(intake, "verify", side_effect=intake.Refused("changed")),
        ):
            status, result, _ = self.run_main(self.PULL_REQUEST, FakeGitHub().send)
        self.assertEqual((status, result["code"]), (1, "ticket-ineligible"))
        for index, value, code in (
            (4, "A" * 64, "input-malformed"),
            (2, "8", "assessment-malformed"),
            (10, "DIR/agent.patch", "assessment-malformed"),
        ):
            changed = list(self.PULL_REQUEST)
            changed[index] = value
            status, result, _ = self.run_main(changed, FakeGitHub().send)
            self.assertEqual((status, result["code"]), (1, code))

    def test_links_pipes_and_missing_files(self):
        for name in ("link.json", "pipe.json", "none.json", ""):
            with self.subTest(name):
                arguments = ["ticket", "--text", f"DIR/{name}"]
                status, result, _ = self.run_main(arguments, FakeGitHub().send)
                self.assertEqual((status, result["code"]), (1, "input-missing"))

    def test_tokens_that_would_not_trigger_tests(self):
        for token in ("gh" + "s_" + "x" * 20, "gh" + "p_" + "x" * 20, "", "github" + "_pat_x\n"):
            environment = {**self.ENVIRONMENT, "FACTORY_PUBLISH_TOKEN": token}
            arguments = ["ticket", "--text", "DIR/ticket.json"]
            status, result, _ = self.run_main(arguments, None, environment)
            self.assertEqual((status, result["code"]), (1, "environment-malformed"))

    def test_split_has_its_own_status(self):
        error = publish.TooLarge("too-many-changed-lines")
        with mock.patch.object(publish, "_run", side_effect=error):
            status, result, _ = self.run_main(["route", "--ticket", "1"], None)
        self.assertEqual((status, result["outcome"]), (3, "split"))

    def test_output_never_holds_agent_text(self):
        with mock.patch.object(publish, "_run", side_effect=RuntimeError("::add-mask::evil")):
            status, result, output = self.run_main(["route", "--ticket", "1"], None)
        self.assertEqual(status, 1)
        self.assertNotIn("evil", output + json.dumps(result))

    def test_the_result_says_whether_a_pause_is_missing(self):
        for code, pause in (
            ("ticket-unverified-paused", "done"),
            ("ticket-unverified-not-paused", "failed"),
            ("ticket-limit", "unneeded"),
            ("gate-refused", "unneeded"),
        ):
            with mock.patch.object(publish, "_run", side_effect=publish.Refused(code)):
                _, result, _ = self.run_main(["ticket", "--text", "DIR/ticket.json"], None)
            self.assertEqual(result["pause"], pause)
        with mock.patch.object(publish, "_run", side_effect=RuntimeError()):
            _, result, _ = self.run_main(["ticket", "--text", "DIR/ticket.json"], None)
        self.assertEqual(result["pause"], "failed")
        _, result, _ = self.run_main(["ticket", "--text", "DIR/ticket.json"], FakeGitHub().send)
        self.assertEqual((result["outcome"], result["pause"]), ("published", "unneeded"))

    def test_only_pause_works_while_the_gate_refuses(self):
        arguments = ["pause", "--reason", "main-broken"]
        status, result, _ = self.run_main(arguments, FakeGitHub().send, gate_refuses=True)
        self.assertEqual((status, result["number"], self.kinds), (0, 88, []))
        arguments = ["ticket", "--text", "DIR/ticket.json"]
        status, result, _ = self.run_main(arguments, FakeGitHub().send, gate_refuses=True)
        self.assertEqual((status, result["code"]), (1, "gate-refused"))

    def test_the_transport_cannot_follow_redirects(self):
        send = publish._transport("github" + "_pat_x", REPO, refuse)
        answer = contextlib.nullcontext(io.StringIO('{"name": "x"}'))
        with mock.patch.object(publish.github_http, "open_api", return_value=answer) as opened:
            self.assertEqual(send("GET", f"/repos/{REPO}/labels/x", None), {"name": "x"})
        opened.assert_called_once()


class WorkflowTest(unittest.TestCase):
    def read(self, name):
        return (WORKFLOWS / name).read_text(encoding="utf-8")

    def test_inputs_are_never_interpolated_into_scripts(self):
        for name in ("factory-publish.yml", "factory-pause.yml"):
            workflow = self.read(name)
            scripts = re.findall(r"run: (?:[|>]\n((?:          .*\n|\n)+)|(.*))", workflow)
            self.assertTrue(scripts)
            for script in scripts:
                self.assertNotIn("${{", "".join(script))
            for setting in ("ref: main", "persist-credentials: false", "permissions: {}"):
                self.assertIn(setting, workflow)

    def test_the_token_is_used_by_these_workflows_only(self):
        users = {p.name for p in WORKFLOWS.iterdir() if "FACTORY_PUBLISH_TOKEN" in self.read(p.name)}
        self.assertEqual(users, {"factory-publish.yml", "factory-pause.yml"})

    def test_only_the_pause_workflow_lacks_the_gate(self):
        self.assertIn("gate.py publish", self.read("factory-publish.yml"))
        self.assertNotIn("publish.py pause", self.read("factory-publish.yml"))
        self.assertEqual(re.findall(r"publish\.py (\S+)", self.read("factory-pause.yml")), ["pause"])

    def test_an_ungated_job_verifies_the_environment_before_publishing(self):
        workflow = self.read("factory-publish.yml")
        verify, secret = workflow.split("\njobs:\n")[1].split("\n  publish:\n")
        self.assertIn("scripts/check-release-environment.py", verify)
        self.assertIn("--name factory-publish --no-reviewer", verify)
        self.assertIn("environments/factory-publish", verify)
        self.assertNotIn("\n    environment:", verify)
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("always()", verify)
        self.assertIn("    needs: verify\n", secret)
        condition = re.search(r"\n    if: (.*)", secret)[1]
        self.assertEqual(condition, "github.ref == 'refs/heads/main'")
        self.assertIn("    environment: factory-publish\n", secret)

    def test_nothing_can_skip_a_pause(self):
        workflow = self.read("factory-pause.yml")
        jobs = re.sub(r"(?m)^ *#.*\n", "", workflow.split("\njobs:\n")[1])
        # gate.py finds the job by this name.
        self.assertEqual(re.findall(r"^  (\S+):$", jobs, re.M), ["factory-pause"])
        self.assertIn("    name: factory-pause\n", jobs)
        self.assertIn("    environment: factory-publish\n", jobs)
        for word in ("needs:", "if:", "continue-on-error", "concurrency", "gate.py", "check-release-environment"):
            self.assertNotIn(word, jobs)
        self.assertIn("value: ${{ jobs.factory-pause.outputs.outcome }}", workflow)
        self.assertRegex(jobs, r"set -euo pipefail\n(?:.*\n)*?.*publish\.py pause(?:.*\n)*?.*outcome=paused")

    @unittest.skipUnless(hasattr(gate, "PAUSE_JOB"), "needs the gate's failed-pause detection")
    def test_the_gate_looks_for_these_names(self):
        pause = self.read("factory-pause.yml")
        self.assertEqual(gate.PAUSE_PATH, ".github/workflows/factory-pause.yml")
        self.assertIn(f"\n    name: {gate.PAUSE_JOB}\n", pause)
        publishing = self.read("factory-publish.yml")
        self.assertIn(f"\n      - name: {gate.PAUSE_FAILED_STEP}\n", publishing)
        self.assertNotIn("continue-on-error", pause + publishing)
        for path in WORKFLOWS.iterdir():
            if path.name != "factory-pause.yml":
                named = rf"(?m)^  {gate.PAUSE_JOB}:|^    name: [\"']?{gate.PAUSE_JOB}[\"']?\s*$"
                self.assertNotRegex(self.read(path.name), named)

    def test_an_unpaused_ticket_failure_is_evidence(self):
        step = self.read("factory-publish.yml").split("      - name: factory-pause-failed\n")[1]
        condition = re.search(r"if: >-\n((?:          .*\n)+)", step)[1].split()
        self.assertEqual(
            " ".join(condition),
            "always() && inputs.operation == 'ticket' && steps.publish.outcome != 'skipped' "
            "&& steps.result.outputs.pause != 'unneeded' && steps.result.outputs.pause != 'done'",
        )
        self.assertIn("exit 1", step)
        self.assertNotIn("- name", step)

    def test_tests_ci_covers_every_pull_request_to_main(self):
        trigger = self.read("runTests.yml").split("jobs:")[0]
        self.assertRegex(trigger, r'pull_request:\n\s+branches: \[ "main" \]')
        self.assertNotIn("paths", trigger)


if __name__ == "__main__":
    unittest.main()
