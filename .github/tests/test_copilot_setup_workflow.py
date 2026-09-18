#!/usr/bin/env python3

import re
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).parents[1] / "workflows" / "copilot-setup-steps.yml"
REQUIRED_JOB_ID = "copilot-setup-steps"
SELF_PATH = ".github/workflows/copilot-setup-steps.yml"
JOB_ID = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_-]*):\s*$")
TOP_LEVEL_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*$")


class CopilotSetupWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.lines = cls.workflow.splitlines()

    def test_uses_reserved_workflow_path(self):
        self.assertEqual(
            WORKFLOW.relative_to(WORKFLOW.parents[2]).as_posix(),
            ".github/workflows/copilot-setup-steps.yml",
        )

    def test_has_exactly_the_reserved_job(self):
        jobs_index = self.lines.index("jobs:")
        job_ids = []
        for line in self.lines[jobs_index + 1:]:
            if TOP_LEVEL_KEY.fullmatch(line):
                break
            if match := JOB_ID.fullmatch(line):
                job_ids.append(match.group(1))
        self.assertEqual(job_ids, [REQUIRED_JOB_ID])

    def test_reserved_job_has_runner_and_steps(self):
        job_start = self.lines.index(f"  {REQUIRED_JOB_ID}:")
        job_lines = []
        for line in self.lines[job_start + 1:]:
            if JOB_ID.fullmatch(line) or TOP_LEVEL_KEY.fullmatch(line):
                break
            job_lines.append(line)
        job = "\n".join(job_lines)
        self.assertRegex(job, r"(?m)^    runs-on:\s+\S")
        self.assertRegex(job, r"(?m)^    steps:\s*$")
        self.assertRegex(job, r"(?m)^    - (?:name:|uses:|run:)")

    def test_push_and_pull_request_watch_the_workflow(self):
        self.assertEqual(
            self.lines.count(f"      - {SELF_PATH}"),
            2,
        )


if __name__ == "__main__":
    unittest.main()
