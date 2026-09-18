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
            self.root / "redis-client.cabal", "redis-client", "0.6.0.0"
        )
        self.write_package(
            self.root / "hask-redis-mux" / "hask-redis-mux.cabal",
            "hask-redis-mux",
            "0.3.0.0",
        )
        self.write_changelog(
            self.root / "CHANGELOG.md",
            "redis-client",
            "0.6.0.0",
            "Unreleased",
            "CLI changes.",
        )
        self.write_changelog(
            self.root / "hask-redis-mux" / "CHANGELOG.md",
            "hask-redis-mux",
            "0.3.0.0",
            "Unreleased",
            "Library changes.",
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

    def write_changelog(self, path, package_name, version, status, body):
        path.write_text(
            f"# Revision history for {package_name}\n\n"
            f"## {version} -- {status}\n\n"
            f"{body}\n\n"
            "## 0.1.0.0 -- 2025-01-01\n\nPrevious release.\n",
            encoding="utf-8",
        )

    def release(self, package_name, version, date="2026-09-18", body=None):
        path = (
            self.root / "CHANGELOG.md"
            if package_name == "redis-client"
            else self.root / "hask-redis-mux" / "CHANGELOG.md"
        )
        self.write_changelog(
            path, package_name, version, date, body or f"{package_name} changes."
        )

    def valid_cli_release(self, **overrides):
        arguments = {
            "commit_sha": "abcdef1234567890",
            "docker_tags": ["0.6.0.0", "sha-abcdef123456", "latest"],
            "allow_latest": True,
        }
        arguments.update(overrides)
        return MODULE.validate_release(
            self.root, "redis-client-v0.6.0.0", **arguments
        )

    def test_repository_accepts_versioned_unreleased_entries(self):
        self.assertEqual(MODULE.validate_repository(self.root), [])

    def test_repository_rejects_generic_unreleased_heading(self):
        (self.root / "CHANGELOG.md").write_text(
            "# Revision history for redis-client\n\n## Unreleased\n\nChanges.\n",
            encoding="utf-8",
        )
        self.assertIn(
            "top heading must name version 0.6.0.0",
            "\n".join(MODULE.validate_repository(self.root)),
        )

    def test_repository_rejects_cabal_changelog_mismatch(self):
        self.write_package(
            self.root / "redis-client.cabal", "redis-client", "0.7.0.0"
        )
        self.assertIn(
            "top changelog version 0.6.0.0 does not match cabal version 0.7.0.0",
            "\n".join(MODULE.validate_repository(self.root)),
        )

    def test_repository_rejects_empty_top_entry(self):
        self.write_changelog(
            self.root / "CHANGELOG.md",
            "redis-client",
            "0.6.0.0",
            "Unreleased",
            "",
        )
        self.assertIn(
            "top changelog entry is empty",
            "\n".join(MODULE.validate_repository(self.root)),
        )

    def test_release_rejects_unknown_and_malformed_tags(self):
        self.assertEqual(
            MODULE.validate_release(self.root, "v0.6.0.0"),
            ["release tag v0.6.0.0 must match exactly one known prefix"],
        )
        self.assertEqual(
            MODULE.validate_release(self.root, "redis-client-v0.6"),
            ["release tag redis-client-v0.6 must end with X.Y.Z.W"],
        )

    def test_release_rejects_unreleased_top_entry(self):
        self.assertIn(
            "version 0.6.0.0 is still Unreleased",
            "\n".join(self.valid_cli_release()),
        )

    def test_old_tag_cannot_publish_newer_unreleased_source(self):
        failures = MODULE.validate_release(
            self.root,
            "redis-client-v0.5.0.0",
            commit_sha="abcdef1234567890",
            docker_tags=["0.6.0.0", "sha-abcdef123456"],
        )
        self.assertIn("targets version 0.5.0.0", "\n".join(failures))
        self.assertIn(
            "version 0.6.0.0 is still Unreleased", "\n".join(failures)
        )

    def test_release_requires_a_date_not_an_arbitrary_status(self):
        self.release("redis-client", "0.6.0.0", date="ready")
        self.assertIn(
            "must use a YYYY-MM-DD release date",
            "\n".join(self.valid_cli_release()),
        )

    def test_cli_release_accepts_matching_metadata_and_docker_tags(self):
        self.release("redis-client", "0.6.0.0")
        self.assertEqual(self.valid_cli_release(), [])

    def test_cli_release_requires_version_sha_and_explicit_latest_tags(self):
        self.release("redis-client", "0.6.0.0")
        failures = self.valid_cli_release(
            docker_tags=["latest"], allow_latest=False
        )
        self.assertIn(
            "redis-client releases must publish Docker tag 0.6.0.0", failures
        )
        self.assertIn(
            "redis-client releases must publish Docker tag sha-abcdef123456",
            failures,
        )
        self.assertIn("Docker tag latest requires --allow-latest", failures[-1])

    def test_cli_release_rejects_unexpected_and_duplicate_docker_tags(self):
        self.release("redis-client", "0.6.0.0")
        failures = self.valid_cli_release(
            docker_tags=[
                "0.6.0.0",
                "sha-abcdef123456",
                "latest",
                "latest",
                "edge",
            ]
        )
        self.assertIn(
            "redis-client release declared unexpected Docker tag edge", failures
        )
        self.assertIn("redis-client release declared duplicate Docker tags", failures)

    def test_library_release_accepts_cli_remaining_unreleased(self):
        self.release("hask-redis-mux", "0.3.0.0")
        self.assertEqual(
            MODULE.validate_release(
                self.root, "hask-redis-mux-v0.3.0.0"
            ),
            [],
        )

    def test_library_release_rejects_docker_metadata(self):
        self.release("hask-redis-mux", "0.3.0.0")
        failures = MODULE.validate_release(
            self.root,
            "hask-redis-mux-v0.3.0.0",
            commit_sha="abcdef1",
            docker_tags=["0.3.0.0"],
            allow_latest=True,
        )
        self.assertEqual(len(failures), 3)
        self.assertTrue(all("Docker" in failure for failure in failures))

    def test_release_notes_include_only_the_tagged_top_entry(self):
        self.release(
            "hask-redis-mux",
            "0.3.0.0",
            body="First change.\n\n* Second change.",
        )
        self.assertEqual(
            MODULE.release_notes(self.root, "hask-redis-mux-v0.3.0.0"),
            "## hask-redis-mux 0.3.0.0\n\nFirst change.\n\n* Second change.\n",
        )

    def test_cli_release_notes_do_not_require_docker_publication_arguments(self):
        self.release("redis-client", "0.6.0.0", body="CLI release.")
        self.assertEqual(
            MODULE.release_notes(self.root, "redis-client-v0.6.0.0"),
            "## redis-client 0.6.0.0\n\nCLI release.\n",
        )


if __name__ == "__main__":
    unittest.main()
