#!/usr/bin/env python3
"""Generate and audit the checked-in Redis command metadata artifact."""

import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SNAPSHOT = ROOT / "hask-redis-mux/data/redis-command-metadata.json"
DEFAULT_OUTPUT = ROOT / "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Internal/CommandMetadata.hs"
SCHEMA_VERSION = 1
SUPPORTED_BEGIN_SEARCH = {"index", "keyword", "unknown"}
SUPPORTED_FIND_KEYS = {"range", "keynum", "unknown"}
SUPPORTED_REDIS_SOURCES = {
    "7.2.0": {
        "commit": "29622276ecd7b74312798e6772744858a8a6f9bf",
        "counts": {"top_level": 242, "subcommands": 150, "total": 392},
    }
}


class AuditError(Exception):
    pass


def canonical_json(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def commands_digest(commands):
    encoded = json.dumps(commands, separators=(",", ":"), sort_keys=True, ensure_ascii=True).encode("ascii")
    return hashlib.sha256(encoded).hexdigest()


def command_identity(command):
    name = command["name"].upper()
    container = command["metadata"].get("container")
    if container is None:
        return name
    return "{} {}".format(container.upper(), name.replace("-", "_").replace(":", ""))


def expect_mapping(value, description):
    if not isinstance(value, dict):
        raise AuditError("{} must be an object".format(description))
    return value


def expect_list(value, description):
    if not isinstance(value, list):
        raise AuditError("{} must be an array".format(description))
    return value


def audit_key_spec(identity, index, key_spec):
    key_spec = expect_mapping(key_spec, "{} key spec {}".format(identity, index))
    begin_search = expect_mapping(key_spec.get("begin_search"), "{} key spec {} begin_search".format(identity, index))
    find_keys = expect_mapping(key_spec.get("find_keys"), "{} key spec {} find_keys".format(identity, index))
    if len(begin_search) != 1 or next(iter(begin_search)) not in SUPPORTED_BEGIN_SEARCH:
        raise AuditError("{} key spec {} has unsupported begin_search schema".format(identity, index))
    if len(find_keys) != 1 or next(iter(find_keys)) not in SUPPORTED_FIND_KEYS:
        raise AuditError("{} key spec {} has unsupported find_keys schema".format(identity, index))
    begin_kind, begin_value = next(iter(begin_search.items()))
    find_kind, find_value = next(iter(find_keys.items()))
    if begin_kind == "index":
        expect_mapping(begin_value, "{} key spec {} index".format(identity, index))
        if not isinstance(begin_value.get("pos"), int):
            raise AuditError("{} key spec {} index position is invalid".format(identity, index))
    elif begin_kind == "keyword":
        begin_value = expect_mapping(begin_value, "{} key spec {} keyword".format(identity, index))
        if not isinstance(begin_value.get("keyword"), str) or not isinstance(begin_value.get("startfrom"), int):
            raise AuditError("{} key spec {} keyword is invalid".format(identity, index))
    elif begin_value is not None:
        raise AuditError("{} key spec {} unknown begin_search must be null".format(identity, index))
    if find_kind == "range":
        find_value = expect_mapping(find_value, "{} key spec {} range".format(identity, index))
        if not all(isinstance(find_value.get(field), int) for field in ("lastkey", "step", "limit")):
            raise AuditError("{} key spec {} range is invalid".format(identity, index))
    elif find_kind == "keynum":
        find_value = expect_mapping(find_value, "{} key spec {} keynum".format(identity, index))
        if not all(isinstance(find_value.get(field), int) for field in ("keynumidx", "firstkey", "step")):
            raise AuditError("{} key spec {} keynum is invalid".format(identity, index))
    elif find_value is not None:
        raise AuditError("{} key spec {} unknown find_keys must be null".format(identity, index))


def audit_snapshot(snapshot):
    snapshot = expect_mapping(snapshot, "snapshot")
    if snapshot.get("schema_version") != SCHEMA_VERSION:
        raise AuditError("unsupported snapshot schema version")
    provenance = expect_mapping(snapshot.get("provenance"), "provenance")
    required_provenance = (
        "redis_version_tag",
        "redis_commit",
        "source_url",
        "source_path",
        "retrieved_at",
        "source_sha256",
        "commands_sha256",
    )
    for field in required_provenance:
        if not isinstance(provenance.get(field), str) or not provenance[field]:
            raise AuditError("provenance {} is missing".format(field))
    if len(provenance["redis_commit"]) != 40:
        raise AuditError("provenance redis_commit must be a full SHA")
    source = SUPPORTED_REDIS_SOURCES.get(provenance["redis_version_tag"])
    if source is None or source["commit"] != provenance["redis_commit"]:
        raise AuditError("unsupported Redis source provenance")
    commands = expect_list(snapshot.get("commands"), "commands")
    identities = []
    top_level = 0
    subcommands = 0
    kinds = {"fixed": 0, "range": 0, "keyword": 0, "movable": 0}
    for index, command in enumerate(commands):
        command = expect_mapping(command, "command {}".format(index))
        if not isinstance(command.get("name"), str) or not command["name"]:
            raise AuditError("command {} has no name".format(index))
        metadata = expect_mapping(command.get("metadata"), "command {} metadata".format(command["name"]))
        identity = command_identity(command)
        identities.append(identity)
        if "container" in metadata:
            subcommands += 1
        else:
            top_level += 1
        if not isinstance(metadata.get("arity"), int):
            raise AuditError("{} is missing arity".format(identity))
        key_specs = expect_list(metadata.get("key_specs"), "{} key_specs".format(identity))
        for spec_index, key_spec in enumerate(key_specs):
            audit_key_spec(identity, spec_index, key_spec)
            begin_kind = next(iter(key_spec["begin_search"]))
            find_kind = next(iter(key_spec["find_keys"]))
            if begin_kind == "index":
                kinds["fixed"] += 1
            if find_kind == "range":
                kinds["range"] += 1
            if begin_kind == "keyword":
                kinds["keyword"] += 1
            if find_kind == "keynum":
                kinds["movable"] += 1
    if identities != sorted(identities):
        raise AuditError("command identities are not sorted")
    if len(identities) != len(set(identities)):
        raise AuditError("duplicate command identity")
    counts = expect_mapping(snapshot.get("counts"), "counts")
    expected_counts = {
        "top_level": top_level,
        "subcommands": subcommands,
        "total": len(commands),
    }
    if counts != expected_counts:
        raise AuditError("command counts do not match the snapshot")
    if counts != source["counts"]:
        raise AuditError("command counts do not match the immutable Redis source")
    if provenance["commands_sha256"] != commands_digest(commands):
        raise AuditError("snapshot command digest mismatch")
    if not all(kinds.values()):
        raise AuditError("snapshot lacks a representative fixed, range, keyword, or movable key spec")
    return commands


def hs_string(value):
    return json.dumps(value, ensure_ascii=True)


def hs_int(value):
    return "({})".format(value)


def render_begin_search(spec):
    kind, value = next(iter(spec["begin_search"].items()))
    if kind == "index":
        return "Fixed {}".format(hs_int(value["pos"]))
    if kind == "keyword":
        return "Keyword {} {}".format(hs_string(value["keyword"]), hs_int(value["startfrom"]))
    return "UnknownBeginSearch"


def render_find_keys(spec):
    kind, value = next(iter(spec["find_keys"].items()))
    if kind == "range":
        return "Range {} {} {}".format(
            hs_int(value["lastkey"]), hs_int(value["step"]), hs_int(value["limit"])
        )
    if kind == "keynum":
        return "Keynum {} {} {}".format(
            hs_int(value["keynumidx"]), hs_int(value["firstkey"]), hs_int(value["step"])
        )
    return "UnknownFindKeys"


def render_module(commands, snapshot_path):
    try:
        snapshot_reference = snapshot_path.relative_to(ROOT).as_posix()
    except ValueError:
        snapshot_reference = snapshot_path.as_posix()
    lines = [
        "-- This file is generated by scripts/generate-redis-command-metadata.py; do not edit.",
        "-- Source: {}".format(snapshot_reference),
        "{-# LANGUAGE OverloadedStrings #-}",
        "",
        "module Database.Redis.Cluster.Internal.CommandMetadata",
        "  ( BeginSearch (..)",
        "  , FindKeys (..)",
        "  , KeySpec (..)",
        "  , CommandMetadata (..)",
        "  , commandMetadata",
        "  ) where",
        "",
        "import           Data.ByteString (ByteString)",
        "",
        "data BeginSearch = Fixed Int | Keyword ByteString Int | UnknownBeginSearch",
        "  deriving (Eq, Show)",
        "",
        "data FindKeys = Range Int Int Int | Keynum Int Int Int | UnknownFindKeys",
        "  deriving (Eq, Show)",
        "",
        "data KeySpec = KeySpec",
        "  { keySpecBeginSearch :: BeginSearch",
        "  , keySpecFindKeys    :: FindKeys",
        "  } deriving (Eq, Show)",
        "",
        "data CommandMetadata = CommandMetadata",
        "  { commandIdentity :: ByteString",
        "  , commandArity    :: Int",
        "  , commandKeySpecs :: [KeySpec]",
        "  } deriving (Eq, Show)",
        "",
        "commandMetadata :: [CommandMetadata]",
        "commandMetadata =",
        "  [",
    ]
    entries = []
    for command in commands:
        metadata = command["metadata"]
        specs = metadata["key_specs"]
        rendered_specs = ", ".join(
            "KeySpec ({}) ({})".format(render_begin_search(spec), render_find_keys(spec)) for spec in specs
        )
        entries.append(
            '    CommandMetadata {} {} [{}]'.format(
                hs_string(command_identity(command)), "({})".format(metadata["arity"]), rendered_specs
            )
        )
    lines.append(",\n".join(entries))
    lines.extend(["  ]", ""])
    return "\n".join(lines)


def load_snapshot(path):
    try:
        contents = path.read_text(encoding="utf-8")
        snapshot = json.loads(contents)
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError("cannot read snapshot {}: {}".format(path, error)) from error
    if contents != canonical_json(snapshot):
        raise AuditError("snapshot is not canonical, sorted JSON")
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--audit", action="store_true", help="verify snapshot and generated module without writing")
    args = parser.parse_args()
    try:
        snapshot = load_snapshot(args.snapshot)
        commands = audit_snapshot(snapshot)
        rendered = render_module(commands, args.snapshot)
        if args.audit:
            if not args.output.is_file() or args.output.read_text(encoding="utf-8") != rendered:
                raise AuditError("generated module drift")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
    except AuditError as error:
        print("redis command metadata audit failed: {}".format(error), file=sys.stderr)
        return 1
    print("redis command metadata: {} commands ({})".format(len(commands), "audited" if args.audit else "generated"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
