import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import commit_id
import performance_gate
import publish
import secret_scan

FULL = "0123456789abcdef0123456789abcdef01234567"


class CommitIdTests(unittest.TestCase):
    def test_only_a_full_lower_case_commit_id_is_one(self):
        self.assertTrue(commit_id.is_commit_id(FULL))
        for value in (FULL.upper(), FULL[:-1], FULL + "8", FULL[:-1] + "g", f"{FULL}\n",
                      f" {FULL}", None, 1, b"0" * 40):
            with self.subTest(value=value):
                self.assertFalse(commit_id.is_commit_id(value))

    def test_publisher_accepts_the_same_ids(self):
        for value in (FULL, FULL.upper(), FULL[:-1], f"{FULL}\n", None):
            with self.subTest(value=value):
                self.assertEqual(publish._is_sha(value), commit_id.is_commit_id(value))

    def test_secret_scan_finds_commit_ids_only_standing_alone(self):
        self.assertEqual(secret_scan.COMMIT.findall(f"see {FULL}."), [FULL])
        self.assertEqual(secret_scan.COMMIT.findall(f"x{FULL} {FULL}0 {FULL.upper()}"), [])

    def test_baseline_refuses_anything_else(self):
        result = {"runs": [{"standalone/p99": {"head": {"samples": [1]}}}], "passed": True}
        for value in (FULL.upper(), FULL[:-1], f"{FULL}\n"):
            with self.subTest(value=value), self.assertRaises(performance_gate.GateError):
                performance_gate.store_baseline(None, "o/r", result, value, list)


if __name__ == "__main__":
    unittest.main()
