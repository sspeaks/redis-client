#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
from dataclasses import dataclass
from typing import Any

REDIS_SOURCE_SHA = "ae6a2aa95cd094b032e7a69b8b59f64dd1ed085f"  # redis 7.2.6
ROOT = pathlib.Path(__file__).resolve().parent.parent
COMMANDS_DIR = ROOT / "vendor" / "redis-7.2.6-commands"
OUT_PATH = ROOT / "hask-redis-mux" / "lib" / "cluster" / "Database" / "Redis" / "Cluster" / "Commands" / "Generated.hs"


def hs_bs(value: str) -> str:
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def bool_lit(v: bool) -> str:
    return "True" if v else "False"


@dataclass(frozen=True)
class Arg:
    type: str
    name: str
    token: str | None
    optional: bool
    multiple: bool
    key_spec_index: int | None
    children: tuple["Arg", ...]
    alternatives: tuple[tuple["Arg", ...], ...]


@dataclass(frozen=True)
class Spec:
    tokens: tuple[str, ...]
    arity: int
    flags: tuple[str, ...]
    args: tuple[Arg, ...]


def normalize_arg(raw: dict[str, Any]) -> Arg:
    alternatives: list[tuple[Arg, ...]] = []
    if raw.get("type") == "oneof":
        for option in raw.get("arguments", []):
            option_type = option.get("type")
            if option_type in ("block", "oneof"):
                option_nodes = (normalize_arg(option),)
            else:
                option_nodes = (normalize_arg(option),)
            alternatives.append(option_nodes)
    return Arg(
        type=raw.get("type", "string"),
        name=raw.get("name", ""),
        token=raw.get("token"),
        optional=bool(raw.get("optional", False)),
        multiple=bool(raw.get("multiple", False)),
        key_spec_index=raw.get("key_spec_index"),
        children=tuple(normalize_arg(x) for x in raw.get("arguments", []) if raw.get("type") != "oneof"),
        alternatives=tuple(alternatives),
    )


def normalize_spec(name: str, raw: dict[str, Any]) -> Spec:
    tokens_parts: list[str] = []
    container = raw.get("container")
    if container:
        tokens_parts.extend(container.split("|"))
    tokens_parts.extend(name.split("|"))
    tokens = tuple(token.upper() for token in tokens_parts)
    flags = tuple(flag.upper() for flag in raw.get("command_flags", []))
    args = tuple(normalize_arg(arg) for arg in raw.get("arguments", []))
    return Spec(tokens=tokens, arity=int(raw.get("arity", 0)), flags=flags, args=args)


def load_specs() -> list[Spec]:
    specs: list[Spec] = []
    for path in sorted(COMMANDS_DIR.glob("*.json")):
        data = json.loads(path.read_text())
        for name, raw in data.items():
            specs.append(normalize_spec(name, raw))
    specs.sort(key=lambda spec: spec.tokens)
    return specs


def emit_arg(arg: Arg, indent: str) -> list[str]:
    lines = [f"{indent}GeneratedArgument"]
    lines.append(f"{indent}  {{ gaType = {hs_bs(arg.type)}")
    lines.append(f"{indent}  , gaName = {hs_bs(arg.name)}")
    token = "Nothing" if arg.token is None else f"Just {hs_bs(arg.token)}"
    lines.append(f"{indent}  , gaToken = {token}")
    lines.append(f"{indent}  , gaOptional = {bool_lit(arg.optional)}")
    lines.append(f"{indent}  , gaMultiple = {bool_lit(arg.multiple)}")
    key_idx = "Nothing" if arg.key_spec_index is None else f"Just {arg.key_spec_index}"
    lines.append(f"{indent}  , gaKeySpecIndex = {key_idx}")
    if arg.children:
        lines.append(f"{indent}  , gaChildren =")
        lines.append(f"{indent}      [")
        child_lines: list[str] = []
        for idx, child in enumerate(arg.children):
            emitted = emit_arg(child, indent + "        ")
            if idx + 1 < len(arg.children):
                emitted[-1] = emitted[-1] + ","
            child_lines.extend(emitted)
        lines.extend(child_lines)
        lines.append(f"{indent}      ]")
    else:
        lines.append(f"{indent}  , gaChildren = []")

    if arg.alternatives:
        lines.append(f"{indent}  , gaAlternatives =")
        lines.append(f"{indent}      [")
        alt_blocks: list[str] = []
        for alt_idx, alt in enumerate(arg.alternatives):
            alt_blocks.append(f"{indent}        [")
            for arg_idx, alt_arg in enumerate(alt):
                emitted = emit_arg(alt_arg, indent + "          ")
                if arg_idx + 1 < len(alt):
                    emitted[-1] = emitted[-1] + ","
                alt_blocks.extend(emitted)
            suffix = "]" + ("," if alt_idx + 1 < len(arg.alternatives) else "")
            alt_blocks.append(f"{indent}        {suffix}")
        lines.extend(alt_blocks)
        lines.append(f"{indent}      ]")
    else:
        lines.append(f"{indent}  , gaAlternatives = []")

    lines.append(f"{indent}  }}")
    return lines


def emit_spec(spec: Spec, indent: str = "  ") -> list[str]:
    lines = [f"{indent}GeneratedCommandSpec"]
    tokens = ", ".join(hs_bs(token) for token in spec.tokens)
    lines.append(f"{indent}  {{ gcsTokens = [{tokens}]")
    lines.append(f"{indent}  , gcsArity = {spec.arity}")
    flags = ", ".join(hs_bs(flag) for flag in spec.flags)
    lines.append(f"{indent}  , gcsFlags = [{flags}]")
    if spec.args:
        lines.append(f"{indent}  , gcsArguments =")
        lines.append(f"{indent}      [")
        arg_lines: list[str] = []
        for idx, arg in enumerate(spec.args):
            emitted = emit_arg(arg, indent + "        ")
            if idx + 1 < len(spec.args):
                emitted[-1] = emitted[-1] + ","
            arg_lines.extend(emitted)
        lines.extend(arg_lines)
        lines.append(f"{indent}      ]")
    else:
        lines.append(f"{indent}  , gcsArguments = []")
    lines.append(f"{indent}  }}")
    return lines


def generate_haskell(specs: list[Spec]) -> str:
    lines: list[str] = []
    lines.append("{-# LANGUAGE OverloadedStrings #-}")
    lines.append("")
    lines.append("module Database.Redis.Cluster.Commands.Generated")
    lines.append("  ( redis72SourceSha")
    lines.append("  , generatedSupportedFormsCount")
    lines.append("  , generatedCommandSpecs")
    lines.append("  ) where")
    lines.append("")
    lines.append("import Database.Redis.Cluster.Commands.Spec")
    lines.append("")
    lines.append(f"redis72SourceSha :: String")
    lines.append(f"redis72SourceSha = \"{REDIS_SOURCE_SHA}\"")
    lines.append("")
    lines.append("generatedSupportedFormsCount :: Int")
    lines.append(f"generatedSupportedFormsCount = {len(specs)}")
    lines.append("")
    lines.append("-- Generated from vendor/redis-7.2.6/src/commands/*.json")
    lines.append("-- by scripts/generate_cluster_routing.py")
    lines.append("")
    lines.append("generatedCommandSpecs :: [GeneratedCommandSpec]")
    lines.append("generatedCommandSpecs =")
    lines.append("  [")
    for idx, spec in enumerate(specs):
        emitted = emit_spec(spec)
        if idx + 1 < len(specs):
            emitted[-1] = emitted[-1] + ","
        lines.extend(emitted)
    lines.append("  ]")
    lines.append("")
    return "\n".join(lines)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if not COMMANDS_DIR.exists():
        raise SystemExit(f"Missing Redis metadata directory: {COMMANDS_DIR}")

    specs = load_specs()
    generated = generate_haskell(specs)

    if args.check:
        current = OUT_PATH.read_text() if OUT_PATH.exists() else ""
        if normalize_for_semantic_compare(current) != normalize_for_semantic_compare(generated):
            raise SystemExit("Generated routing artifact is stale: run scripts/generate_cluster_routing.py")
        print("Generated routing artifact is up-to-date")
        return

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(generated)
    print(f"Wrote {OUT_PATH}")


def normalize_for_semantic_compare(text: str) -> str:
    keep: list[str] = []
    for line in text.splitlines():
      stripped = line.strip()
      if stripped.startswith("--"):
        continue
      if stripped == "":
        continue
      keep.append(stripped)
    return "\n".join(keep)


if __name__ == "__main__":
    main()
