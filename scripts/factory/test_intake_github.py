import contextlib
import copy
import http.server
import io
import itertools
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import github_http
import intake
import intake_github

MAINTAINER = {"databaseId": intake.MAINTAINER_ID}
CREATED = "2026-11-01T00:00:00Z"


def page(nodes=()):
    return {"totalCount": len(nodes), "nodes": list(nodes)}


def issue_node(**extra):
    return {
        "number": 5,
        "state": "OPEN",
        "title": "Title",
        "body": "Body",
        "createdAt": CREATED,
        "lastEditedAt": None,
        "author": MAINTAINER,
        "labels": page([{"name": "ready-for-agent"}]),
        "userContentEdits": page(),
        "blockedBy": page(),
        "issueDependenciesSummary": {"blockedBy": 0, "totalBlockedBy": 0},
        "comments": page(),
        **extra,
    }


IDS = itertools.count()


def labeled(**extra):
    return {
        "id": 1,
        "node_id": extra.pop("node_id", f"N{next(IDS)}"),
        "event": "labeled",
        "created_at": CREATED,
        "actor": {"id": intake.MAINTAINER_ID},
        "performed_via_github_app": None,
        "label": {"name": "ready-for-agent"},
        **extra,
    }


class FakeTransport:
    """Answers GitHub requests; issue reads come from a queue, then repeat."""

    def __init__(self, *issues, timeline=None, listing=None, states=None):
        self.issues = list(issues) or [issue_node()]
        self.timeline = [labeled()] if timeline is None else timeline
        self.listing = listing
        self.states = states or {}

    def __call__(self, method, path, body=None):
        if path == "/graphql":
            assert method == "POST" and body["query"].startswith("query")
            node = self.issues.pop(0) if len(self.issues) > 1 else self.issues[0]
            node = copy.deepcopy(node)
            if "timelineItems" not in node:
                node["timelineItems"] = page(
                    [
                        {"id": entry.get("node_id")}
                        for entry in self.timeline
                        if entry and entry.get("event") in intake_github.EVENT_TYPES
                    ]
                )
            return {"data": {"repository": {"issue": node}}}
        assert method == "GET"
        path, _, query = path.partition("?")
        number = int(query.rpartition("page=")[2]) if query else 1
        if path.endswith("/timeline"):
            return self.timeline[(number - 1) * 100 : number * 100]
        if path.endswith("/issues"):
            listing = self.listing
            if listing is None:
                listing = [
                    {"number": 5, "labels": [{"name": "ready-for-agent"}]},
                    {"number": 6, "labels": [{"name": "needs-triage"}]},
                    {
                        "number": 7,
                        "labels": [{"name": "ready-for-agent"}],
                        "pull_request": {},
                    },
                ]
            return listing[(number - 1) * 100 : number * 100]
        try:
            return {"state": self.states[int(path.rpartition("/")[2])]}
        except KeyError:
            raise intake_github.LookupFailed("GitHub request failed") from None


def fetch(*issues, **kwargs):
    return intake_github.fetch_ticket(FakeTransport(*issues, **kwargs), "o/r", 5)


class FetchTicket(unittest.TestCase):
    def test_result_is_accepted_by_intake(self):
        self.assertEqual(intake.next_step([fetch()])["action"], "assess")

    def test_reads_events_past_the_first_page(self):
        noise = [labeled(event="mentioned") for _ in range(100)]
        self.assertEqual(
            intake.next_step([fetch(timeline=[*noise, labeled()])])["action"], "assess"
        )

    def test_timeline_must_match_the_independent_event_list(self):
        renamed = labeled(event="renamed", actor={"id": 99})

        class Dropping(FakeTransport):
            def __call__(self, method, path, body=None):
                result = super().__call__(method, path, body)
                return result[:99] if "/timeline" in path else result

        entries = [labeled()] + [labeled(event="mentioned") for _ in range(98)]
        with self.assertRaises(intake_github.Unreadable):
            intake_github.fetch_ticket(
                Dropping(timeline=[*entries, renamed]), "o/r", 5
            )
        first = labeled()
        for timeline, ids in (
            ([first], [first["node_id"], "missing"]),
            ([first], []),
            ([first, first], [first["node_id"]]),
        ):
            node = issue_node(timelineItems=page([{"id": i} for i in ids]))
            with self.assertRaises(intake_github.Unreadable):
                fetch(node, timeline=timeline)

    def test_a_short_page_is_not_the_last_page(self):
        class Short(FakeTransport):
            def __call__(self, method, path, body=None):
                result = super().__call__(method, path, body)
                return result[:99] if "page=1" in path and "timeline" in path else result

        noise = [labeled(event="mentioned") for _ in range(100)]
        renamed = labeled(event="renamed", actor={"id": 99})
        item = intake_github.fetch_ticket(
            Short(timeline=[labeled(), *noise, renamed]), "o/r", 5
        )
        self.assertEqual(item["events"][-1]["event"], "renamed")

    def test_endless_pages_are_refused(self):
        class Endless(FakeTransport):
            calls = 0

            def __call__(self, method, path, body=None):
                if path != "/graphql":
                    self.calls += 1
                    assert self.calls < 1000
                    return [labeled(event="mentioned", number=1, labels=[])]
                return super().__call__(method, path, body)

        with self.assertRaises(intake_github.Unreadable):
            intake_github.fetch_ticket(Endless(), "o/r", 5)
        with self.assertRaises(intake_github.LookupFailed):
            intake_github.fetch_ready_tickets(Endless(), "o/r")

    def test_unknown_timeline_entries_are_refused(self):
        unnamed = labeled()
        del unnamed["event"]
        for entry in (None, unnamed, labeled(event=None), labeled(event="")):
            with self.assertRaises(intake_github.Unreadable):
                fetch(timeline=[labeled(), entry])

    def test_app_or_unknown_application_is_not_the_maintainer(self):
        unknown = labeled()
        del unknown["performed_via_github_app"]
        for entry in (
            labeled(performed_via_github_app={"id": 1}),
            unknown,
            labeled(actor=None),
        ):
            step = intake.next_step([fetch(timeline=[entry])])
            self.assertEqual(step["skipped"][0]["reason"], "ready-label-unproven")

    def test_edits_comments_and_deleted_users(self):
        edited = {
            "lastEditedAt": CREATED,
            "userContentEdits": page([{"editedAt": CREATED, "editor": None}]),
        }
        remark = {"id": "C", "author": None, "body": "x", "createdAt": CREATED}
        item = fetch(issue_node(comments=page([{**remark, **edited}]), **edited))
        self.assertEqual(item["edits"], [{"edited_at": CREATED, "editor_id": None}])
        self.assertEqual(item["comments"][0]["edits"], item["edits"])
        self.assertIsNone(item["comments"][0]["author_id"])

    def test_native_blockers_count_only_when_closed(self):
        for node, blocked in (({"state": "OPEN"}, 1), (None, 1), ({"state": "CLOSED"}, 0)):
            item = issue_node(
                blockedBy=page([node]),
                issueDependenciesSummary={"blockedBy": blocked, "totalBlockedBy": 1},
            )
            self.assertEqual(fetch(item)["open_blockers"], blocked)

    def test_evidence_of_a_hidden_blocker_blocks(self):
        for extra, timeline in (
            ({"issueDependenciesSummary": {"blockedBy": 0, "totalBlockedBy": 1}}, []),
            ({"issueDependenciesSummary": {"blockedBy": 1, "totalBlockedBy": 0}}, []),
            ({}, [labeled(event="blocked_by_added")]),
        ):
            item = fetch(issue_node(**extra), timeline=[labeled(), *timeline])
            self.assertEqual(
                intake.next_step([item])["skipped"][0]["reason"], "blocked"
            )
        removed = [labeled(event="blocked_by_added"), labeled(event="blocked_by_removed")]
        self.assertEqual(fetch(timeline=[labeled(), *removed])["open_blockers"], 0)

    def test_body_blockers_are_looked_up(self):
        node = issue_node(body="Blocked by: #8")
        self.assertEqual(fetch(node, states={8: "open"})["blocker_states"], {8: "open"})
        missing = intake.next_step([fetch(node)])
        self.assertEqual(missing["skipped"][0]["reason"], "blocked")

    def test_truncated_or_changing_data_is_refused(self):
        for field in ("labels", "userContentEdits", "blockedBy", "comments"):
            node = issue_node(**{field: {"totalCount": 101, "nodes": []}})
            with self.assertRaises(intake_github.LookupFailed):
                fetch(node)
        with self.assertRaises(intake_github.LookupFailed):
            fetch(issue_node(), issue_node(title="Changed while reading"))

    def test_graphql_errors_and_missing_issues_are_refused(self):
        for response in (
            {"errors": [{}], "data": {"repository": {"issue": issue_node()}}},
            {"data": {"repository": {"issue": None}}},
            {},
        ):
            with self.assertRaises(intake_github.LookupFailed):
                intake_github.fetch_ticket(lambda *_: response, "o/r", 5)


class HttpTransport(unittest.TestCase):
    def setUp(self):
        test = self
        self.requests = []
        self.status = 200

        class Handler(http.server.BaseHTTPRequestHandler):
            def answer(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                test.requests.append((self.path, self.headers.get("Authorization")))
                status = 200 if self.path == "/elsewhere" else test.status
                self.send_response(status)
                if status != 200:
                    self.send_header("Location", test.location)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            do_GET = do_POST = answer

            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.port = server.server_port
        root = f"http://127.0.0.1:{self.port}"
        patch = mock.patch.object(github_http, "API", root)
        patch.start()
        self.addCleanup(patch.stop)
        self.send = intake_github.http_transport("TOKEN")

    def test_environment_proxies_are_ignored(self):
        proxy = f"http://127.0.0.1:{self.port}/proxy"
        with mock.patch.dict(os.environ, {"http_proxy": proxy, "https_proxy": proxy,
                                          "all_proxy": proxy, "no_proxy": ""}):
            self.assertEqual(intake_github.http_transport("TOKEN")("GET", "/x"), {})
        self.assertEqual(self.requests, [("/x", "Bearer TOKEN")])

    def test_sends_to_the_api(self):
        self.assertEqual(self.send("GET", "/x"), {})
        self.assertEqual(self.requests, [("/x", "Bearer TOKEN")])

    def test_redirects_are_refused(self):
        for status in (301, 302, 303, 307, 308):
            for host in ("127.0.0.1", "localhost"):
                for method, body in (("GET", None), ("POST", {})):
                    with self.subTest(status=status, host=host, method=method):
                        self.status = status
                        self.location = f"http://{host}:{self.port}/elsewhere"
                        self.requests.clear()
                        with self.assertRaises(intake_github.LookupFailed):
                            self.send(method, "/x", body)
                        self.assertEqual([path for path, _ in self.requests], ["/x"])

    def test_off_host_urls_are_refused_before_sending(self):
        for path in (
            f"@localhost:{self.port}/elsewhere",
            ".evil.example/x",
            f"http://localhost:{self.port}/elsewhere",
            f"//localhost:{self.port}/elsewhere",
            "/\\localhost/elsewhere",
            "/x\r\nHost: evil.example",
            "/x y",
            "/x#y",
            "",
        ):
            with self.subTest(path), self.assertRaises(intake_github.LookupFailed):
                self.send("GET", path)
        self.assertEqual(self.requests, [])


class CommandLine(unittest.TestCase):
    def run_main(self, transport, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "step.json"
            errors = io.StringIO()
            with (
                mock.patch.object(intake_github, "http_transport", lambda _: transport),
                mock.patch.dict(os.environ, {"GITHUB_TOKEN": "x"}),
                contextlib.redirect_stderr(errors),
                contextlib.redirect_stdout(errors),
            ):
                code = intake_github.main(
                    [*arguments, "--repository", "o/r"]
                    + (["--output", str(output)] if arguments[0] == "next" else [])
                )
            step = json.loads(output.read_text()) if output.exists() else None
            return code, step, errors.getvalue()

    def test_next_reads_only_ready_issues(self):
        code, step, _ = self.run_main(FakeTransport(), "next")
        self.assertEqual((code, step["action"], step["ticket"]), (0, "assess", 5))
        self.assertEqual(step["skipped"], [])

    def test_lists_past_the_first_page(self):
        listing = [{"number": n, "labels": []} for n in range(100, 200)]
        listing.append({"number": 5, "labels": [{"name": "Ready-For-Agent"}]})
        _, step, _ = self.run_main(FakeTransport(listing=listing), "next")
        self.assertEqual(step["ticket"], 5)

    def test_lookup_failure_writes_no_step_and_no_ticket_text(self):
        def failing(method, path, body=None):
            raise intake_github.LookupFailed("GitHub request failed")

        code, step, errors = self.run_main(failing, "next")
        self.assertEqual((code, step), (1, None))
        self.assertIn("GitHub request failed", errors)

    def test_one_unreadable_ticket_does_not_stop_the_others(self):
        listing = [
            {"number": n, "labels": [{"name": "ready-for-agent"}]} for n in (9, 5)
        ]
        # The first ticket is read once and fails; the next reads normally.
        transport = FakeTransport(
            issue_node(labels="SECRET TEXT"), issue_node(), listing=listing
        )
        code, step, errors = self.run_main(transport, "next")
        self.assertEqual((code, step["action"], step["ticket"]), (0, "assess", 5))
        self.assertEqual(step["skipped"], [{"ticket": 9, "reason": "unreadable"}])
        self.assertNotIn("SECRET TEXT", errors)

    def test_verify(self):
        item = fetch()
        evidence = {
            "ticket": 5,
            "source_digest": intake.next_step([item])["digest"],
            "output": '{"kind": "tests", "human_reviewed_classes": [],'
            ' "contradicted_adrs": []}',
        }
        digest = intake.next_step([item], [evidence])["work_digest"]
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "assessments.json"
            arguments = ("verify", "--ticket", "5", "--assessments", str(file))
            for assessments, work_digest, code in (
                ([evidence], digest, 0),
                ([evidence], "0", 1),
                ([], digest, 1),
                ([evidence, evidence], digest, 1),
                ("bad", digest, 1),
            ):
                file.write_text(json.dumps(assessments))
                result = self.run_main(
                    FakeTransport(), *arguments, "--work-digest", work_digest
                )
                self.assertEqual(result[0], code)
            file.write_text("not json")
            result = self.run_main(
                FakeTransport(), *arguments, "--work-digest", digest
            )
            self.assertEqual(result[0], 1)


if __name__ == "__main__":
    unittest.main()
