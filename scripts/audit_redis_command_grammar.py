#!/usr/bin/env python3
"""Semantic audit for generated Redis command grammar metadata."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any

from generate_redis_command_grammar import (
    DEFAULT_SHA,
    GEN_HS,
    build_grammar_entries,
    grammar_digest,
    load_redis_command_json,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "hask-redis-mux" / "data"


def read_snapshot(sha: str) -> dict[str, Any]:
    path = DATA_DIR / f"redis-commands-{sha}.json"
    if not path.exists():
        raise FileNotFoundError(f"Missing generated snapshot: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def parse_haskell_constants() -> tuple[str, str]:
    content = GEN_HS.read_text(encoding="utf-8")
    sha_match = re.search(r'redisSourceSha = "([0-9a-f]{40})"', content)
    digest_match = re.search(r'redisGrammarDigest = "([0-9a-f]{64})"', content)
    if sha_match is None or digest_match is None:
        raise ValueError("Generated Haskell file is missing redisSourceSha or redisGrammarDigest")
    return sha_match.group(1), digest_match.group(1)


def mutate_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not entries:
        return entries
    altered = json.loads(json.dumps(entries))
    altered[0]["arity"] = int(altered[0]["arity"]) + 1
    return altered


def canonical_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(entries, key=lambda entry: (entry["tokens"], entry["arity"]))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha", default=DEFAULT_SHA)
    parser.add_argument("--expect-mutation-failure", action="store_true")
    args = parser.parse_args()

    commands = load_redis_command_json(args.sha)
    expected_entries = [entry.to_json() for entry in build_grammar_entries(commands)]
    expected_digest = grammar_digest(build_grammar_entries(commands), args.sha)

    snapshot = read_snapshot(args.sha)
    snapshot_entries = snapshot["entries"]
    if args.expect_mutation_failure:
        snapshot_entries = mutate_entries(snapshot_entries)

    if snapshot.get("redis_source_sha") != args.sha:
        print("Snapshot source SHA mismatch", file=sys.stderr)
        sys.exit(1)

    if canonical_entries(snapshot_entries) != canonical_entries(expected_entries):
        print("Snapshot entries do not match authoritative Redis command JSON", file=sys.stderr)
        sys.exit(1)

    snapshot_digest = snapshot.get("redis_grammar_digest")
    if snapshot_digest != expected_digest:
        print("Snapshot digest mismatch", file=sys.stderr)
        sys.exit(1)

    hs_sha, hs_digest = parse_haskell_constants()
    if hs_sha != args.sha or hs_digest != expected_digest:
        print("Generated Haskell constants mismatch", file=sys.stderr)
        sys.exit(1)

    print(f"Audit passed for {len(expected_entries)} entries at {args.sha}")


if __name__ == "__main__":
    main()
