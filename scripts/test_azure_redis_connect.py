import importlib.util
import io
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("azure-redis-connect.py")
SPEC = importlib.util.spec_from_file_location("azure_redis_connect", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

SYNTHETIC_JWT_HEADER = "eyJhbGciOiJub25lIn0_"
SYNTHETIC_JWT_CLAIMS = "eyJvaWQiOiJ0ZXN0LXVzZXJfMSJ9-_"
SYNTHETIC_JWT_SIGNATURE = "c2lnbmF0dXJlLXNhZmU_-"
SYNTHETIC_JWT = ".".join(
    [SYNTHETIC_JWT_HEADER, SYNTHETIC_JWT_CLAIMS, SYNTHETIC_JWT_SIGNATURE]
)
SYNTHETIC_ACCESS_KEY = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-+/AbCd"


class AzureRedisCredentialTests(unittest.TestCase):
    def setUp(self):
        self.connector = MODULE.AzureRedisConnector("test-subscription")
        self.cache = {
            "name": "test-cache",
            "cache_type": "Standard",
            "hostName": "cache.example",
            "sslPort": 6380,
        }

    def entra_launch_patches(self):
        return (
            mock.patch.object(self.connector, "check_entra_auth", return_value=True),
            mock.patch.object(
                self.connector,
                "get_entra_token",
                return_value=(SYNTHETIC_JWT, "entra-object-id"),
            ),
        )

    def test_redacts_url_safe_jwt_and_access_key(self):
        text = f"token={SYNTHETIC_JWT} key={SYNTHETIC_ACCESS_KEY}"
        redacted = self.connector.obfuscate_sensitive_data(text)
        self.assertNotIn(SYNTHETIC_JWT, redacted)
        self.assertNotIn(SYNTHETIC_JWT_CLAIMS, redacted)
        self.assertNotIn(SYNTHETIC_ACCESS_KEY, redacted)
        self.assertEqual(redacted.count("***REDACTED***"), 2)

    @mock.patch.dict(os.environ, {"PRESERVED": "value"}, clear=True)
    def test_child_environment_carries_credential_without_modifying_argv(self):
        command = ["redis-client", "cli", "-h", "cache.example"]
        child_environment = self.connector.build_redis_client_environment(SYNTHETIC_JWT)
        self.assertNotIn(SYNTHETIC_JWT, command)
        self.assertEqual(
            child_environment[MODULE.PASSWORD_ENVIRONMENT_VARIABLE],
            SYNTHETIC_JWT,
        )
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

    @mock.patch.dict(os.environ, {"PRESERVED": "value"}, clear=True)
    def test_launch_passes_credential_only_in_child_environment(self):
        check_auth, get_token = self.entra_launch_patches()
        with check_auth, get_token, \
             mock.patch("builtins.input", return_value="n"), \
             mock.patch.object(MODULE.subprocess, "run") as run, \
             redirect_stdout(io.StringIO()):
            self.connector.launch_redis_client(self.cache.copy(), "cli")

        run.assert_called_once()
        command = run.call_args.args[0]
        child_environment = run.call_args.kwargs["env"]
        self.assertNotIn(SYNTHETIC_JWT, command)
        self.assertNotIn("--password", command)
        self.assertNotIn("-a", command)
        self.assertEqual(
            child_environment[MODULE.PASSWORD_ENVIRONMENT_VARIABLE],
            SYNTHETIC_JWT,
        )
        self.assertEqual(child_environment["PRESERVED"], "value")
        self.assertTrue(run.call_args.kwargs["check"])

    def test_launch_failure_emits_no_command_or_credential(self):
        child_error = MODULE.subprocess.CalledProcessError(
            9, ["redis-client", "cli", "--password", SYNTHETIC_JWT]
        )
        check_auth, get_token = self.entra_launch_patches()
        stderr = io.StringIO()
        with check_auth, get_token, \
             mock.patch("builtins.input", return_value="n"), \
             mock.patch.object(MODULE.subprocess, "run", side_effect=child_error), \
             redirect_stdout(io.StringIO()), \
             redirect_stderr(stderr), \
             self.assertRaises(SystemExit) as exit_context:
            self.connector.launch_redis_client(self.cache.copy(), "cli")

        error_output = stderr.getvalue()
        self.assertEqual(exit_context.exception.code, 1)
        self.assertNotIn(SYNTHETIC_JWT, error_output)
        self.assertNotIn(SYNTHETIC_JWT_CLAIMS, error_output)
        self.assertNotIn("--password", error_output)
        self.assertNotIn("cache.example", error_output)
        self.assertEqual(
            error_output.strip(),
            "Error running redis-client (exit code 9)",
        )

    def test_launch_save_path_receives_and_writes_only_credential_free_command(self):
        with tempfile.TemporaryDirectory() as temp_directory:
            previous_directory = os.getcwd()
            os.chdir(temp_directory)
            try:
                check_auth, get_token = self.entra_launch_patches()
                with check_auth, get_token, \
                     mock.patch("builtins.input", return_value="y"), \
                     mock.patch.object(
                         self.connector,
                         "save_command_file",
                         wraps=self.connector.save_command_file,
                     ) as save_command, \
                     mock.patch.object(MODULE.subprocess, "run"), \
                     redirect_stdout(io.StringIO()):
                    self.connector.launch_redis_client(self.cache.copy(), "cli")

                saved_command = save_command.call_args.args[0]
                saved_file = next(Path(temp_directory).glob("redis-command_*.sh"))
                contents = saved_file.read_text()
            finally:
                os.chdir(previous_directory)

        self.assertNotIn(SYNTHETIC_JWT, saved_command)
        self.assertNotIn("--password", saved_command)
        self.assertNotIn("-a", saved_command)
        self.assertNotIn(SYNTHETIC_JWT, contents)
        self.assertNotIn(SYNTHETIC_JWT_CLAIMS, contents)
        self.assertIn("exec redis-client cli -h cache.example", contents)


if __name__ == "__main__":
    unittest.main()
