#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import pathlib
import sys
import urllib.request
from typing import Any, Dict, List, Optional

REDIS_DOC_SHA = "928bf6ed9848b76b53429adf81f96f9db3b06800"  # redis-doc update from Redis 7.2.2
REDIS_DOC_URL = f"https://raw.githubusercontent.com/redis/redis-doc/{REDIS_DOC_SHA}/commands.json"
ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT_PATH = ROOT / "hask-redis-mux" / "data" / "redis-doc-commands-7.2.2-928bf6ed.json"
GENERATED_PATH = ROOT / "hask-redis-mux" / "lib" / "cluster" / "Database" / "Redis" / "Cluster" / "Commands" / "Generated.hs"

MAINTAINED_COMMANDS = [
    "APPEND", "AUTH", "CLUSTER SLOTS", "COMMAND", "DBSIZE", "DECR", "DEL", "ECHO",
    "EVAL", "EVALSHA", "EXISTS", "EXPIRE", "FLUSHALL", "FLUSHDB", "GEOADD", "GEODIST",
    "GEOHASH", "GEOPOS", "GEORADIUS", "GEORADIUSBYMEMBER", "GEORADIUSBYMEMBER_RO", "GEORADIUS_RO",
    "GEOSEARCH", "GEOSEARCHSTORE", "GET", "GETDEL", "GETEX", "GETRANGE", "HDEL", "HEXISTS",
    "HGET", "HGETALL", "HKEYS", "HMGET", "HSET", "HVALS", "INCR", "INFO", "LINDEX", "LLEN",
    "LPOP", "LPUSH", "LRANGE", "MGET", "MEMORY USAGE", "MSET", "MSETNX", "PERSIST",
    "PING", "PSETEX", "QUIT", "RPOP", "RPUSH", "SADD", "SCARD", "SET", "SETEX", "SETRANGE",
    "SETNX", "SISMEMBER", "SMEMBERS", "STRLEN", "TIME", "TTL", "XREAD", "XREADGROUP", "ZADD", "ZRANGE",
    "ZCARD", "CLIENT SETINFO"
]


def fetch_commands_json() -> Dict[str, Any]:
    with urllib.request.urlopen(REDIS_DOC_URL) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload)


def command_syntax(tokens: List[str]) -> str:
    name = " ".join(tokens)
    if name in ("MSET", "MSETNX"):
        return "SyntaxPairs"
    if name in ("EVAL", "EVALSHA"):
        return "SyntaxEval"
    if name == "XREAD":
        return "SyntaxXRead"
    if name == "XREADGROUP":
        return "SyntaxXReadGroup"
    return "SyntaxNone"


def normalize_key_spec(raw: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    key_specs = raw.get("key_specs", [])
    if not key_specs:
        return None
    first = key_specs[0]
    begin = first.get("begin_search", {})
    begin_type = begin.get("type")
    begin_spec = begin.get("spec", {})

    find = first.get("find_keys", {})
    find_type = find.get("type")
    find_spec = find.get("spec", {})

    if begin_type == "index":
        begin_norm = {
            "tag": "BeginAtIndex",
            "index": int(begin_spec.get("index", 0)),
            "keyword": None,
            "startfrom": None,
        }
    elif begin_type == "keyword":
        begin_norm = {
            "tag": "BeginAfterKeyword",
            "index": None,
            "keyword": str(begin_spec.get("keyword", "")).upper(),
            "startfrom": int(begin_spec.get("startfrom", 0)),
        }
    else:
        return None

    if find_type == "range":
        find_norm = {
            "tag": "FindRange",
            "lastkey": int(find_spec.get("lastkey", 0)),
            "keystep": int(find_spec.get("keystep", 1)),
            "limit": int(find_spec.get("limit", 0)),
            "keynumidx": None,
            "firstkey": None,
        }
    elif find_type == "keynum":
        find_norm = {
            "tag": "FindKeyNum",
            "lastkey": None,
            "keystep": int(find_spec.get("keystep", 1)),
            "limit": None,
            "keynumidx": int(find_spec.get("keynumidx", 0)),
            "firstkey": int(find_spec.get("firstkey", 0)),
        }
    else:
        return None

    return {"begin": begin_norm, "find": find_norm}


def normalize_entry(name: str, raw: Dict[str, Any]) -> Dict[str, Any]:
    tokens = [token.upper() for token in name.split(" ")]
    return {
        "name": name,
        "tokens": tokens,
        "arity": int(raw.get("arity", 0)),
        "flags": sorted(raw.get("command_flags", [])),
        "key_spec": normalize_key_spec(raw),
        "syntax": command_syntax(tokens),
        "arguments": raw.get("arguments", []),
    }


def make_snapshot(commands: Dict[str, Any]) -> Dict[str, Any]:
    missing = [name for name in MAINTAINED_COMMANDS if name not in commands]
    if missing:
        raise RuntimeError(f"missing maintained commands in redis-doc metadata: {missing}")

    entries = [normalize_entry(name, commands[name]) for name in MAINTAINED_COMMANDS]
    entries.sort(key=lambda item: item["tokens"])
    return {
        "redisDocSha": REDIS_DOC_SHA,
        "redisDocUrl": REDIS_DOC_URL,
        "commandCount": len(entries),
        "entries": entries,
    }


def hs_bs(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_key_spec(key_spec: Optional[Dict[str, Any]]) -> str:
    if key_spec is None:
        return "Nothing"
    begin = key_spec["begin"]
    find = key_spec["find"]
    if begin["tag"] == "BeginAtIndex":
        begin_expr = f"(BeginAtIndex {begin['index']})"
    else:
        begin_expr = f"(BeginAfterKeyword {hs_bs(begin['keyword'])} {begin['startfrom']})"

    if find["tag"] == "FindRange":
        find_expr = f"(FindRange ({find['lastkey']}) ({find['keystep']}) ({find['limit']}))"
    else:
        find_expr = f"(FindKeyNum ({find['keynumidx']}) ({find['firstkey']}) ({find['keystep']}))"
    return f"(Just (GeneratedKeySpec {begin_expr} {find_expr}))"


def render_generated(snapshot: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("{-# LANGUAGE OverloadedStrings #-}")
    lines.append("")
    lines.append("-- This file is generated by scripts/generate-smart-proxy-routing.py")
    lines.append("module Database.Redis.Cluster.Commands.Generated")
    lines.append("  ( redisDocSha")
    lines.append("  , generatedRoutingEntries")
    lines.append("  , GeneratedRoutingEntry(..)")
    lines.append("  , GeneratedKeySpec(..)")
    lines.append("  , GeneratedBeginSearch(..)")
    lines.append("  , GeneratedFindKeys(..)")
    lines.append("  , GeneratedSyntax(..)")
    lines.append("  ) where")
    lines.append("")
    lines.append("import Data.ByteString (ByteString)")
    lines.append("")
    lines.append("data GeneratedBeginSearch")
    lines.append("  = BeginAtIndex Int")
    lines.append("  | BeginAfterKeyword ByteString Int")
    lines.append("  deriving (Eq, Show)")
    lines.append("")
    lines.append("data GeneratedFindKeys")
    lines.append("  = FindRange Int Int Int")
    lines.append("  | FindKeyNum Int Int Int")
    lines.append("  deriving (Eq, Show)")
    lines.append("")
    lines.append("data GeneratedKeySpec = GeneratedKeySpec")
    lines.append("  { gksBegin :: GeneratedBeginSearch")
    lines.append("  , gksFind :: GeneratedFindKeys")
    lines.append("  } deriving (Eq, Show)")
    lines.append("")
    lines.append("data GeneratedSyntax")
    lines.append("  = SyntaxNone")
    lines.append("  | SyntaxPairs")
    lines.append("  | SyntaxEval")
    lines.append("  | SyntaxXRead")
    lines.append("  | SyntaxXReadGroup")
    lines.append("  deriving (Eq, Show)")
    lines.append("")
    lines.append("data GeneratedRoutingEntry = GeneratedRoutingEntry")
    lines.append("  { greTokens :: [ByteString]")
    lines.append("  , greArity :: Int")
    lines.append("  , greKeySpec :: Maybe GeneratedKeySpec")
    lines.append("  , greSyntax :: GeneratedSyntax")
    lines.append("  , greArgumentsJson :: ByteString")
    lines.append("  } deriving (Eq, Show)")
    lines.append("")
    lines.append(f"redisDocSha :: ByteString\nredisDocSha = {hs_bs(snapshot['redisDocSha'])}")
    lines.append("")
    lines.append("generatedRoutingEntries :: [GeneratedRoutingEntry]")
    lines.append("generatedRoutingEntries =")
    for idx, entry in enumerate(snapshot["entries"]):
        prefix = "  [" if idx == 0 else "  ,"
        lines.append(prefix + " GeneratedRoutingEntry")
        tokens = ", ".join(hs_bs(token) for token in entry["tokens"])
        lines.append(f"      [{tokens}]")
        lines.append(f"      ({entry['arity']})")
        lines.append(f"      {render_key_spec(entry['key_spec'])}")
        lines.append(f"      {entry['syntax']}")
        args_json = json.dumps(entry["arguments"], separators=(",", ":"), sort_keys=True)
        lines.append(f"      {hs_bs(args_json)}")
    lines.append("  ]")
    lines.append("")
    return "\n".join(lines)


def write_outputs(snapshot: Dict[str, Any]) -> None:
    SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
    GENERATED_PATH.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT_PATH.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    GENERATED_PATH.write_text(render_generated(snapshot), encoding="utf-8")


def audit(snapshot: Dict[str, Any], simulate_mutation: bool) -> None:
    if not SNAPSHOT_PATH.exists() or not GENERATED_PATH.exists():
        raise RuntimeError("generated artifacts are missing; run generate first")

    stored_snapshot = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
    if stored_snapshot != snapshot:
        raise RuntimeError("snapshot metadata drift detected; re-run generator")

    generated_text = GENERATED_PATH.read_text(encoding="utf-8")
    expected_generated_text = render_generated(snapshot)
    if generated_text != expected_generated_text:
        raise RuntimeError("generated Haskell routing entries do not match metadata-derived canonical output")

    if simulate_mutation:
        entries = copy.deepcopy(snapshot["entries"])
        if not entries:
            raise RuntimeError("mutation check failed: no entries available")
        entries[0]["arity"] += 1
        mutated_snapshot = dict(snapshot)
        mutated_snapshot["entries"] = entries
        if render_generated(mutated_snapshot) == expected_generated_text:
            raise RuntimeError("mutation check failed: semantic audit did not detect mutation")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate/audit smart proxy routing metadata")
    parser.add_argument("action", choices=["generate", "audit"])
    parser.add_argument("--simulate-mutation", action="store_true")
    args = parser.parse_args()

    commands = fetch_commands_json()
    snapshot = make_snapshot(commands)

    if args.action == "generate":
        write_outputs(snapshot)
        print(f"Generated {SNAPSHOT_PATH} and {GENERATED_PATH}")
    else:
        audit(snapshot, args.simulate_mutation)
        print("Semantic routing audit passed")
        if args.simulate_mutation:
            print("Mutation simulation passed (audit would fail on entry changes)")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
