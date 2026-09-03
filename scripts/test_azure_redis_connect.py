import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("azure-redis-connect.py")
SPEC = importlib.util.spec_from_file_location("azure_redis_connect", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

SYNTHETIC_JWT = (
    "eyJhbGciOiJub25lIn0."
    "eyJvaWQiOiJ0ZXN0LXVzZXJfMSJ9."
    "c2lnbmF0dXJlLXNhZmU"
)
SYNTHETIC_ACCESS_KEY = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-+/AbCd"


class AzureRedisCredentialTests(unittest.TestCase):
    def setUp(self):
        self.connector = MODULE.AzureRedisConnector("test-subscription")

    def test_redacts_url_safe_jwt_and_access_key(self):
        text = f"token={SYNTHETIC_JWT} key={SYNTHETIC_ACCESS_KEY}"
        redacted = self.connector.obfuscate_sensitive_data(text)
        self.assertNotIn(SYNTHETIC_JWT, redacted)
        self.assertNotIn(SYNTHETIC_ACCESS_KEY, redacted)
        self.assertEqual(redacted.count("***REDACTED***"), 2)

    @mock.patch.dict(os.environ, {"PRESERVED": "value"}, clear=True)
    def test_child_environment_carries_credential_without_modifying_argv(self):
        command = ["redis-client", "cli", "-h", "cache.example"]
        child_environment = self.connector.build_redis_client_environment(SYNTHETIC_JWT)
        self.assertNotIn(SYNTHETIC_JWT, command)
        self.assertEqual(child_environment[MODULE.PASSWORD_ENVIRONMENT_VARIABLE], SYNTHETIC_JWT)
        self.assertEqual(child_environment["PRESERVED"], "value")

    def test_saved_command_is_owner_only_and_contains_no_live_credential(self):
        command = ["redis-client", "cli", "-h", "cache.example"]
        with tempfile.TemporaryDirectory() as temp_directory:
            previous_directory = os.getcwd()
            os.chdir(temp_directory)
            try:
                filename = self.connector.save_command_file(
                    command, "cache/name", "cache.example", 6380
                )
                contents = Path(filename).read_text()
                mode = stat.S_IMODE(Path(filename).stat().st_mode)
            finally:
                os.chdir(previous_directory)

        self.assertEqual(mode, 0o700)
        self.assertNotIn(SYNTHETIC_JWT, contents)
        self.assertNotIn(SYNTHETIC_ACCESS_KEY, contents)
        self.assertIn(MODULE.PASSWORD_FILE_ENVIRONMENT_VARIABLE, contents)
        self.assertIn(MODULE.PASSWORD_ENVIRONMENT_VARIABLE, contents)

    def test_subprocess_failure_message_does_not_format_command_arguments(self):
        error = MODULE.subprocess.CalledProcessError(
            9, ["redis-client", "cli", "--password", SYNTHETIC_JWT]
        )
        self.assertIn(SYNTHETIC_JWT, str(error))
        safe_message = self.connector.format_redis_client_failure(error.returncode)
        self.assertNotIn(SYNTHETIC_JWT, safe_message)


if __name__ == "__main__":
    unittest.main()
