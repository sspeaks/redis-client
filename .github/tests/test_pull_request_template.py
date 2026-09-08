#!/usr/bin/env python3

import re
import unittest
from pathlib import Path


TEMPLATE = Path(__file__).parents[1] / "pull_request_template.md"
REQUIRED_ROWS = (
    "Public API and exports",
    "Keyed paths",
    "Keyless paths",
    "Standalone paths",
    "Cluster paths",
    "Reconnect behavior",
    "Redirect behavior",
    "Live-fixture needs",
    "Required specialist reviewers",
    "Intentionally untested paths",
    "Nix-first build",
    "Targeted tests",
    "Full `make test`",
    "Profiling",
)


class PullRequestTemplateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = TEMPLATE.read_text(encoding="utf-8")
        cls.rows = {
            cells[0]: cells[1]
            for line in cls.template.splitlines()
            if len(cells := [cell.strip() for cell in line.strip().strip("|").split("|")])
            == 2
        }

    def test_uses_the_discoverable_github_template_location(self):
        self.assertEqual(TEMPLATE.relative_to(TEMPLATE.parents[1]).as_posix(),
                         ".github/pull_request_template.md")

    def test_has_cross_cutting_and_low_ceremony_narrow_change_modes(self):
        self.assertRegex(
            self.template,
            r"- \[ \] \*\*Cross-cutting change:\*\*",
        )
        self.assertRegex(
            self.template,
            r"- \[ \] \*\*Narrow or docs-only change:\*\*.*entire matrix is "
            r"\*\*N/A\*\*.*no additional N/A explanation is required",
        )

    def test_every_required_prompt_is_a_two_column_row_with_na_support(self):
        self.assertEqual(set(REQUIRED_ROWS), set(self.rows) - {"Path or gate", "---"})
        for prompt in REQUIRED_ROWS:
            with self.subTest(prompt=prompt):
                self.assertRegex(self.rows[prompt], re.compile(r"\bN/A\b"))


if __name__ == "__main__":
    unittest.main()
