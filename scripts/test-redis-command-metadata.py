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

    def audit(self, snapshot, output=OUTPUT):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--audit", "--snapshot", str(snapshot), "--output", str(output)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_audits_checked_in_snapshot_and_generated_module(self):
        self.assertEqual(self.audit(SNAPSHOT).returncode, 0)

    def test_rejects_snapshot_digest_mismatch(self):
        path = self.write_snapshot("bad-digest.json", lambda value: value["provenance"].update(commands_sha256="0" * 64))
        self.assertNotEqual(self.audit(path).returncode, 0)

    def test_rejects_generated_drift(self):
        output = WORK / "drift.hs"
        output.write_text("drift\n", encoding="utf-8")
        self.assertNotEqual(self.audit(SNAPSHOT, output).returncode, 0)

    def test_rejects_duplicate_identity(self):
        path = self.write_snapshot("duplicate.json", lambda value: value["commands"].insert(1, copy.deepcopy(value["commands"][0])))
        self.assertNotEqual(self.audit(path).returncode, 0)

    def test_rejects_unsupported_key_spec_schema(self):
        def mutate(value):
            spec = next(command["metadata"]["key_specs"][0] for command in value["commands"] if command["metadata"]["key_specs"])
            spec["begin_search"] = {"unsupported": {}}
        path = self.write_snapshot("unsupported.json", mutate)
        self.assertNotEqual(self.audit(path).returncode, 0)

    def test_rejects_missing_arity_and_key_specs(self):
        arity = self.write_snapshot("missing-arity.json", lambda value: value["commands"][0]["metadata"].pop("arity"))
        key_specs = self.write_snapshot("missing-key-specs.json", lambda value: value["commands"][0]["metadata"].pop("key_specs"))
        self.assertNotEqual(self.audit(arity).returncode, 0)
        self.assertNotEqual(self.audit(key_specs).returncode, 0)


if __name__ == "__main__":
    unittest.main()
