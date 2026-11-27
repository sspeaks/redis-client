import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import check_proof

LIBDIR = "/nix/store/" + "0a" * 16 + "-ghc-9.8.4-with-packages/lib/ghc-9.8.4/lib"
# Blob ids from `git hash-object`, not from the code under test.
PATCH = f"""diff --git a/factory-proof.txt b/factory-proof.txt
new file mode 100644
index {"0" * 40}..BLOB
--- /dev/null
+++ b/factory-proof.txt
@@ -0,0 +1 @@
+{LIBDIR}
"""


def blob(text):
    command = ["git", "hash-object", "--stdin"]
    return subprocess.run(command, input=text, text=True, capture_output=True).stdout.strip()


PATCH = PATCH.replace("BLOB", blob(LIBDIR + "\n"))
NO_NEWLINE = (
    PATCH.replace(blob(LIBDIR + "\n"), blob(LIBDIR)) + "\\ No newline at end of file\n"
)


class CheckProofTests(unittest.TestCase):
    def check(self, outcome="success", patch=PATCH, libdir=LIBDIR, fetched=10**9, host=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "result.json").write_text(json.dumps({"outcome": outcome}))
            if patch is not None:
                (root / "agent.patch").write_text(patch)
            event = {"kind": "tunnel", "host": host or "cache.nixos.org", "bytes": fetched}
            (root / "proxy-events.jsonl").write_text(
                json.dumps({"kind": "refused"}) + "\n" + json.dumps(event) + "\n"
            )
            return check_proof.failures(root, libdir)

    def test_accepts_the_completed_task(self):
        self.assertEqual(self.check(), [])
        self.assertEqual(self.check(patch=NO_NEWLINE), [])

    def test_rejects_incomplete_work(self):
        self.assertTrue(self.check(outcome="usage_limit"))
        self.assertTrue(self.check(patch=None))
        self.assertTrue(self.check(patch=""))

    def test_the_patch_must_be_exact(self):
        for patch in (
            PATCH.replace(LIBDIR, "done"),
            PATCH + PATCH.replace("factory-proof.txt", "Makefile"),
            PATCH.replace("b/factory-proof.txt\nnew", "x b/factory-proof.txt\nnew"),
            PATCH.replace("b/factory-proof.txt\nnew", "b/x b/factory-proof.txt\nnew"),
            PATCH + "+++ extra\n",
            PATCH.replace("@@ -0,0 +1 @@", "@@ -0,0 +1,2 @@") + "+++ extra\n",
            PATCH.replace("100644", "100755"),
            PATCH + "\n",
            " " + PATCH,
        ):
            self.assertTrue(self.check(patch=patch), patch)

    def test_the_agents_word_is_not_enough(self):
        self.assertTrue(self.check(libdir=LIBDIR.replace("0a", "0b")))
        self.assertTrue(self.check(libdir=""))
        self.assertTrue(self.check(fetched=1000))
        self.assertTrue(self.check(host="hackage.haskell.org"))

    def test_the_independent_answer_must_be_a_store_path(self):
        patch = PATCH.replace(LIBDIR, "9.8.4")
        self.assertTrue(self.check(libdir="9.8.4", patch=patch))

    def test_findings_never_repeat_agent_text(self):
        evil = PATCH.replace("factory-proof.txt", "::error::x").replace(LIBDIR, "::add-mask::y")
        self.assertNotIn("::", "\n".join(self.check(patch=evil)))


if __name__ == "__main__":
    unittest.main()
