import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "factory-proof.yml"


class ProofWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.jobs = dict(
            re.findall(r"^  (verify|proof):\n(.*?)(?=^  \w+:\n|\Z)", self.text, re.M | re.S)
        )

    def step(self, name):
        job = self.jobs["proof"]
        (found,) = re.findall(
            rf"^      - (?:name: {name}|uses: {name})\n(.*?)(?=^      - |\Z)", job, re.M | re.S
        )
        return found

    def test_each_job_refuses_a_rerun_before_anything_else(self):
        self.assertEqual(set(self.jobs), {"verify", "proof"})
        for name, job in self.jobs.items():
            refusals = [m.start() for m in re.finditer(r'test "\$GITHUB_RUN_ATTEMPT" = 1', job)]
            self.assertEqual(len(refusals), 1, name)
            for later in ("actions/checkout", "docker ", "python3 ", "gh api", "secrets.CLAUDE"):
                at = job.find(later)
                if at >= 0 and not (name == "verify" and later.startswith("secrets.")):
                    self.assertLess(refusals[0], at, (name, later))

    def test_starts_only_by_hand(self):
        triggers = re.search(r"^on:\n(.*?)^\w", self.text, re.M | re.S).group(1)
        self.assertEqual(re.findall(r"^  (\w+):", triggers, re.M), ["workflow_dispatch"])

    def test_uploads_only_after_the_token_search_finished(self):
        condition = re.search(r"^        if: (.*)$", self.step("Upload the evidence"), re.M)
        self.assertEqual(
            condition.group(1), "always() && steps.agent.outputs.searched == 'true'"
        )
        self.assertEqual(self.text.count("upload-artifact@"), 1)

    def test_the_token_is_in_the_agent_step_only(self):
        self.assertIn("secrets.CLAUDE_CODE_OAUTH_TOKEN }}", self.step("factory-agent-run"))
        self.assertEqual(self.text.count("secrets.CLAUDE_CODE_OAUTH_TOKEN }}"), 1)
        self.assertIn("environment: factory-model", self.jobs["proof"])
        self.assertIn("needs: verify", self.jobs["proof"])


if __name__ == "__main__":
    unittest.main()
