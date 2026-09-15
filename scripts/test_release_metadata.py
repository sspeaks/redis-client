import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("check-release-metadata.py")
SPEC = importlib.util.spec_from_file_location("check_release_metadata", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "hask-redis-mux").mkdir()
        self.write_package(
            self.root / "redis-client.cabal",
            "redis-client",
            "0.5.0.0",
        )
        self.write_package(
            self.root / "hask-redis-mux" / "hask-redis-mux.cabal",
            "hask-redis-mux",
            "0.2.0.0",
        )
        (self.root / "CHANGELOG.md").write_text(
            "# Revision history for redis-client\n\n"
            "## Unreleased\n\n"
            "## 0.5.0.0 -- 2026-02-05\n",
            encoding="utf-8",
        )
        (self.root / "hask-redis-mux" / "CHANGELOG.md").write_text(
            "# Revision history for hask-redis-mux\n\n"
            "## 0.2.0.0 -- Unreleased\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_package(self, path, package_name, version):
        path.write_text(
            "cabal-version: 3.0\n"
            f"name: {package_name}\n"
            f"version: {version}\n",
            encoding="utf-8",
        )

    def test_repository_validation_accepts_matching_versions(self):
        self.assertEqual(MODULE.validate_repository(self.root), [])

    def test_repository_validation_ignores_unreleased_heading(self):
        self.assertEqual(
            MODULE.latest_changelog_version(self.root / "CHANGELOG.md"),
            "0.5.0.0",
        )

    def test_repository_validation_rejects_mismatched_changelog(self):
        (self.root / "CHANGELOG.md").write_text(
            "# Revision history for redis-client\n\n## 0.6.0.0 -- 2026-02-05\n",
            encoding="utf-8",
        )
        self.assertIn(
            "changelog version 0.6.0.0 does not match cabal version 0.5.0.0",
            MODULE.validate_repository(self.root)[0],
        )

    def test_release_validation_rejects_unknown_tag_prefix(self):
        self.assertEqual(
            MODULE.validate_release(self.root, "v0.5.0.0"),
            ["release tag v0.5.0.0 must match exactly one known prefix"],
        )

    def test_redis_client_release_requires_version_and_sha_tags(self):
        self.assertEqual(
            MODULE.validate_release(
                self.root,
                "redis-client-v0.5.0.0",
                commit_sha="abcdef1234567890",
                docker_tags=["0.5.0.0", "sha-abcdef123456"],
            ),
            [],
        )

    def test_redis_client_release_rejects_unapproved_latest_tag(self):
        self.assertEqual(
            MODULE.validate_release(
                self.root,
                "redis-client-v0.5.0.0",
                commit_sha="abcdef1234567890",
                docker_tags=["0.5.0.0", "sha-abcdef123456", "latest"],
            ),
            [
                "Docker tag latest requires --allow-latest so it is only used intentionally"
            ],
        )

    def test_library_release_rejects_docker_tags(self):
        self.assertEqual(
            MODULE.validate_release(
                self.root,
                "hask-redis-mux-v0.2.0.0",
                docker_tags=["0.2.0.0"],
            ),
            ["hask-redis-mux releases must not declare Docker tags"],
        )


if __name__ == "__main__":
    unittest.main()
