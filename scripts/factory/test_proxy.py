import http.client
import json
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import proxy


def dummy(prefix, fill="x"):
    """A pretend token. Built when called, so that no source or compiled file holds one."""
    return prefix + fill * 60


TOKEN = "sk-ant-oat01-" + "".join(chr(ord("A") + i % 26) + str(i % 10) for i in range(30))
LIMIT = {
    "anthropic-ratelimit-unified-status": "rejected",
    "anthropic-ratelimit-unified-reset": "1800000000",
}
MODEL = "claude-sonnet-5-5"
BODY = {
    "model": MODEL,
    "max_tokens": 1,
    "messages": [{"role": "user", "content": "hi"}],
    "tools": [{"name": "Bash", "description": "run", "input_schema": {"type": "object"}}],
}


def client_hello(host):
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = ssl.create_default_context().wrap_bio(incoming, outgoing, server_hostname=host)
    try:
        tls.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def with_extension(hello, extension):
    """Append an extension to a ClientHello and grow the three enclosing lengths."""
    body = bytearray(hello)
    at = 5 + 4 + 2 + 32
    at += 1 + body[at]
    at += 2 + int.from_bytes(body[at : at + 2], "big")
    at += 1 + body[at]
    for offset, width in ((3, 2), (6, 3), (at, 2)):
        value = int.from_bytes(body[offset : offset + width], "big") + len(extension)
        body[offset : offset + width] = value.to_bytes(width, "big")
    return bytes(body + extension)


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("proxy", timeout=10)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(10)
        self.sock.connect(str(self.path))


class FakeUpstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        self.server.seen.append((self.path, self.headers, body))
        status, headers, chunks = self.server.reply
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        if self.server.truncate == "length":
            self.send_header("content-length", "1000")
            self.end_headers()
            self.wfile.write(b"short")
            self.close_connection = True
            return
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        try:
            for chunk in chunks:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                if self.server.gate:
                    self.server.gate.wait(10)
            if self.server.truncate:
                self.close_connection = True
                return
            self.wfile.write(b"0\r\n\r\n")
        except OSError:
            self.close_connection = True

    def log_message(self, *_):
        pass


class ProxyTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.events = []

    def serve(self, server):
        threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        ).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def kinds(self):
        return [event["kind"] for event in self.events]

    def wait_for(self, kind):
        deadline = time.monotonic() + 10
        while kind not in self.kinds():
            self.assertLess(time.monotonic(), deadline, f"no {kind} in {self.kinds()}")
            time.sleep(0.005)


class ModelProxyTests(ProxyTestCase):
    def setUp(self):
        super().setUp()
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        self.upstream.daemon_threads = True
        self.upstream.handle_error = lambda *_: None
        self.upstream.seen, self.upstream.gate, self.upstream.truncate = [], None, False
        self.upstream.reply = (200, {"content-type": "text/event-stream"}, [b"data: hi\n\n"])
        self.serve(self.upstream)
        self.start(f"http://127.0.0.1:{self.upstream.server_port}")

    def start(self, upstream=None, **options):
        upstream = upstream or f"http://127.0.0.1:{self.upstream.server_port}"
        self.path = Path(self.dir.name) / f"m{len(list(Path(self.dir.name).iterdir()))}"
        self.server = proxy.ModelProxy(
            self.path, TOKEN, self.events.append, MODEL, upstream=upstream, **options
        )
        self.serve(self.server)

    def request(self, method="POST", path="/v1/messages?beta=true", body=BODY, headers=None):
        if isinstance(body, dict):
            body = json.dumps(body)
        connection = UnixConnection(self.path)
        self.addCleanup(connection.close)
        connection.request(method, path, body, headers or {})
        return connection.getresponse()

    def status(self, *arguments, **options):
        """Send a request, read the whole reply, and return its status.

        A reply left unread makes the proxy see a client that hung up, at a
        moment that depends on garbage collection.
        """
        response = self.request(*arguments, **options)
        response.read()
        return response.status

    def test_replaces_every_client_credential_with_the_held_token(self):
        self.status(
            headers={
                "Authorization": "Bearer placeholder",
                "X-Api-Key": "k",
                "Cookie": "c",
                "Proxy-Authorization": "p",
            }
        )
        _, headers, _ = self.upstream.seen[0]
        self.assertEqual(headers.get_all("authorization"), [f"Bearer {TOKEN}"])
        for name in ("x-api-key", "cookie", "proxy-authorization"):
            self.assertIsNone(headers[name])

    def test_forwards_capability_headers_body_and_response(self):
        self.upstream.reply = (200, {"anthropic-ratelimit-unified-status": "allowed"}, [b"ok"])
        response = self.request(
            headers={
                "anthropic-beta": "oauth-2025-04-20,effort-2025-11-24",
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
        )
        self.assertEqual(response.read(), b"ok")
        self.assertEqual(response.headers["anthropic-ratelimit-unified-status"], "allowed")
        path, headers, body = self.upstream.seen[0]
        self.assertEqual(
            (path, headers["anthropic-beta"], headers["anthropic-version"], json.loads(body)),
            ("/v1/messages?beta=true", "oauth-2025-04-20,effort-2025-11-24", "2023-06-01", BODY),
        )

    def test_streams_before_the_upstream_finishes(self):
        self.upstream.gate = threading.Event()
        response = self.request()
        self.assertEqual(response.read1(100), b"data: hi\n\n")
        self.upstream.gate.set()
        self.assertEqual(response.read(), b"")

    def test_truncated_upstream_is_visible_to_the_client(self):
        for self.upstream.truncate in (True, "length"):
            with self.assertRaises(http.client.IncompleteRead):
                self.request().read()

    def test_other_routes_never_reach_upstream(self):
        for method, path in (
            ("POST", "/v1/files"),
            ("GET", "/v1/messages"),
            ("POST", "/api/oauth/usage"),
            ("POST", "//evil/v1/messages"),
            ("POST", "/v1/messages?next=/x"),
            ("PUT", "/v1/messages"),
        ):
            self.assertEqual(self.status(method, path), 403, (method, path))
        self.assertEqual(self.upstream.seen, [])

    def test_connection_warming_probe_is_answered_locally(self):
        self.assertEqual(self.status("HEAD", "/api/hello", None), 200)
        self.assertEqual(self.upstream.seen, [])

    def test_usage_limit_is_recorded_and_latched(self):
        self.upstream.reply = (429, LIMIT, [b"limit"])
        first = self.request()
        self.assertEqual((first.status, first.read()), (429, b"limit"))
        self.upstream.reply = (200, {}, [b"ok"])
        again = self.request()
        again.read()
        self.assertEqual(again.status, 429)
        self.assertEqual(again.headers["anthropic-ratelimit-unified-status"], "rejected")
        self.assertEqual(len(self.upstream.seen), 1)
        self.assertEqual(self.kinds(), ["usage_limit", "refused"])

    def test_other_failures_are_not_usage_limits(self):
        for status, headers, kind in (
            (429, {}, "throttled"),
            (429, {"anthropic-ratelimit-unified-status": "allowed"}, "throttled"),
            (529, {}, "overloaded"),
            (401, {}, "auth_failed"),
            (403, {}, "auth_failed"),
            (500, {}, "upstream_error"),
        ):
            self.upstream.reply = (status, headers, [b"e"])
            self.status()
            self.assertEqual(self.kinds()[-1], kind)
        self.upstream.reply = (200, {}, [b"ok"])
        self.assertEqual(self.status(), 200)

    def test_usage_credits_signal_stops_the_run(self):
        self.upstream.reply = (
            200,
            {"anthropic-ratelimit-unified-overage-status": "allowed"},
            [b"x"],
        )
        self.status()
        self.assertEqual(self.status(), 403)
        self.assertIn("usage_credits", self.kinds())

    def test_disabled_usage_credits_do_not_stop_the_run(self):
        self.upstream.reply = (
            200,
            {"anthropic-ratelimit-unified-overage-status": "rejected"},
            [b"x"],
        )
        self.status()
        self.assertEqual(self.status(), 200)
        self.assertIn(
            "rejected", [e.get("limits", {}).get("overage-status") for e in self.events]
        )

    def test_request_backstop(self):
        self.start(max_requests=1)
        self.assertEqual(self.status(), 200)
        self.assertEqual(self.status(), 403)
        self.assertEqual(self.kinds()[-1], "refused")

    def test_default_request_backstop_is_the_turn_cap(self):
        self.assertEqual(self.server.remaining, 100)

    def test_unreachable_upstream_is_a_502(self):
        with socket.socket() as unused:
            unused.bind(("127.0.0.1", 0))
            port = unused.getsockname()[1]
        self.start(f"http://127.0.0.1:{port}")
        self.assertEqual(self.status(), 502)
        self.assertEqual(self.kinds(), ["upstream_unreachable"])

    def assert_echo_stops_the_run(self, reply):
        self.upstream.reply = reply
        response = self.request()
        seen = str(response.headers).encode()
        try:
            seen += response.read()
        except http.client.IncompleteRead as error:
            seen += error.partial
        for start in range(13, len(TOKEN) - 8):
            self.assertNotIn(TOKEN[start : start + 8].lower().encode(), seen.lower())
        self.assertEqual(self.status(), 403)
        self.assertIn("token_echoed", self.kinds())
        for start in range(13, len(TOKEN) - 8):
            self.assertNotIn(TOKEN[start : start + 8].lower(), json.dumps(self.events).lower())

    def test_body_echo_stops_the_run(self):
        self.assert_echo_stops_the_run((200, {}, [b"a" + TOKEN.encode() + b"b"]))

    def test_echo_split_into_single_bytes_stops_the_run(self):
        self.assert_echo_stops_the_run((200, {}, [bytes([c]) for c in TOKEN.encode()]))

    def test_header_echo_stops_the_run(self):
        self.assert_echo_stops_the_run((400, {"x-echo": TOKEN}, [b"bad"]))

    def test_echo_split_across_headers_stops_the_run(self):
        self.assert_echo_stops_the_run((400, {"x-a": TOKEN[:25], "x-b": TOKEN[25:]}, [b"bad"]))

    def test_echo_split_by_spaces_in_a_header_stops_the_run(self):
        spaced = " ".join(TOKEN[i : i + 5] for i in range(0, len(TOKEN), 5))
        self.assert_echo_stops_the_run((400, {"request-id": spaced}, [b"bad"]))

    def test_echo_in_a_header_name_stops_the_run(self):
        for name in (TOKEN, TOKEN.lower(), "anthropic-ratelimit-unified-" + TOKEN[13:].upper()):
            self.start()
            self.assert_echo_stops_the_run((200, {name: "x"}, [b"ok"]))

    def test_each_way_to_hide_a_token_in_headers_is_searched(self):
        search = proxy.TokenSearch(TOKEN)
        secret = TOKEN[13:]
        # Pieces too short to find alone, so each case needs its own joined text.
        a, b, c = secret[:8], secret[8:16], secret[16:24]
        for reason, headers in (
            (f"x {a} {b}", {}),
            ("OK", {a: "zz", b: "zz"}),
            ("OK", {"x-p": a, "x-q": b}),
            ("OK", {a: b}),
            ("OK", {"!": a, b: "?"}),
            ("OK", {"!": a, b: c}),
        ):
            self.assertTrue(search.found_in_headers(reason, headers), (reason, headers))
        for reason, headers in (("OK", {}), (a, {"x": "y"}), ("OK", {a: "y", "x": "z"})):
            self.assertFalse(search.found_in_headers(reason, headers), (reason, headers))

    def test_every_guard_against_numbers_json_lacks(self):
        good = json.dumps(BODY).encode()[:-1]
        for literal in (b"NaN", b"Infinity", b"-Infinity", b"1e999", b"-1e999"):
            raw = good + b',"temperature":' + literal + b"}"
            # Reading must refuse it without help from writing.
            with unittest.mock.patch.object(proxy.model_request.json, "dumps", lambda *_, **__: ""):
                with self.assertRaises(proxy.model_request.Refused, msg=literal):
                    proxy.model_request.check_body(raw, MODEL, False)
        # Should one be missed while reading, it must not be written either.
        with unittest.mock.patch.object(proxy.model_request, "finite", float):
            with self.assertRaises(proxy.model_request.Refused):
                proxy.model_request.check_body(good + b',"temperature":1e999}', MODEL, False)
        self.assertIn(
            b"0.5", proxy.model_request.check_body(good + b',"temperature":0.5}', MODEL, False)
        )

    def test_echo_split_across_header_names_stops_the_run(self):
        self.assert_echo_stops_the_run((200, {TOKEN[:20]: "x", TOKEN[20:]: "y"}, [b"ok"]))

    def test_echo_in_another_case_stops_the_run(self):
        self.assert_echo_stops_the_run((200, {}, [TOKEN.lower().encode()]))

    def test_echo_in_a_limit_header_is_not_logged(self):
        self.assert_echo_stops_the_run((200, {"anthropic-ratelimit-unified-x": TOKEN}, [b"x"]))
        self.assertNotIn("ok", self.kinds())

    def test_compressed_responses_are_refused_because_they_cannot_be_searched(self):
        self.upstream.reply = (200, {"content-encoding": "gzip"}, [b"x"])
        self.assertEqual(self.status(), 502)

    def test_redirects_are_refused(self):
        self.upstream.reply = (302, {"location": "https://evil.example/"}, [b""])
        response = self.request()
        response.read()
        self.assertEqual((response.status, response.headers["location"]), (502, None))

    def test_bodies_outside_the_allowlist_never_reach_upstream(self):
        text = {"type": "text", "text": "x"}
        remote = {"type": "image", "source": {"type": "url", "url": "https://evil.example"}}

        def user(*blocks):
            return {"messages": [{"role": "user", "content": list(blocks)}]}

        def tool(**fields):
            return {"tools": [{"name": "Bash", "input_schema": {}, **fields}]}

        changes = [
            {"model": "claude-opus-5-5"},
            {"model": ["claude-sonnet-5-5"]},
            {"speed": "fast"},
            {"service_tier": "auto"},
            {"mcp_servers": []},
            {"container": "x"},
            {"unknown": None},
            {"betas": []},
            {"context_management": {}},
            {"max_tokens": "1"},
            {"max_tokens": True},
            {"stream": 1},
            tool(type="web_search_20250305", name="web_search"),
            tool(type="web_fetch_20250910"),
            tool(type="code_execution_20250825", name="code_execution"),
            {"tools": [{"type": "mcp_toolset", "mcp_server_name": "x"}]},
            tool(name="WebFetch"),
            tool(allowed_callers=["code_execution_20250825"]),
            tool(type=None),
            {"tools": {}},
            {"tools": ["Bash"]},
            {"tool_choice": {"type": "x"}},
            user(remote),
            user({**text, "extra": 1}),
            user({"type": "container_upload", "file_id": "f"}),
            user({"type": "document", "source": {"type": "file", "file_id": "f"}}),
            user({"type": "tool_result", "tool_use_id": "t", "content": [remote]}),
            user({"type": "server_tool_use", "id": "x", "name": "web_search", "input": {}}),
            user({"type": "tool_use", "id": "x", "name": "Bash", "input": {}, "caller": "x"}),
            user({"type": "text", "text": {"a": 1}}),
            user("text"),
            {"messages": [{"role": "tool", "content": "x"}]},
            {"messages": "x"},
            {"messages": []},
            {"system": [remote]},
            {"output_config": {"task_budget": 1}},
        ]
        for change in changes:
            self.assertEqual(self.status(body={**BODY, **change}), 403, change)
        for raw in (
            b"",
            b"[]",
            b"{",
            b"\xff",
            b'{"a":NaN}',
            json.dumps(BODY).encode()[:-1] + b',"temperature":1e999}',
            json.dumps(BODY).encode()[:-1] + b',"temperature":-1e999}',
            json.dumps({**BODY, "tools": []}).encode()[:-3]
            + b'[{"name":"Bash","input_schema":{"maximum":1e999}}]}',
            b"[" * 100000,
            json.dumps(BODY).encode()[:-1] + b',"model":"x"}',
            json.dumps(BODY).encode()[:-1] + b',"\\u0074ools":[]}',
        ):
            self.assertEqual(self.status(body=raw), 403, raw[:40])
        for missing in ("model", "messages", "max_tokens"):
            body = {name: value for name, value in BODY.items() if name != missing}
            self.assertEqual(self.status(body=body), 403, missing)
        self.assertEqual(self.upstream.seen, [])
        self.assertEqual(set(self.kinds()), {"refused"})

    def test_everything_the_pinned_client_sends_is_allowed(self):
        cache = {"type": "ephemeral", "ttl": "1h"}
        result = {
            "type": "tool_result",
            "tool_use_id": "t",
            "content": "hi",
            "is_error": False,
            "cache_control": cache,
        }
        picture = {"type": "base64", "media_type": "image/png", "data": "eA=="}
        body = {
            **BODY,
            "system": [{"type": "text", "text": "x", "cache_control": cache}],
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "x"}]},
                {"role": "system", "content": "x"},
                {
                    "role": "assistant",
                    "content": [
                        {"type": "thinking", "thinking": "", "signature": "s"},
                        {"type": "redacted_thinking", "data": "d"},
                        {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "x"}},
                    ],
                },
                {
                    "role": "user",
                    "content": [
                        result,
                        {**result, "content": [{"type": "image", "source": picture}]},
                    ],
                },
            ],
            "metadata": {"user_id": "u"},
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": "medium"},
            "stream": True,
        }
        self.assertEqual(self.status(body=body), 200)
        self.assertEqual(json.loads(self.upstream.seen[0][2]), body)

    def test_token_counting_needs_no_max_tokens(self):
        body = {name: value for name, value in BODY.items() if name != "max_tokens"}
        self.assertEqual(self.status(path="/v1/messages/count_tokens", body=body), 200)

    def test_unapproved_betas_and_headers_never_reach_upstream(self):
        for value in (
            "context-1m-2025-08-07",
            "mcp-client-2025-04-04",
            "oauth-2025-04-20,web-fetch-2025-09-10",
        ):
            self.assertEqual(self.status(headers={"anthropic-beta": value}), 403, value)
        self.assertEqual(self.status(headers={"anthropic-version": "2099-01-01"}), 403)
        self.assertEqual(self.status(headers={"content-encoding": "gzip"}), 403)
        self.assertEqual(self.upstream.seen, [])
        extra = {"x-other": "v", "anthropic-x": "v", "x-http-method-override": "GET"}
        self.assertEqual(self.status(headers=extra), 200)
        for name in extra:
            self.assertIsNone(self.upstream.seen[0][1][name])

    def test_ambiguous_framing_is_refused(self):
        body = json.dumps(BODY).encode()
        length = b"Content-Length: %d\r\n" % len(body)
        for extra in (
            b"X-A: a\r\n Authorization: evil\r\n",
            b"X-A: a\n\r\n",
            b"Content-Length: 2\r\n",
            b"Transfer-Encoding: chunked\r\n",
            b"Transfer-Encoding : chunked\r\n",
            b"Content-Length : 2\r\n",
            b"anthropic-beta: oauth-2025-04-20\r\nanthropic-beta: evil\r\n",
        ):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10)
                client.connect(str(self.path))
                client.sendall(
                    b"POST /v1/messages HTTP/1.1\r\nHost: x\r\n" + length + extra + b"\r\n" + body
                )
                self.assertRegex(client.recv(100), rb"^HTTP/1.1 (400|403|411) ", extra)
        self.assertEqual(self.upstream.seen, [])

    def test_a_client_that_hangs_up_is_not_an_upstream_failure(self):
        self.upstream.gate = threading.Event()
        self.upstream.reply = (200, {}, [b"x" * 100000] * 20)
        connection = UnixConnection(self.path)
        connection.request("POST", "/v1/messages", json.dumps(BODY))
        connection.getresponse().close()
        connection.close()
        self.upstream.gate.set()
        self.wait_for("client_gone")
        self.assertEqual(self.kinds(), ["ok", "client_gone"])

    def test_concurrent_requests_are_bounded(self):
        self.start(connections=1)
        self.upstream.gate = threading.Event()
        held = self.request()
        with self.assertRaises((OSError, http.client.HTTPException)):
            self.request()
        self.upstream.gate.set()
        held.read()

    def test_sockets_are_private(self):
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_stop_refuses_later_requests(self):
        self.server.stop("time is up")
        self.assertEqual(self.status(), 403)
        self.assertEqual(self.upstream.seen, [])

    def test_plaintext_remote_upstream_and_unscannable_token_are_rejected(self):
        path = Path(self.dir.name) / "z"
        with self.assertRaises(ValueError):
            proxy.ModelProxy(path, TOKEN, print, MODEL, upstream="http://example.com")
        for token in ("opaque", dummy("sk-ant-api03-"), TOKEN + "\r\nX: y"):
            with self.assertRaises(ValueError):
                proxy.ModelProxy(path, token, print, MODEL)


class EgressProxyTests(ProxyTestCase):
    def setUp(self):
        super().setUp()
        self.echo = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(self.echo.close)
        self.dialled = []
        self.path = Path(self.dir.name) / "e"

        def dial(host, port):
            self.dialled.append((host, port))
            return socket.create_connection(self.echo.getsockname())

        self.serve(proxy.EgressProxy(self.path, self.events.append, dial=dial))

    def send(self, line, payload=b""):
        client = socket.socket(socket.AF_UNIX)
        self.addCleanup(client.close)
        client.settimeout(10)
        client.connect(str(self.path))
        client.sendall(line.encode() + b"\r\nHost: x\r\n\r\n" + payload)
        return client, client.recv(4096)

    def accept(self):
        server, _ = self.echo.accept()
        self.addCleanup(server.close)
        server.settimeout(10)
        return server

    def read(self, server, size):
        data = b""
        while len(data) < size:
            data += server.recv(65536)
        return data

    def test_tunnels_tls_to_the_named_host_and_counts_bytes(self):
        client, reply = self.send("CONNECT cache.nixos.org:443 HTTP/1.1")
        self.assertIn(b" 200 ", reply)
        server = self.accept()
        hello = client_hello("cache.nixos.org")
        for start in range(0, len(hello), 100):
            client.sendall(hello[start : start + 100])
        self.assertEqual(self.read(server, len(hello)), hello)
        server.sendall(b"pong")
        self.assertEqual(client.recv(4), b"pong")
        record = b"\x17\x03\x03\x00\x02ab"
        for byte in record:
            client.sendall(bytes([byte]))
        self.assertEqual(self.read(server, len(record)), record)
        server.close()
        client.close()
        self.wait_for("tunnel")
        self.assertEqual(self.dialled, [("cache.nixos.org", 443)])
        self.assertEqual(
            [(e["kind"], e["host"], e["bytes"]) for e in self.events],
            [("tunnel", "cache.nixos.org", 4)],
        )

    def test_hello_sent_with_the_connect_is_not_lost(self):
        hello = client_hello("cache.nixos.org")
        self.send("CONNECT cache.nixos.org:443 HTTP/1.1", hello)
        self.assertEqual(self.read(self.accept(), len(hello)), hello)

    def forwarded(self, payload):
        client, reply = self.send("CONNECT cache.nixos.org:443 HTTP/1.1")
        self.assertIn(b" 200 ", reply)
        server = self.accept()
        try:
            client.sendall(payload)
            client.shutdown(socket.SHUT_WR)
        except OSError:
            pass  # The proxy may already have refused and hung up.
        received = b""
        try:
            while data := server.recv(65536):
                received += data
        except ConnectionError:
            pass
        server.close()
        return received

    def test_refuses_tunnels_that_are_not_tls_to_the_named_host(self):
        for payload in (
            b"GET / HTTP/1.1\r\nHost: cache.nixos.org\r\n\r\n",
            client_hello("evil.example"),
            client_hello("cache.nixos.org")[:60],
            client_hello("1.1.1.1"),
            b"",
        ):
            self.assertEqual(self.forwarded(payload), b"")
        self.assertIn("refused", self.kinds())

    def test_refuses_plaintext_after_a_valid_hello(self):
        hello = client_hello("cache.nixos.org")
        self.assertNotIn(b"GET /", self.forwarded(hello + b"GET / HTTP/1.1\r\n\r\n"))

    def test_refuses_hidden_or_repeated_server_names(self):
        hello = client_hello("cache.nixos.org")
        self.assertEqual(proxy.server_name(hello), "cache.nixos.org")
        name = b"evil.example"
        entry = b"\0" + len(name).to_bytes(2, "big") + name
        names = len(entry).to_bytes(2, "big") + entry
        for extension in (
            b"\xfe\x0d\x00\x00",
            b"\0\0" + len(names).to_bytes(2, "big") + names,
        ):
            with self.assertRaises(ValueError):
                proxy.server_name(with_extension(hello, extension))

    def test_malformed_hellos_are_refused(self):
        hello = client_hello("cache.nixos.org")
        for size in range(len(hello)):
            self.assertIsNone(proxy.server_name(hello[:size]), size)
        for at in range(5, 60):
            broken = hello[:at] + b"\xff" + hello[at + 1 :]
            try:
                self.assertIn(proxy.server_name(broken), (None, "cache.nixos.org"))
            except ValueError:
                pass

    def test_refuses_everything_else(self):
        for line in (
            "CONNECT example.com:443 HTTP/1.1",
            "CONNECT api.anthropic.com:443 HTTP/1.1",
            "CONNECT github.com:443 HTTP/1.1",
            "CONNECT api.github.com:443 HTTP/1.1",
            "CONNECT cache.nixos.org:80 HTTP/1.1",
            "CONNECT cache.nixos.org.evil.com:443 HTTP/1.1",
            "CONNECT x.cache.nixos.org:443 HTTP/1.1",
            "CONNECT 169.254.169.254:443 HTTP/1.1",
            "CONNECT cache.nixos.org HTTP/1.1",
            "GET http://cache.nixos.org/ HTTP/1.1",
        ):
            self.assertIn(b" 403 ", self.send(line)[1], line)
        self.assertEqual(self.dialled, [])

    def test_only_public_ipv4_addresses_are_dialled(self):
        with self.assertRaises(OSError):
            proxy.dial_public("localhost", 443)
        for address in (
            "127.0.0.1",
            "10.0.0.1",
            "169.254.169.254",
            "100.64.0.1",
            "224.0.0.1",
            "168.63.129.16",
            "192.0.0.8",
            "240.0.0.1",
            "0.0.0.0",
            "64:ff9b::a9fe:a9fe",
            "64:ff9b:1::1",
            "::ffff:8.8.8.8",
            "2002:7f00:1::",
            "2600::1",
        ):
            self.assertFalse(proxy.is_dialable(address), address)
        self.assertTrue(proxy.is_dialable("151.101.1.91"))


if __name__ == "__main__":
    unittest.main()
