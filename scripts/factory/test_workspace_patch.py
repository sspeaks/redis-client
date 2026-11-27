import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
from workspace_patch import Baseline, PatchRefused


class WorkspacePatchTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.work, self.mark = self.root / "work", self.root / "executed"
        (self.work / "dir").mkdir(parents=True)
        (self.work / "a.txt").write_text("old\n")
        (self.work / "dir/b.txt").write_text("b\n")
        (self.work / ".gitignore").write_text("build/\nout/cache/\n*.log\n")
        (self.work / "LINK").symlink_to("a.txt")
        (self.work / "picture").write_bytes(b"\0\1")
        self.baseline = Baseline(self.root / "base", self.work)

    def patch(self):
        patch = self.baseline.patch()
        self.assertFalse(self.mark.exists(), "the host ran something from the workspace")
        return patch.decode()

    def assert_refused(self):
        with self.assertRaises(PatchRefused):
            self.baseline.patch()
        self.assertFalse(self.mark.exists(), "the host ran something from the workspace")

    def repository(self, path):
        def git(*arguments):
            subprocess.run(["git", "-C", str(path), *arguments], check=True, capture_output=True)

        git("init", "-q")
        script = self.root / "run.sh"
        script.write_text(f"#!/bin/sh\ntouch {self.mark}\ncat\n")
        script.chmod(0o755)
        git("config", "core.fsmonitor", str(script))
        git("config", "filter.x.clean", str(script))
        (path / ".gitattributes").write_text("* filter=x\n")

    def test_unchanged_workspace_gives_an_empty_patch(self):
        self.assertEqual(self.patch(), "")

    def test_changes_apply_to_the_sources(self):
        (self.work / "a.txt").write_text("new\n")
        (self.work / "c d.txt").write_text("added\n")
        (self.work / "dir/b.txt").unlink()
        script = self.work / "run.sh"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
        fresh = self.root / "fresh"
        (fresh / "dir").mkdir(parents=True)
        (fresh / "a.txt").write_text("old\n")
        (fresh / "dir/b.txt").write_text("b\n")
        subprocess.run(["git", "apply"], cwd=fresh, input=self.patch().encode(), check=True)
        self.assertEqual((fresh / "a.txt").read_text(), "new\n")
        self.assertEqual((fresh / "c d.txt").read_text(), "added\n")
        self.assertFalse((fresh / "dir/b.txt").exists())
        self.assertTrue(os.access(fresh / "run.sh", os.X_OK))

    def test_workspace_git_configuration_is_never_used(self):
        self.repository(self.work)
        (self.work / "a.txt").write_text("new\n")
        self.assertIn("+new", self.patch())

    def test_host_git_configuration_is_never_used(self):
        (self.work / ".gitattributes").write_text("* filter=x diff=x -text ident\n")
        (self.work / "a.txt").write_text("new $Id$\r\n")
        config = self.root / "config"
        config.write_text(
            f'[filter "x"]\nclean = "touch {self.mark}; cat"\n'
            f'[diff "x"]\ncommand = "touch {self.mark}"\n[core]\nautocrlf = true\n'
        )
        with mock.patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config), GIT_EXTERNAL_DIFF="false"):
            self.assertIn("+new $Id$\r\n", self.patch())

    def test_attributes_cannot_hide_a_change(self):
        (self.work / ".gitattributes").write_text("* -diff binary\n")
        (self.work / "a.txt").write_text("new\n")
        self.assertIn("+new", self.patch())

    def test_agent_ignore_rules_cannot_hide_a_file(self):
        (self.work / ".gitignore").write_text("*\n")
        (self.work / "hidden").write_text("payload\n")
        self.assertIn("+payload", self.patch())

    def test_source_ignore_rules_drop_build_output_unread(self):
        for path in ("build/sub", "out/cache"):
            (self.work / path).mkdir(parents=True)
            (self.work / path / "x").write_bytes(b"\0")
        (self.work / "build/.git").mkdir()
        (self.work / "build/l").symlink_to("/etc/passwd")
        (self.work / "x.log").write_text("log")
        self.assertEqual(self.patch(), "")

    def test_refuses_embedded_repositories(self):
        for name in ("sub", "dir"):
            with self.subTest(name):
                path = self.work / name
                path.mkdir(exist_ok=True)
                self.repository(path)
                self.assert_refused()
                (path / ".git").rename(path / ".GIT")
                self.assert_refused()
                subprocess.run(["rm", "-rf", str(path / ".GIT")], check=True)

    def test_refuses_symbolic_links(self):
        (self.work / "new").symlink_to("/etc/passwd")
        self.assert_refused()
        (self.work / "new").unlink()
        (self.work / "LINK").unlink()
        self.assert_refused()
        (self.work / "LINK").symlink_to("/etc/passwd")
        self.assert_refused()
        (self.work / "LINK").unlink()
        (self.work / "LINK").symlink_to("a.txt")
        (self.work / "dir/b.txt").unlink()
        (self.work / "dir").rmdir()
        (self.work / "dir").symlink_to("/etc")
        self.assert_refused()

    def test_refuses_binary_changes(self):
        for name, data in (("new", b"\0"), ("a.txt", b"\xff\xfe"), ("picture", b"text now")):
            with self.subTest(name):
                old = (self.work / name).read_bytes() if (self.work / name).exists() else None
                (self.work / name).write_bytes(data)
                self.assert_refused()
                (self.work / name).unlink()
                if old is not None:
                    (self.work / name).write_bytes(old)

    def test_refuses_special_unreadable_and_odd_files(self):
        os.mkfifo(self.work / "pipe")
        self.assert_refused()
        (self.work / "pipe").unlink()
        (self.work / "odd\nname").write_text("x")
        self.assert_refused()
        (self.work / "odd\nname").unlink()
        (self.work / "big").write_bytes(b"x" * (8 * 1024 * 1024 + 1))
        self.assert_refused()
        (self.work / "big").unlink()
        if os.getuid():
            (self.work / "secret").write_text("x")
            (self.work / "secret").chmod(0)
            self.assert_refused()

    def test_refuses_a_workspace_that_starts_as_a_repository(self):
        (self.work / ".git").mkdir()
        with self.assertRaises(PatchRefused):
            Baseline(self.root / "other", self.work)


if __name__ == "__main__":
    unittest.main()
