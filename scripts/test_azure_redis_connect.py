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

    def test_cluster_fill_display_and_generated_command_share_one_preset(self):
        cache = self.cache.copy()
        cache["shardCount"] = 3
        stdout = io.StringIO()
        with mock.patch.object(
            self.connector, "check_entra_auth", return_value=False
        ), mock.patch.object(
            self.connector, "get_access_key", return_value=SYNTHETIC_ACCESS_KEY
        ), mock.patch(
            "builtins.input", side_effect=["1", "y", "n"]
        ), mock.patch.object(
            MODULE.subprocess, "run"
        ) as run, redirect_stdout(stdout):
            self.connector.launch_redis_client(cache, "fill")

        command = run.call_args.args[0]
        output = stdout.getvalue()
        self.assertIn("-f", command)
        self.assertIn("-c", command)
        for label, flag, value, unit in MODULE.CLUSTER_FILL_PRESET_OPTIONS:
            flag_index = command.index(flag)
            self.assertEqual(command[flag_index + 1], str(value))
            self.assertIn(
                f"- {label}: {value:,}{unit} ({flag} {value})",
                output,
            )
        self.assertIn(
            f"Launching redis-client with command:\n  {MODULE.shlex.join(command)}",
            output,
        )
        self.assertIn(
            "One connection per primary keeps clusters with up to 32 primaries",
            output,
        )

    def test_cluster_fill_preset_stays_within_worker_limit_at_high_primary_counts(self):
        arguments = MODULE.fill_preset_arguments(clustered=True)
        process_count = int(arguments[arguments.index("-P") + 1])
        connections_per_primary = int(arguments[arguments.index("-n") + 1])

        for primary_count in (16, 17, 24, 32):
            with self.subTest(primary_count=primary_count):
                self.assertLessEqual(
                    process_count * primary_count * connections_per_primary,
                    32,
                )

    def test_enterprise_fill_uses_the_bounded_cluster_preset_without_shard_metadata(self):
        cache = self.cache.copy()
        cache.update({"cache_type": "Enterprise", "resourceGroup": "test-rg"})
        stdout = io.StringIO()
        with mock.patch.object(
            self.connector,
            "get_enterprise_database",
            return_value={"name": "default", "port": 10000},
        ), mock.patch.object(
            self.connector, "check_entra_auth", return_value=False
        ), mock.patch.object(
            self.connector, "get_access_key", return_value=SYNTHETIC_ACCESS_KEY
        ), mock.patch(
            "builtins.input", side_effect=["1", "n", "n"]
        ), mock.patch.object(
            MODULE.subprocess, "run"
        ) as run, redirect_stdout(stdout):
            self.connector.launch_redis_client(cache, "fill")

        command = run.call_args.args[0]
        self.assertIn("-c", command)
        self.assertEqual(command[command.index("-P") + 1], "1")
        self.assertEqual(command[command.index("-n") + 1], "1")
        self.assertIn(
            "One connection per primary keeps clusters with up to 32 primaries",
            stdout.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
