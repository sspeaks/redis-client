#!/usr/bin/env python3

import copy
import json
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
WORK = ROOT / ".metadata-audit-test-work"


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
        self.assert_audit_fails(path, "unsupported begin_search schema")

    def test_rejects_missing_arity_and_key_specs(self):
        arity = self.write_snapshot("missing-arity.json", lambda value: value["commands"][0]["metadata"].pop("arity"))
        key_specs = self.write_snapshot("missing-key-specs.json", lambda value: value["commands"][0]["metadata"].pop("key_specs"))
        self.assert_audit_fails(arity, "is missing arity")
        self.assert_audit_fails(key_specs, "key_specs must be an array")


if __name__ == "__main__":
    unittest.main()
