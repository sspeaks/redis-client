#!/usr/bin/env python3

import copy
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/generate-redis-command-metadata.py"
SNAPSHOT = ROOT / "hask-redis-mux/data/redis-command-metadata.json"
CANONICAL_SOURCE = ROOT / "hask-redis-mux/data/redis-7.2.0-commands.json"
OUTPUT = ROOT / "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Internal/CommandMetadata.hs"
CABAL = ROOT / "hask-redis-mux/hask-redis-mux.cabal"
WORK = ROOT / ".metadata-audit-test-work"


def load_generator():
    spec = importlib.util.spec_from_file_location("command_metadata_generator", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load_generator()


class CommandMetadataAuditSpec(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shutil.rmtree(WORK, ignore_errors=True)
        WORK.mkdir()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(WORK, ignore_errors=True)

    def write_snapshot(self, name, mutate):
        value = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        mutate(value)
        path = WORK / name
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def audit(self, snapshot, output=OUTPUT, canonical_source=None):
        command = [sys.executable, str(SCRIPT), "--audit", "--snapshot", str(snapshot), "--output", str(output)]
        if canonical_source is not None:
            command.extend(["--canonical-source", str(canonical_source)])
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_audit_fails(self, snapshot, reason, **kwargs):
        result = self.audit(snapshot, **kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stderr)

    def test_audits_checked_in_snapshot_and_generated_module(self):
        self.assertEqual(self.audit(SNAPSHOT).returncode, 0)

    def test_rejects_snapshot_digest_mismatch(self):
        path = self.write_snapshot("bad-digest.json", lambda value: value["provenance"].update(commands_sha256="0" * 64))
        self.assert_audit_fails(path, "snapshot command digest mismatch")

    def test_rejects_source_digest_mismatch(self):
        path = self.write_snapshot("bad-source-digest.json", lambda value: value["provenance"].update(source_sha256="0" * 64))
        self.assert_audit_fails(path, "provenance source_sha256 is not bound")

    def test_rejects_canonical_source_digest_mismatch(self):
        bundle = WORK / "bad-canonical-source.json"
        source = json.loads(CANONICAL_SOURCE.read_text(encoding="utf-8"))
        source["audit_note"] = "tampered"
        bundle.write_text(json.dumps(source, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.assert_audit_fails(SNAPSHOT, "canonical source digest mismatch", canonical_source=bundle)

    def test_rejects_unbound_or_malformed_commit(self):
        unbound = self.write_snapshot(
            "unbound-commit.json",
            lambda value: value["provenance"].update(redis_commit="0" * 40),
        )
        malformed = self.write_snapshot(
            "malformed-commit.json",
            lambda value: value["provenance"].update(redis_commit="not-a-sha"),
        )
        self.assert_audit_fails(unbound, "provenance redis_commit is not bound")
        self.assert_audit_fails(malformed, "provenance redis_commit must be a full SHA")

    def test_rejects_unbound_source_url_and_path(self):
        source_url = self.write_snapshot(
            "unbound-source-url.json",
            lambda value: value["provenance"].update(source_url="https://example.invalid/commands"),
        )
        source_path = self.write_snapshot(
            "unbound-source-path.json",
            lambda value: value["provenance"].update(source_path="commands.json"),
        )
        self.assert_audit_fails(source_url, "provenance source_url is not bound")
        self.assert_audit_fails(source_path, "provenance source_path is not bound")

    def test_rejects_missing_or_malformed_retrieval_date(self):
        missing = self.write_snapshot("missing-retrieved-at.json", lambda value: value["provenance"].pop("retrieved_at"))
        malformed = self.write_snapshot(
            "malformed-retrieved-at.json",
            lambda value: value["provenance"].update(retrieved_at="September 4, 2026"),
        )
        self.assert_audit_fails(missing, "provenance retrieved_at is missing")
        self.assert_audit_fails(malformed, "provenance retrieved_at must be an ISO calendar date")

    def test_rejects_generated_drift(self):
        output = WORK / "drift.hs"
        output.write_text("drift\n", encoding="utf-8")
        self.assert_audit_fails(SNAPSHOT, "generated module drift", output=output)

    def test_rejects_duplicate_identity(self):
        path = self.write_snapshot("duplicate.json", lambda value: value["commands"].insert(1, copy.deepcopy(value["commands"][0])))
        self.assert_audit_fails(path, "duplicate command identity")

    def test_rejects_unsupported_key_spec_schema(self):
        def mutate(value):
            spec = next(command["metadata"]["key_specs"][0] for command in value["commands"] if command["metadata"]["key_specs"])
            spec["begin_search"] = {"unsupported": {}}
        path = self.write_snapshot("unsupported.json", mutate)
        self.assert_audit_fails(path, "begin_search has unexpected field unsupported")

    def test_rejects_invalid_key_spec_bounds(self):
        def first_range(value):
            return next(
                spec["find_keys"]["range"]
                for command in value["commands"]
                for spec in command["metadata"]["key_specs"]
                if "range" in spec["find_keys"]
            )

        def first_keynum(value):
            return next(
                spec["find_keys"]["keynum"]
                for command in value["commands"]
                for spec in command["metadata"]["key_specs"]
                if "keynum" in spec["find_keys"]
            )

        zero_step = self.write_snapshot(
            "zero-range-step.json",
            lambda value: first_range(value).update(step=0),
        )
        negative_limit = self.write_snapshot(
            "negative-range-limit.json",
            lambda value: first_range(value).update(limit=-1),
        )
        invalid_limited_last = self.write_snapshot(
            "invalid-limited-last.json",
            lambda value: first_range(value).update(lastkey=-2, limit=2),
        )
        negative_keynum_index = self.write_snapshot(
            "negative-keynum-index.json",
            lambda value: first_keynum(value).update(keynumidx=-1),
        )
        self.assert_audit_fails(zero_step, "range bounds are invalid")
        self.assert_audit_fails(negative_limit, "range bounds are invalid")
        self.assert_audit_fails(invalid_limited_last, "range bounds are invalid")
        self.assert_audit_fails(negative_keynum_index, "keynum bounds are invalid")

    def test_rejects_unexpected_schema_fields_at_every_audited_level(self):
        def first_spec(value):
            return next(command["metadata"]["key_specs"][0] for command in value["commands"] if command["metadata"]["key_specs"])

        command = self.write_snapshot(
            "unexpected-command.json",
            lambda value: value["commands"][0].update(unexpected=True),
        )
        key_spec = self.write_snapshot(
            "unexpected-key-spec.json",
            lambda value: first_spec(value).update(unexpected=True),
        )
        begin_search = self.write_snapshot(
            "unexpected-begin-search.json",
            lambda value: first_spec(value)["begin_search"].update(unexpected=True),
        )
        find_keys = self.write_snapshot(
            "unexpected-find-keys.json",
            lambda value: first_spec(value)["find_keys"].update(unexpected=True),
        )
        argument = self.write_snapshot(
            "unexpected-argument.json",
            lambda value: next(
                command["metadata"]["arguments"][0]
                for command in value["commands"]
                if command["metadata"].get("arguments")
            ).update(unexpected=True),
        )
        self.assert_audit_fails(command, "command 0 has unexpected field unexpected")
        self.assert_audit_fails(key_spec, "key spec 0 has unexpected field unexpected")
        self.assert_audit_fails(begin_search, "key spec 0 begin_search has unexpected field unexpected")
        self.assert_audit_fails(find_keys, "key spec 0 find_keys has unexpected field unexpected")
        self.assert_audit_fails(argument, "argument 0 has unexpected field unexpected")

    def test_rejects_invalid_argument_schema(self):
        def first_argument(value):
            return next(
                command["metadata"]["arguments"][0]
                for command in value["commands"]
                if command["metadata"].get("arguments")
            )

        unsupported_type = self.write_snapshot(
            "unsupported-argument-type.json",
            lambda value: first_argument(value).update(type="opaque"),
        )
        invalid_optional = self.write_snapshot(
            "invalid-argument-optional.json",
            lambda value: first_argument(value).update(optional="yes"),
        )
        invalid_key_spec = self.write_snapshot(
            "invalid-argument-key-spec.json",
            lambda value: next(
                argument
                for command in value["commands"]
                for argument in command["metadata"].get("arguments", [])
                if argument.get("type") == "key"
            ).update(key_spec_index=999),
        )
        self.assert_audit_fails(unsupported_type, "argument 0 has unsupported type")
        self.assert_audit_fails(invalid_optional, "argument 0 optional must be boolean")
        self.assert_audit_fails(invalid_key_spec, "key_spec_index is invalid")

    def test_rejects_invalid_nested_argument_schema(self):
        def mutate(value):
            parent = next(
                argument
                for command in value["commands"]
                for argument in command["metadata"].get("arguments", [])
                if argument.get("arguments")
            )
            parent["arguments"][0]["unexpected"] = True

        path = self.write_snapshot("invalid-nested-argument.json", mutate)
        self.assert_audit_fails(path, "argument 0.0 has unexpected field unexpected")

    def test_rejects_unlinked_routing_key_spec(self):
        def mutate(value):
            argument = next(
                argument
                for command in value["commands"]
                for argument in command["metadata"].get("arguments", [])
                if argument.get("type") == "key"
                and "key_spec_index" in argument
            )
            argument.pop("key_spec_index")

        path = self.write_snapshot("unlinked-key-spec.json", mutate)
        self.assert_audit_fails(path, "is not linked from its argument grammar")

    def test_rejects_missing_arity_and_key_specs(self):
        arity = self.write_snapshot("missing-arity.json", lambda value: value["commands"][0]["metadata"].pop("arity"))
        key_specs = self.write_snapshot("missing-key-specs.json", lambda value: value["commands"][0]["metadata"].pop("key_specs"))
        self.assert_audit_fails(arity, "is missing arity")
        self.assert_audit_fails(key_specs, "key_specs must be an array")

    def test_generated_flags_match_every_canonical_command_and_key_spec(self):
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        commands = GENERATOR.audit_snapshot(snapshot)
        generated = GENERATOR.render_module(commands, SNAPSHOT)
        rows = re.findall(r"^    CommandMetadata .+$", generated, re.MULTILINE)
        expected_key_spec_count = sum(len(command["metadata"]["key_specs"]) for command in commands)
        expected_argument_count = 0
        def count_arguments(arguments):
            return sum(
                1 + count_arguments(argument.get("arguments", []))
                for argument in arguments
            )
        expected_argument_count = sum(
            count_arguments(command["metadata"].get("arguments", []))
            for command in commands
        )
        self.assertEqual(len(rows), snapshot["counts"]["total"])
        self.assertEqual(len(commands), snapshot["counts"]["total"])
        self.assertEqual(len(re.findall(r"KeySpec \(", generated)) - 1, expected_key_spec_count)
        self.assertEqual(
            len(re.findall(r'CommandArgument "', generated)),
            expected_argument_count,
        )
        append = next(command for command in commands if command["name"] == "APPEND")
        self.assertEqual(append["metadata"]["command_flags"], ["WRITE", "DENYOOM", "FAST"])
        self.assertEqual(append["metadata"]["key_specs"][0]["flags"], ["RW", "INSERT"])
        for command in commands:
            metadata = command["metadata"]
            expected = "CommandMetadata {} ({}) [{}]".format(
                GENERATOR.hs_string(GENERATOR.command_identity(command)),
                metadata["arity"],
                ", ".join(GENERATOR.hs_string(flag) for flag in metadata.get("command_flags", [])),
            )
            self.assertIn(expected, generated)
            for key_spec in metadata["key_specs"]:
                expected = "KeySpec ({}) ({}) [{}]".format(
                    GENERATOR.render_begin_search(key_spec),
                    GENERATOR.render_find_keys(key_spec),
                    ", ".join(GENERATOR.hs_string(flag) for flag in key_spec["flags"]),
                )
                self.assertIn(expected, generated)

    def test_preserves_hyphenated_subcommand_identities(self):
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        commands = GENERATOR.audit_snapshot(snapshot)
        generated = GENERATOR.render_module(commands, SNAPSHOT)
        self.assertIn('CommandMetadata "CLIENT NO-EVICT"', generated)
        self.assertIn('CommandMetadata "CLUSTER SET-CONFIG-EPOCH"', generated)
        self.assertNotIn('CommandMetadata "CLIENT NO_EVICT"', generated)

    def test_generation_is_offline_deterministic_and_byte_identical(self):
        first = WORK / "first.hs"
        second = WORK / "second.hs"
        command = [sys.executable, str(SCRIPT), "--snapshot", str(SNAPSHOT)]
        self.assertEqual(subprocess.run(command + ["--output", str(first)], check=False).returncode, 0)
        self.assertEqual(subprocess.run(command + ["--output", str(second)], check=False).returncode, 0)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_command_metadata_is_not_exposed_by_the_cluster_library(self):
        cluster_library = re.search(
            r"^library cluster\n(.*?)(?=^library redis$)",
            CABAL.read_text(encoding="utf-8"),
            re.MULTILINE | re.DOTALL,
        ).group(1)
        exposed = cluster_library.split("exposed-modules:", 1)[1].split("other-modules:", 1)[0]
        private = cluster_library.split("other-modules:", 1)[1].split("build-depends:", 1)[0]
        self.assertNotIn("Database.Redis.Cluster.Internal.CommandMetadata", exposed)
        self.assertIn("Database.Redis.Cluster.Internal.CommandMetadata", private)


if __name__ == "__main__":
    unittest.main()
