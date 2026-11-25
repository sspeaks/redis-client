import marshal
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent / "container"))
import probe

SANDBOX_SOURCES = {
    "check_proof.py", "entrypoint.py", "model_request.py", "probe.py", "proxy.py",
    "run_agent.py", "test_check_proof.py", "test_probe.py", "test_proof_workflow.py",
    "test_proxy.py", "test_run_agent.py", "test_workspace_patch.py", "workspace_patch.py",
}  # fmt: skip


def dummy(prefix, fill="a"):
    """A pretend token. Built when called, so that no source or compiled file holds one."""
    return prefix + fill * 40


CANARIES = [
    dummy(prefix)
    for prefix in (
        "sk-ant-" + "oat01-",
        "sk-ant-" + "api03-",
        "ghp" + "_",
        "ghs" + "_",
        "github" + "_pat_",
        "AUTHORIZATION: " + "basic ",
        "Authorization: " + "Basic ",
    )
]


class ProbeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def test_clean_tree_passes(self):
        (self.root / "a").write_text("sk-ant-oat placeholder and ghp_short")
        self.assertEqual(probe.scan_files(self.root, frozenset()), [])

    def test_finds_every_token_kind_in_files_without_printing_it(self):
        for canary in CANARIES:
            (self.root / "f").write_text(f"x={canary}\n")
            found = probe.scan_files(self.root, frozenset())
            self.assertEqual(len(found), 1, canary)
            self.assertNotIn(canary, found[0])

    def test_finds_a_token_split_across_read_blocks(self):
        (self.root / "f").write_bytes(b"." * (probe.BLOCK - 10) + CANARIES[0].encode())
        self.assertEqual(len(probe.scan_files(self.root, frozenset())), 1)

    def test_prefilter_never_changes_the_answer(self):
        kinds = ["sk-ant-" + kind + "01-" for kind in ("oat", "ort", "api", "admin", "sid")]
        kinds += ["gh" + kind + "_" for kind in "pousr"]
        kinds += ["github" + "_pat_", "AUTHORIZATION: " + "basic "]
        for kind in kinds:
            for spelled in (kind, kind.lower(), kind.upper(), kind.swapcase(), kind.title()):
                data = b"\xff\0x" + spelled.encode() + b"a" * 40 + b"\n"
                self.assertTrue(probe.TOKEN.search(data), spelled)
                self.assertTrue(probe.has_token(data), spelled)
            self.assertFalse(probe.has_token(kind.encode() + b"a" * 5), kind)

    def test_finds_a_token_at_every_offset_around_a_block_edge(self):
        for canary in CANARIES:
            for before in range(0, len(canary) + 1, 3):
                with mock.patch.object(probe, "BLOCK", 1024):
                    (self.root / "f").write_bytes(b"." * (1024 - before) + canary.encode() + b".")
                    self.assertEqual(
                        len(probe.scan_files(self.root, frozenset())), 1, (canary, before)
                    )

    def test_sandbox_sources_hold_no_token_even_when_compiled(self):
        for path in Path(__file__).parent.rglob("*.py"):
            if path.name not in SANDBOX_SOURCES:
                continue
            source = path.read_bytes()
            self.assertFalse(probe.has_token(source), path.name)
            for level in (0, 2):
                code = marshal.dumps(compile(source, str(path), "exec", optimize=level))
                self.assertFalse(probe.has_token(code), path.name)

    def test_finds_unexpected_sockets(self):
        path = self.root / "docker.sock"
        server = socket.socket(socket.AF_UNIX)
        self.addCleanup(server.close)
        server.bind(str(path))
        self.assertEqual(len(probe.scan_files(self.root, frozenset())), 1)
        self.assertEqual(probe.scan_files(self.root, frozenset({str(path)})), [])

    def test_searches_every_process_environment_and_command_line(self):
        for name, kind in (("environ", "1"), ("cmdline", "2")):
            (self.root / kind).mkdir()
            (self.root / kind / name).write_bytes(b"A=" + CANARIES[2].encode() + b"\0")
        (self.root / "1" / "cmdline").write_bytes(b"init\0")
        (self.root / "2" / "environ").write_bytes(b"PATH=/bin\0")
        self.assertEqual(len(probe.scan_processes(self.root)), 2)

    def test_forbidden_variable_names_fail_whatever_their_value(self):
        (self.root / "1").mkdir()
        (self.root / "1" / "environ").write_bytes(b"ANTHROPIC_API_KEY=\0GITHUB_TOKEN=x\0")
        (self.root / "1" / "cmdline").write_bytes(b"")
        self.assertEqual(len(probe.scan_processes(self.root)), 2)

    def test_no_processes_is_a_failure_not_a_pass(self):
        self.assertTrue(probe.scan_processes(self.root))

    def test_network_probe_reports_reachable_forbidden_and_unreachable_allowed_hosts(self):
        answers = {"bad.example": 200, "good.example": 403}
        found = probe.check_egress(answers.get, ["good.example"], ["bad.example"])
        self.assertEqual(len(found), 2)
        answers = {"bad.example": 403, "good.example": 200}
        self.assertEqual(probe.check_egress(answers.get, ["good.example"], ["bad.example"]), [])

    def test_broken_proxy_does_not_count_as_blocking(self):
        self.assertEqual(len(probe.check_egress(lambda _: None, [], ["bad.example"])), 1)

    def test_tunnel_probe_needs_real_tls_and_refused_alternatives(self):
        def only(*accepted):
            return probe.check_tunnel_binding(lambda name: name in accepted)

        self.assertEqual(only("cache.nixos.org"), [])
        self.assertEqual(len(only()), 1)
        self.assertEqual(len(only("cache.nixos.org", "example.com", None)), 2)

    def test_model_probe_accepts_only_an_explicit_refusal(self):
        for answer, count in ((403, 0), (None, 2), (200, 2), (404, 2)):
            found = probe.check_model_route(lambda *_: answer)
            self.assertEqual(len(found), count)

    def test_direct_connection_probe_detects_a_route(self):
        server = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(server.close)
        self.assertTrue(probe.can_connect(*server.getsockname()))

    def test_forbidden_hosts_cover_the_boundary(self):
        for host in ("api.anthropic.com", "github.com", "api.github.com", "example.com"):
            self.assertIn(host, probe.FORBIDDEN_HOSTS)


if __name__ == "__main__":
    unittest.main()
