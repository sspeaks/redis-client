#!/usr/bin/env python3
"""Tests for deterministic Redis command grammar generation and audit."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from generate_redis_command_grammar import (
    DEFAULT_SHA,
    build_grammar_entries,
    load_redis_command_json,
)
SNAPSHOT = ROOT / "hask-redis-mux" / "data" / f"redis-commands-{DEFAULT_SHA}.json"


class RedisGrammarAuditTests(unittest.TestCase):
    def test_snapshot_count_matches_authoritative_source(self) -> None:
        authoritative = build_grammar_entries(load_redis_command_json(DEFAULT_SHA))
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        self.assertEqual(len(snapshot["entries"]), len(authoritative))

    def test_maintained_known_forms_exist_in_snapshot(self) -> None:
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        names = {tuple(entry["tokens"]) for entry in snapshot["entries"]}
        expected = {
            ("SET",),
            ("MEMORY", "USAGE"),
            ("OBJECT", "HELP"),
            ("ZUNION",),
            ("XREAD",),
            ("XREADGROUP",),
            ("MSET",),
            ("EVAL",),
            ("GEOSEARCH",),
        }
        self.assertTrue(expected.issubset(names))

    def test_semantic_audit_and_deliberate_mutation_failure(self) -> None:
        ok = subprocess.run(
            ["python3", "scripts/audit_redis_command_grammar.py", "--sha", DEFAULT_SHA],
            cwd=ROOT,
            check=False,
        )
        self.assertEqual(ok.returncode, 0)

        mutated = subprocess.run(
            [
                "python3",
                "scripts/audit_redis_command_grammar.py",
                "--sha",
                DEFAULT_SHA,
                "--expect-mutation-failure",
            ],
            cwd=ROOT,
            check=False,
        )
        self.assertNotEqual(mutated.returncode, 0)


if __name__ == "__main__":
    unittest.main()
