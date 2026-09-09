#!/usr/bin/env python3
"""Generate and audit checked-in Redis command metadata.

``source_sha256`` is the SHA-256 of the exact UTF-8 bytes in the checked-in,
canonical JSON source bundle named by the supported source record.  The bundle
contains the immutable Redis commit, URL, path, and command data.  The
retrieval date is informational only and is validated solely as YYYY-MM-DD.
"""

import argparse
import copy
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SNAPSHOT = ROOT / "hask-redis-mux/data/redis-command-metadata.json"
DEFAULT_OUTPUT = ROOT / "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Internal/CommandMetadata.hs"
SCHEMA_VERSION = 1
SUPPORTED_BEGIN_SEARCH = {"index", "keyword", "unknown"}
SUPPORTED_FIND_KEYS = {"range", "keynum", "unknown"}
COMMAND_FIELDS = {"name", "metadata"}
COMMAND_METADATA_FIELDS = {
    "acl_categories", "arguments", "arity", "command_flags", "command_tips",
    "complexity", "container", "deprecated_since", "doc_flags", "function",
    "get_keys_function", "group", "history", "key_specs", "replaced_by",
    "reply_schema", "since", "summary",
}
KEY_SPEC_FIELDS = {"begin_search", "find_keys", "flags", "notes"}
BEGIN_SEARCH_FIELDS = {
    "index": {"pos"},
    "keyword": {"keyword", "startfrom"},
}
FIND_KEYS_FIELDS = {
    "range": {"lastkey", "step", "limit"},
    "keynum": {"keynumidx", "firstkey", "step"},
}
ARGUMENT_FIELDS = {
    "arguments", "deprecated_since", "display", "key_spec_index", "multiple",
    "multiple_token", "name", "optional", "since", "token", "type",
}
ARGUMENT_TYPES = {
    "block", "double", "integer", "key", "oneof", "pattern", "pure-token",
    "string", "unix-time",
}
SUPPORTED_REDIS_SOURCES = {
    "7.2.0": {
        "commit": "29622276ecd7b74312798e6772744858a8a6f9bf",
        "source_url": "https://github.com/redis/redis/tree/29622276ecd7b74312798e6772744858a8a6f9bf/src/commands",
        "source_path": "src/commands/*.json",
        "source_sha256": "b33d68cd54eb28d43dcf9bd1fb23e81c0c2762e944c3fde8c9cdc33f0798e14c",
        "canonical_source": "hask-redis-mux/data/redis-7.2.0-commands.json",
        "counts": {"top_level": 242, "subcommands": 150, "total": 392},
    }
}
FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
ISO_CALENDAR_DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")


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
    return "{} {}".format(container.upper(), name)


def expect_mapping(value, description):
    if not isinstance(value, dict):
        raise AuditError("{} must be an object".format(description))
    return value


def expect_list(value, description):
    if not isinstance(value, list):
        raise AuditError("{} must be an array".format(description))
    return value


def reject_unexpected_fields(value, allowed_fields, description):
    unexpected = sorted(set(value) - allowed_fields)
    if unexpected:
        raise AuditError("{} has unexpected field {}".format(description, unexpected[0]))


def audit_string_list(value, description):
    value = expect_list(value, description)
    if not all(isinstance(item, str) for item in value):
        raise AuditError("{} must contain only strings".format(description))
    return value


def audit_key_spec(identity, index, key_spec):
    key_spec = expect_mapping(key_spec, "{} key spec {}".format(identity, index))
    reject_unexpected_fields(key_spec, KEY_SPEC_FIELDS, "{} key spec {}".format(identity, index))
    begin_search = expect_mapping(key_spec.get("begin_search"), "{} key spec {} begin_search".format(identity, index))
    find_keys = expect_mapping(key_spec.get("find_keys"), "{} key spec {} find_keys".format(identity, index))
    reject_unexpected_fields(begin_search, SUPPORTED_BEGIN_SEARCH, "{} key spec {} begin_search".format(identity, index))
    reject_unexpected_fields(find_keys, SUPPORTED_FIND_KEYS, "{} key spec {} find_keys".format(identity, index))
    if len(begin_search) != 1 or next(iter(begin_search)) not in SUPPORTED_BEGIN_SEARCH:
        raise AuditError("{} key spec {} has unsupported begin_search schema".format(identity, index))
    if len(find_keys) != 1 or next(iter(find_keys)) not in SUPPORTED_FIND_KEYS:
        raise AuditError("{} key spec {} has unsupported find_keys schema".format(identity, index))
    begin_kind, begin_value = next(iter(begin_search.items()))
    find_kind, find_value = next(iter(find_keys.items()))
    if begin_kind == "index":
        begin_value = expect_mapping(begin_value, "{} key spec {} index".format(identity, index))
        reject_unexpected_fields(begin_value, BEGIN_SEARCH_FIELDS[begin_kind], "{} key spec {} index".format(identity, index))
        if not isinstance(begin_value.get("pos"), int):
            raise AuditError("{} key spec {} index position is invalid".format(identity, index))
        if begin_value["pos"] <= 0:
            raise AuditError("{} key spec {} index position must be positive".format(identity, index))
    elif begin_kind == "keyword":
        begin_value = expect_mapping(begin_value, "{} key spec {} keyword".format(identity, index))
        reject_unexpected_fields(begin_value, BEGIN_SEARCH_FIELDS[begin_kind], "{} key spec {} keyword".format(identity, index))
        if not isinstance(begin_value.get("keyword"), str) or not isinstance(begin_value.get("startfrom"), int):
            raise AuditError("{} key spec {} keyword is invalid".format(identity, index))
        if not begin_value["keyword"] or begin_value["startfrom"] == 0:
            raise AuditError("{} key spec {} keyword is invalid".format(identity, index))
    elif begin_value is not None:
        raise AuditError("{} key spec {} unknown begin_search must be null".format(identity, index))
    if find_kind == "range":
        find_value = expect_mapping(find_value, "{} key spec {} range".format(identity, index))
        reject_unexpected_fields(find_value, FIND_KEYS_FIELDS[find_kind], "{} key spec {} range".format(identity, index))
        if not all(isinstance(find_value.get(field), int) for field in ("lastkey", "step", "limit")):
            raise AuditError("{} key spec {} range is invalid".format(identity, index))
        if (
            find_value["step"] <= 0
            or find_value["limit"] < 0
            or (find_value["lastkey"] < -1 and find_value["limit"] != 0)
        ):
            raise AuditError("{} key spec {} range bounds are invalid".format(identity, index))
    elif find_kind == "keynum":
        find_value = expect_mapping(find_value, "{} key spec {} keynum".format(identity, index))
        reject_unexpected_fields(find_value, FIND_KEYS_FIELDS[find_kind], "{} key spec {} keynum".format(identity, index))
        if not all(isinstance(find_value.get(field), int) for field in ("keynumidx", "firstkey", "step")):
            raise AuditError("{} key spec {} keynum is invalid".format(identity, index))
        if (
            find_value["keynumidx"] < 0
            or find_value["firstkey"] < 0
            or find_value["step"] <= 0
        ):
            raise AuditError("{} key spec {} keynum bounds are invalid".format(identity, index))
    elif find_value is not None:
        raise AuditError("{} key spec {} unknown find_keys must be null".format(identity, index))
    audit_string_list(key_spec.get("flags"), "{} key spec {} flags".format(identity, index))


def audit_argument(identity, path, argument, key_spec_count):
    description = "{} argument {}".format(identity, path)
    argument = expect_mapping(argument, description)
    reject_unexpected_fields(argument, ARGUMENT_FIELDS, description)
    if not isinstance(argument.get("name"), str) or not argument["name"]:
        raise AuditError("{} has no name".format(description))
    argument_type = argument.get("type")
    if argument_type not in ARGUMENT_TYPES:
        raise AuditError("{} has unsupported type".format(description))
    for field in ("optional", "multiple", "multiple_token"):
        if field in argument and not isinstance(argument[field], bool):
            raise AuditError("{} {} must be boolean".format(description, field))
    for field in ("token", "display", "since", "deprecated_since"):
        if field in argument and (
            not isinstance(argument[field], str)
            or (field == "token" and not argument[field])
        ):
            raise AuditError("{} {} must be a non-empty string".format(description, field))
    if argument.get("multiple_token", False) and (
        not argument.get("multiple", False) or "token" not in argument
    ):
        raise AuditError("{} multiple_token requires multiple and token".format(description))
    if "key_spec_index" in argument:
        key_spec_index = argument["key_spec_index"]
        if (
            argument_type not in {"key", "pattern"}
            or not isinstance(key_spec_index, int)
            or isinstance(key_spec_index, bool)
            or key_spec_index < 0
            or key_spec_index >= key_spec_count
        ):
            raise AuditError("{} key_spec_index is invalid".format(description))
    children = argument.get("arguments")
    if argument_type in {"block", "oneof"}:
        children = expect_list(children, "{} arguments".format(description))
        if not children:
            raise AuditError("{} arguments must not be empty".format(description))
        for index, child in enumerate(children):
            audit_argument(identity, "{}.{}".format(path, index), child, key_spec_count)
    elif children is not None:
        raise AuditError("{} arguments are only valid for block or oneof".format(description))


def argument_key_spec_indices(arguments):
    indices = []
    for argument in arguments:
        if "key_spec_index" in argument:
            indices.append(argument["key_spec_index"])
        indices.extend(argument_key_spec_indices(argument.get("arguments", [])))
    return indices


def audit_canonical_source(source, canonical_source_path, commands):
    try:
        contents = canonical_source_path.read_text(encoding="utf-8")
        canonical_source = json.loads(contents)
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError("cannot read canonical source {}: {}".format(canonical_source_path, error)) from error
    if contents != canonical_json(canonical_source):
        raise AuditError("canonical source is not canonical, sorted JSON")
    canonical_source = expect_mapping(canonical_source, "canonical source")
    for field in ("redis_commit", "source_url", "source_path", "commands"):
        if field not in canonical_source:
            raise AuditError("canonical source {} is missing".format(field))
    if (
        canonical_source["redis_commit"] != source["commit"]
        or canonical_source["source_url"] != source["source_url"]
        or canonical_source["source_path"] != source["source_path"]
    ):
        raise AuditError("canonical source provenance is not bound to the supported Redis source")
    if canonical_source["commands"] != commands:
        raise AuditError("snapshot commands do not match the canonical source")
    source_sha256 = hashlib.sha256(contents.encode("utf-8")).hexdigest()
    if source_sha256 != source["source_sha256"]:
        raise AuditError("canonical source digest mismatch")


def audit_snapshot(snapshot, canonical_source_path=None):
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
    if not FULL_GIT_SHA.fullmatch(provenance["redis_commit"]):
        raise AuditError("provenance redis_commit must be a full SHA")
    if not SHA256.fullmatch(provenance["source_sha256"]):
        raise AuditError("provenance source_sha256 must be a lowercase SHA-256")
    try:
        if not ISO_CALENDAR_DATE.fullmatch(provenance["retrieved_at"]):
            raise ValueError
        datetime.datetime.strptime(provenance["retrieved_at"], "%Y-%m-%d")
    except ValueError:
        raise AuditError("provenance retrieved_at must be an ISO calendar date")
    source = SUPPORTED_REDIS_SOURCES.get(provenance["redis_version_tag"])
    if source is None:
        raise AuditError("unsupported Redis source provenance")
    for field in ("redis_commit", "source_url", "source_path", "source_sha256"):
        source_field = "commit" if field == "redis_commit" else field
        if provenance[field] != source[source_field]:
            raise AuditError("provenance {} is not bound to the supported Redis source".format(field))
    commands = expect_list(snapshot.get("commands"), "commands")
    identities = []
    top_level = 0
    subcommands = 0
    kinds = {"fixed": 0, "range": 0, "keyword": 0, "movable": 0}
    for index, command in enumerate(commands):
        command = expect_mapping(command, "command {}".format(index))
        reject_unexpected_fields(command, COMMAND_FIELDS, "command {}".format(index))
        if not isinstance(command.get("name"), str) or not command["name"]:
            raise AuditError("command {} has no name".format(index))
        metadata = expect_mapping(command.get("metadata"), "command {} metadata".format(command["name"]))
        reject_unexpected_fields(metadata, COMMAND_METADATA_FIELDS, "{} metadata".format(command["name"]))
        identity = command_identity(command)
        identities.append(identity)
        if "container" in metadata:
            subcommands += 1
        else:
            top_level += 1
        if not isinstance(metadata.get("arity"), int):
            raise AuditError("{} is missing arity".format(identity))
        if "command_flags" in metadata:
            audit_string_list(metadata["command_flags"], "{} command_flags".format(identity))
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
        arguments = metadata.get("arguments", [])
        arguments = expect_list(arguments, "{} arguments".format(identity))
        for argument_index, argument in enumerate(arguments):
            audit_argument(identity, str(argument_index), argument, len(key_specs))
        linked_key_specs = set(argument_key_spec_indices(arguments))
        for spec_index, key_spec in enumerate(key_specs):
            if (
                spec_index not in linked_key_specs
                and "NOT_KEY" not in key_spec["flags"]
            ):
                raise AuditError(
                    "{} key spec {} is not linked from its argument grammar".format(
                        identity, spec_index
                    )
                )
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
    audit_canonical_source(
        source,
        canonical_source_path or ROOT / source["canonical_source"],
        commands,
    )
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


def hs_maybe_string(value):
    return "Nothing" if value is None else "Just {}".format(hs_string(value))


def hs_maybe_int(value):
    return "Nothing" if value is None else "Just {}".format(hs_int(value))


def render_argument(argument):
    argument_type = argument["type"]
    if argument_type == "string":
        kind = "ArgumentString"
    elif argument_type == "integer":
        kind = "ArgumentInteger"
    elif argument_type == "double":
        kind = "ArgumentDouble"
    elif argument_type == "unix-time":
        kind = "ArgumentUnixTime"
    elif argument_type == "key":
        kind = "ArgumentKey"
    elif argument_type == "pattern":
        kind = "ArgumentPattern"
    elif argument_type == "pure-token":
        kind = "ArgumentPureToken"
    else:
        children = ", ".join(render_argument(child) for child in argument["arguments"])
        constructor = "ArgumentBlock" if argument_type == "block" else "ArgumentOneOf"
        kind = "{} [{}]".format(constructor, children)
    token = argument.get("token")
    if argument_type == "pure-token" and token is None:
        token = argument["name"]
    return "CommandArgument {} ({}) ({}) {} {} {} ({})".format(
        hs_string(argument["name"]),
        kind,
        hs_maybe_string(token),
        str(argument.get("optional", False)),
        str(argument.get("multiple", False)),
        str(argument.get("multiple_token", False)),
        hs_maybe_int(argument.get("key_spec_index")),
    )


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
        "  , ArgumentKind (..)",
        "  , CommandArgument (..)",
        "  , CommandMetadata (..)",
        "  , commandMetadata",
        "  , commandMetadataByIdentity",
        "  ) where",
        "",
        "import           Data.ByteString (ByteString)",
        "import qualified Data.Map.Strict as Map",
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
        "  , keySpecFlags       :: [ByteString]",
        "  } deriving (Eq, Show)",
        "",
        "data ArgumentKind",
        "  = ArgumentString",
        "  | ArgumentInteger",
        "  | ArgumentDouble",
        "  | ArgumentUnixTime",
        "  | ArgumentKey",
        "  | ArgumentPattern",
        "  | ArgumentPureToken",
        "  | ArgumentOneOf [CommandArgument]",
        "  | ArgumentBlock [CommandArgument]",
        "  deriving (Eq, Show)",
        "",
        "data CommandArgument = CommandArgument",
        "  { argumentName          :: ByteString",
        "  , argumentKind          :: ArgumentKind",
        "  , argumentToken         :: Maybe ByteString",
        "  , argumentOptional      :: Bool",
        "  , argumentMultiple      :: Bool",
        "  , argumentMultipleToken :: Bool",
        "  , argumentKeySpecIndex  :: Maybe Int",
        "  } deriving (Eq, Show)",
        "",
        "data CommandMetadata = CommandMetadata",
        "  { commandIdentity       :: ByteString",
        "  , commandArity          :: Int",
        "  , commandFlags          :: [ByteString]",
        "  , commandKeySpecs       :: [KeySpec]",
        "  , commandArguments      :: [CommandArgument]",
        "  , commandHasSubcommands :: Bool",
        "  } deriving (Eq, Show)",
        "",
        "commandMetadata :: [CommandMetadata]",
        "commandMetadata =",
        "  [",
    ]
    entries = []
    container_identities = {
        command_identity(command).split(" ", 1)[0]
        for command in commands
        if "container" in command["metadata"]
    }
    for command in commands:
        metadata = command["metadata"]
        specs = metadata["key_specs"]
        arguments = metadata.get("arguments", [])
        rendered_specs = ", ".join(
            "KeySpec ({}) ({}) [{}]".format(
                render_begin_search(spec),
                render_find_keys(spec),
                ", ".join(hs_string(flag) for flag in spec["flags"]),
            )
            for spec in specs
        )
        rendered_arguments = ", ".join(render_argument(argument) for argument in arguments)
        identity = command_identity(command)
        entries.append(
            '    CommandMetadata {} {} [{}] [{}] [{}] {}'.format(
                hs_string(identity),
                "({})".format(metadata["arity"]),
                ", ".join(hs_string(flag) for flag in metadata.get("command_flags", [])),
                rendered_specs,
                rendered_arguments,
                str(identity in container_identities),
            )
        )
    lines.append(",\n".join(entries))
    lines.extend([
        "  ]",
        "",
        "commandMetadataByIdentity :: Map.Map ByteString CommandMetadata",
        "commandMetadataByIdentity =",
        "  Map.fromList [(commandIdentity metadata, metadata) | metadata <- commandMetadata]",
        "",
    ])
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
    parser.add_argument(
        "--canonical-source",
        type=Path,
        help="override the checked-in canonical source bundle for audit testing",
    )
    parser.add_argument("--audit", action="store_true", help="verify snapshot and generated module without writing")
    args = parser.parse_args()
    try:
        snapshot = load_snapshot(args.snapshot)
        commands = audit_snapshot(snapshot, args.canonical_source)
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
