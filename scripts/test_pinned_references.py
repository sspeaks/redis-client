#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("check-pinned-references.py")
SPEC = importlib.util.spec_from_file_location("check_pinned_references", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

ACTION_SHA = "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
IMAGE_DIGEST = "71da9275c5f3fcb97d0fa0c8c5b36cc995327265420f17a04bfd544f458059f7"


class PinnedReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / ".github" / "workflows").mkdir(parents=True)
        (self.root / "docker" / "cluster").mkdir(parents=True)
        self.workflow = self.root / ".github" / "workflows" / "test.yml"
        self.compose = self.root / "docker" / "docker-compose.yml"
        self.script = self.root / "docker" / "cluster" / "create.sh"
        self.write_valid_fixture()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_valid_fixture(self):
        self.workflow.write_text(
            f"- uses: actions/checkout@{ACTION_SHA} # v5\n- uses: ./local-action\n",
            encoding="utf-8",
        )
        self.compose.write_text(
            "services:\n"
            f"  redis:\n    image: redis:7@sha256:{IMAGE_DIGEST}\n"
            "  test:\n"
            '    image: "${REDIS_E2E_IMAGE:-e2etests:latest}"\n',
            encoding="utf-8",
        )
        self.script.write_text(
            f"docker run redis:7@sha256:{IMAGE_DIGEST} redis-cli ping\n",
            encoding="utf-8",
        )

    def failures(self):
        failures = []
        MODULE.validate_actions(self.root, failures)
        MODULE.validate_compose_images(self.root, failures)
        MODULE.validate_redis_docker_commands(self.root, failures)
        return failures

    def test_accepts_pinned_external_and_local_references(self):
        self.assertEqual(self.failures(), [])

    def test_rejects_mutable_action_reference(self):
        self.workflow.write_text("- uses: actions/checkout@v5\n", encoding="utf-8")
        self.assertIn("mutable action reference actions/checkout@v5", self.failures()[0])

    def test_rejects_mutable_compose_image(self):
        self.compose.write_text("services:\n  redis:\n    image: redis:7\n", encoding="utf-8")
        self.assertIn("unpinned external image redis:7", self.failures()[0])

    def test_rejects_mutable_redis_docker_command(self):
        self.script.write_text("docker run redis redis-cli ping\n", encoding="utf-8")
        self.assertIn("unpinned external image redis", self.failures()[0])


if __name__ == "__main__":
    unittest.main()
