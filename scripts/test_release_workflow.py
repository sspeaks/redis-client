import re
import unittest
from pathlib import Path


WORKFLOW = (
    Path(__file__).parents[1] / ".github" / "workflows" / "docker-publish.yml"
)


class ReleaseWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_both_namespaced_package_tags_trigger_the_workflow(self):
        self.assertIn('- "redis-client-v*"', self.workflow)
        self.assertIn('- "hask-redis-mux-v*"', self.workflow)

    def test_every_package_tag_creates_a_namespaced_github_release(self):
        self.assertIn("publish-github-release:", self.workflow)
        self.assertIn(
            'gh release create "$GITHUB_REF_NAME"', self.workflow
        )
        self.assertIn('cabal sdist "pkg:$PACKAGE_NAME"', self.workflow)
        self.assertIn("--notes-file release-notes.md", self.workflow)

    def test_release_builds_use_only_the_locked_flake(self):
        self.assertIn(
            "nix develop --no-update-lock-file --no-write-lock-file",
            self.workflow,
        )
        self.assertIn(
            "nix build --no-update-lock-file --no-write-lock-file .#dockerImage",
            self.workflow,
        )
        self.assertNotIn("nix_path:", self.workflow)
        self.assertNotIn("channel:", self.workflow)
        self.assertNotIn("nix-build", self.workflow)
        self.assertNotIn("default.nix", self.workflow)

    def test_only_cli_tags_can_publish_ghcr(self):
        docker_job = self.workflow.split("  publish-docker:", 1)[1]
        self.assertRegex(
            docker_job,
            re.compile(
                r"if:\s+needs\.verify-release\.outputs\.package_name "
                r"== 'redis-client'"
            ),
        )
        self.assertIn(
            "ghcr.io/sspeaks/redis-client:${{ needs.verify-release.outputs.package_version }}",
            docker_job,
        )
        self.assertIn(
            "ghcr.io/sspeaks/redis-client:${{ needs.verify-release.outputs.docker_sha_tag }}",
            docker_job,
        )
        self.assertIn("ghcr.io/sspeaks/redis-client:latest", docker_job)

    def test_library_validation_declares_no_docker_metadata(self):
        library_case = self.workflow.split("hask-redis-mux)", 1)[1].split(
            ";;", 1
        )[0]
        self.assertNotIn("--docker-tag", library_case)
        self.assertNotIn("--commit-sha", library_case)

    def job(self, name):
        match = re.search(
            rf"^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)",
            self.workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing job {name}")
        return match.group(1)

    def test_only_the_known_jobs_exist(self):
        jobs = self.workflow.split("\njobs:\n", 1)[1]
        self.assertEqual(
            re.findall(r"^  ([\w-]+):", jobs, re.MULTILINE),
            ["verify-release", "publish-github-release", "publish-docker"],
        )

    def test_publishing_jobs_wait_for_release_approval(self):
        for name in ("publish-github-release", "publish-docker"):
            with self.subTest(job=name):
                self.assertRegex(
                    self.job(name),
                    re.compile(r"^    environment: release$", re.MULTILINE),
                )
                self.assertIn("    needs: verify-release\n", self.job(name))

    def test_metadata_verification_is_ungated_and_cannot_write(self):
        job = self.job("verify-release")
        self.assertNotIn("environment:", job)
        self.assertNotIn(": write", job)

    def test_verification_rejects_an_unprotected_release_environment(self):
        job = self.job("verify-release")
        self.assertIn('"repos/$GITHUB_REPOSITORY/environments/release" > ', job)
        self.assertIn("scripts/check-release-environment.py", job)
        self.assertIn("      actions: read\n", job)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("always()", self.workflow)


if __name__ == "__main__":
    unittest.main()
