#!/usr/bin/env python3
"""Generate deterministic Redis 7.2 command grammar metadata.

Source of truth: immutable Redis upstream command JSON files at a fixed commit.
This script extracts arity, flags, and key-spec semantics and emits:

1) hask-redis-mux/data/redis-commands-<sha>.json
2) hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands/Generated.hs
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import tarfile
import urllib.request
from dataclasses import dataclass
from io import BytesIO
from typing import Any

DEFAULT_SHA = "9913c926510755fa0d241658f550338a02258edb"
ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "hask-redis-mux" / "data"
GEN_HS = (
    ROOT
    / "hask-redis-mux"
    / "lib"
    / "cluster"
    / "Database"
    / "Redis"
    / "Cluster"
    / "Commands"
    / "Generated.hs"
)


@dataclass(frozen=True)
class GrammarEntry:
    tokens: list[str]
    arity: int
    command_flags: list[str]
    key_specs: list[dict[str, Any]]

    def to_json(self) -> dict[str, Any]:
        return {
            "tokens": self.tokens,
            "arity": self.arity,
            "command_flags": self.command_flags,
            "key_specs": self.key_specs,
        }


def load_redis_command_json(sha: str) -> list[tuple[str, dict[str, Any]]]:
    url = f"https://codeload.github.com/redis/redis/tar.gz/{sha}"
    with urllib.request.urlopen(url) as resp:
        blob = resp.read()

    archive = tarfile.open(fileobj=BytesIO(blob), mode="r:gz")
    prefix = f"redis-{sha}/src/commands/"
    commands: list[tuple[str, dict[str, Any]]] = []
    for member in archive.getmembers():
        if not member.isfile():
            continue
        if not member.name.startswith(prefix) or not member.name.endswith(".json"):
            continue
        file_obj = archive.extractfile(member)
        if file_obj is None:
            continue
        payload = json.loads(file_obj.read().decode("utf-8"))
        for command_name, command_spec in payload.items():
            commands.append((command_name, command_spec))
    commands.sort(key=lambda item: (item[1].get("container", ""), item[0]))
    return commands


def to_full_tokens(command_name: str, spec: dict[str, Any]) -> list[str]:
    container = spec.get("container")
    if container:
        return [str(container).upper(), str(command_name).upper()]
    return [str(command_name).upper()]


def extract_key_spec(raw: dict[str, Any]) -> dict[str, Any]:
    begin_search = raw.get("begin_search", {})
    find_keys = raw.get("find_keys", {})
    result: dict[str, Any] = {"flags": [str(flag).upper() for flag in raw.get("flags", [])]}

    if "index" in begin_search:
        result["begin_search"] = {
            "kind": "index",
            "pos": int(begin_search["index"]["pos"]),
        }
    elif "keyword" in begin_search:
        result["begin_search"] = {
            "kind": "keyword",
            "keyword": str(begin_search["keyword"]["keyword"]).upper(),
            "startfrom": int(begin_search["keyword"]["startfrom"]),
        }
    else:
        result["begin_search"] = {"kind": "unknown"}

    if "range" in find_keys:
        range_spec = find_keys["range"]
        result["find_keys"] = {
            "kind": "range",
            "lastkey": int(range_spec["lastkey"]),
            "step": int(range_spec["step"]),
            "limit": int(range_spec.get("limit", 0)),
        }
    elif "keynum" in find_keys:
        keynum_spec = find_keys["keynum"]
        result["find_keys"] = {
            "kind": "keynum",
            "keynumidx": int(keynum_spec["keynumidx"]),
            "firstkey": int(keynum_spec["firstkey"]),
            "step": int(keynum_spec["step"]),
        }
    else:
        result["find_keys"] = {"kind": "unknown"}
    return result


def build_grammar_entries(commands: list[tuple[str, dict[str, Any]]]) -> list[GrammarEntry]:
    entries: list[GrammarEntry] = []
    for command_name, command_spec in commands:
        arity = int(command_spec["arity"])
        command_flags = [str(flag).upper() for flag in command_spec.get("command_flags", [])]
        key_specs = [extract_key_spec(spec) for spec in command_spec.get("key_specs", [])]
        entries.append(
            GrammarEntry(
                tokens=to_full_tokens(command_name, command_spec),
                arity=arity,
                command_flags=sorted(set(command_flags)),
                key_specs=key_specs,
            )
        )
    entries.sort(key=lambda entry: (entry.tokens, entry.arity))
    return entries


def grammar_digest(entries: list[GrammarEntry], sha: str) -> str:
    payload = {
        "redis_source_sha": sha,
        "entries": [entry.to_json() for entry in entries],
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def render_haskell(entries: list[GrammarEntry], sha: str, digest: str) -> str:
    lines: list[str] = [
        "{-# LANGUAGE OverloadedStrings #-}",
        "",
        "-- GENERATED FILE. DO NOT EDIT.",
        "-- Generated by scripts/generate_redis_command_grammar.py",
        "",
        "module Database.Redis.Cluster.Commands.Generated",
        "  ( GrammarEntry(..)",
        "  , BeginSearch(..)",
        "  , FindKeys(..)",
        "  , KeySpec(..)",
        "  , redisSourceSha",
        "  , redisGrammarDigest",
        "  , grammarEntries",
        "  ) where",
        "",
        "import Data.ByteString (ByteString)",
        "",
        "data GrammarEntry = GrammarEntry",
        "  { geTokens :: [ByteString]",
        "  , geArity :: Int",
        "  , geCommandFlags :: [ByteString]",
        "  , geKeySpecs :: [KeySpec]",
        "  }",
        "",
        "data KeySpec = KeySpec",
        "  { ksFlags :: [ByteString]",
        "  , ksBeginSearch :: BeginSearch",
        "  , ksFindKeys :: FindKeys",
        "  }",
        "",
        "data BeginSearch",
        "  = BeginSearchIndex !Int",
        "  | BeginSearchKeyword !ByteString !Int",
        "  | BeginSearchUnknown",
        "",
        "data FindKeys",
        "  = FindKeysRange !Int !Int !Int",
        "  | FindKeysKeyNum !Int !Int !Int",
        "  | FindKeysUnknown",
        "",
        f'redisSourceSha :: ByteString\nredisSourceSha = "{sha}"',
        "",
        f'redisGrammarDigest :: ByteString\nredisGrammarDigest = "{digest}"',
        "",
        "grammarEntries :: [GrammarEntry]",
        "grammarEntries =",
    ]
    if not entries:
        lines.append("  []")
        return "\n".join(lines) + "\n"

    for index, entry in enumerate(entries):
        prefix = "  [ " if index == 0 else "  , "
        lines.append(prefix + render_entry(entry))
    lines.append("  ]")
    return "\n".join(lines) + "\n"


def quote_bytestring(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_entry(entry: GrammarEntry) -> str:
    tokens = "[" + ", ".join(quote_bytestring(tok) for tok in entry.tokens) + "]"
    flags = "[" + ", ".join(quote_bytestring(flag) for flag in entry.command_flags) + "]"
    specs = "[" + ", ".join(render_key_spec(spec) for spec in entry.key_specs) + "]"
    return f"GrammarEntry {tokens} {render_int(entry.arity)} {flags} {specs}"


def render_key_spec(spec: dict[str, Any]) -> str:
    flags = "[" + ", ".join(quote_bytestring(flag) for flag in spec["flags"]) + "]"
    begin = spec["begin_search"]
    find = spec["find_keys"]
    begin_repr = "BeginSearchUnknown"
    if begin["kind"] == "index":
        begin_repr = f"(BeginSearchIndex {render_int(begin['pos'])})"
    elif begin["kind"] == "keyword":
        begin_repr = (
            "(BeginSearchKeyword "
            f"{quote_bytestring(begin['keyword'])} {render_int(begin['startfrom'])})"
        )

    find_repr = "FindKeysUnknown"
    if find["kind"] == "range":
        find_repr = (
            "(FindKeysRange "
            f"{render_int(find['lastkey'])} {render_int(find['step'])} {render_int(find['limit'])})"
        )
    elif find["kind"] == "keynum":
        find_repr = (
            "(FindKeysKeyNum "
            f"{render_int(find['keynumidx'])} {render_int(find['firstkey'])} {render_int(find['step'])})"
        )
    return f"KeySpec {flags} {begin_repr} {find_repr}"


def render_int(value: int) -> str:
    return f"({value})"


def write_outputs(entries: list[GrammarEntry], sha: str) -> tuple[pathlib.Path, pathlib.Path]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    GEN_HS.parent.mkdir(parents=True, exist_ok=True)
    digest = grammar_digest(entries, sha)
    data_path = DATA_DIR / f"redis-commands-{sha}.json"
    payload = {
        "redis_source_sha": sha,
        "redis_grammar_digest": digest,
        "entries": [entry.to_json() for entry in entries],
    }
    data_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    GEN_HS.write_text(render_haskell(entries, sha, digest), encoding="utf-8")
    return data_path, GEN_HS


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha", default=DEFAULT_SHA)
    args = parser.parse_args()

    commands = load_redis_command_json(args.sha)
    entries = build_grammar_entries(commands)
    data_path, hs_path = write_outputs(entries, args.sha)
    print(f"Generated {len(entries)} command entries")
    print(f"Wrote {data_path}")
    print(f"Wrote {hs_path}")


if __name__ == "__main__":
    main()
