import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

import gate
import github_http


class Server:
    """A local HTTP server that records the requests it receives."""

    def __init__(self, test, status=200, location=None):
        self.requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(handler):
                self.requests.append((handler.path, handler.headers.get("Authorization")))
                handler.send_response(status)
                if location:
                    handler.send_header("Location", location)
                handler.end_headers()
                handler.wfile.write(b"[]")

            do_POST = do_GET

            def log_message(handler, *arguments):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{server.server_port}"
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        test.addCleanup(server.server_close)
        test.addCleanup(thread.join)
        test.addCleanup(server.shutdown)


class GitHubHttpTests(unittest.TestCase):
    def use_api(self, server):
        patcher = patch.object(github_http, "API", server.url)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_ordinary_response_is_read_with_the_token(self):
        api = Server(self)
        self.use_api(api)
        self.assertEqual(gate._github("secret")("/x"), ([], None))
        self.assertEqual(api.requests, [("/x", "Bearer secret")])

    def test_redirects_are_refused_and_never_followed(self):
        for status in (300, 301, 302, 303, 307, 308):
            for same_host in (False, True):
                with self.subTest(status=status, same_host=same_host):
                    other = Server(self)
                    location = "/elsewhere" if same_host else other.url + "/steal"
                    api = Server(self, status, location)
                    self.use_api(api)
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        gate._github("secret")("/x")
                    caught.exception.close()
                    self.assertEqual(caught.exception.code, status)
                    self.assertEqual(other.requests, [])
                    self.assertEqual(len(api.requests), 1)

    def test_redirected_writes_are_refused(self):
        for status in (301, 302, 303, 307, 308):
            other = Server(self)
            api = Server(self, status, other.url)
            self.use_api(api)
            request = urllib.request.Request(api.url + "/x", data=b"{}", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as caught:
                github_http.open_api(request)
            caught.exception.close()
            self.assertEqual(other.requests, [])

    def test_gate_refuses_a_redirect(self):
        api = Server(self, 302, "/elsewhere")
        self.use_api(api)
        environment = {"GITHUB_REPOSITORY": "octo/repo", "GITHUB_RUN_ID": "1",
                       "FACTORY_GATE_TOKEN": "secret"}
        with patch.dict("os.environ", environment):
            with self.assertRaisesRegex(gate.Refused, "lookup failed.*302"):
                gate.require("publish")

    def test_environment_proxies_are_ignored(self):
        api, proxy = Server(self), Server(self)
        self.use_api(api)
        with patch.dict("os.environ", {"http_proxy": proxy.url, "https_proxy": proxy.url,
                                       "all_proxy": proxy.url, "no_proxy": ""}):
            gate._github("secret")("/x")
        self.assertEqual(proxy.requests, [])
        self.assertEqual(api.requests, [("/x", "Bearer secret")])

    def test_requests_carry_githubs_standard_headers(self):
        request = github_http.api_request(
            "/repos/o/r", "secret", "factory-test", method="POST", data=b"{}",
            headers={"Cache-Control": "no-cache"},
        )
        self.assertEqual(request.full_url, "https://api.github.com/repos/o/r")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.data, b"{}")
        self.assertEqual(
            {name.lower(): value for name, value in request.header_items()},
            {
                "accept": "application/vnd.github+json",
                "authorization": "Bearer secret",
                "user-agent": "factory-test",
                "x-github-api-version": "2022-11-28",
                "cache-control": "no-cache",
            },
        )
        self.assertEqual(github_http.api_request("/x", "t", "a").get_method(), "GET")

    def test_requests_off_the_api_host_are_never_sent(self):
        other = Server(self)
        host = other.url.removeprefix("http://")
        for url in (other.url, f"https://api.github.com@{host}/x",
                    f"http://api.github.com@{host}/x", "http://api.github.com/x",
                    "https://api.github.com.evil.test/x", "https://api.github.com:444/x",
                    "file:///etc/hosts"):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "GitHub API"):
                github_http.open_api(urllib.request.Request(url))
        self.assertEqual(other.requests, [])


if __name__ == "__main__":
    unittest.main()
