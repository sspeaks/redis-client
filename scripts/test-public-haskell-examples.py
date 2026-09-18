#!/usr/bin/env python3

import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

COMPONENTS = {
    "root-readme": {
        "dependencies": [
            "base >= 4.19 && < 5",
            "hask-redis-mux",
        ],
        "markdown": {
            Path("README.md"): 2,
        },
        "haddock": {},
    },
    "library-docs": {
        "dependency_document": Path("hask-redis-mux/README.md"),
        "markdown": {
            Path("hask-redis-mux/README.md"): 6,
        },
        "haddock": {
            Path("hask-redis-mux/lib/redis/Database/Redis.hs"): 3,
            Path("hask-redis-mux/lib/cluster/Database/Redis/Standalone.hs"): 4,
            Path("hask-redis-mux/lib/cluster/Database/Redis/Connector.hs"): 5,
        },
    },
}


def markdown_blocks(text):
    return re.findall(r"```haskell[ \t]*\n(.*?)```", text, re.DOTALL)


def documented_dependencies(relative_path):
    text = (ROOT / relative_path).read_text()
    blocks = re.findall(r"```cabal[ \t]*\n(.*?)```", text, re.DOTALL)
    if len(blocks) != 1:
        raise ValueError(
            f"{relative_path}: expected one Cabal dependency block, "
            f"found {len(blocks)}"
        )

    lines = [line.strip() for line in blocks[0].splitlines()]
    if not lines or lines[0] != "build-depends:":
        raise ValueError(
            f"{relative_path}: Cabal block must start with build-depends:"
        )

    dependencies = [line.rstrip(",") for line in lines[1:] if line]
    if not dependencies:
        raise ValueError(f"{relative_path}: build-depends is empty")
    return ["base >= 4.19 && < 5", *dependencies]


def haddock_blocks(text):
    blocks = []
    current = None
    for line in text.splitlines():
        if line == "-- @":
            if current is None:
                current = []
            else:
                blocks.append("\n".join(current) + "\n")
                current = None
            continue
        if current is not None:
            match = re.fullmatch(r"--(?: (.*))?", line)
            if match is None:
                raise ValueError("Haddock example contains a non-comment line")
            current.append(match.group(1) or "")
    if current is not None:
        raise ValueError("Haddock example is missing its closing -- @")
    return blocks


def decoded_haddock(block):
    return block.replace(r"\\", "\\").replace(r"\"", '"')


def add_module_name(source, module_name):
    lines = source.splitlines()
    insert_at = 0
    while insert_at < len(lines):
        line = lines[insert_at]
        if line.startswith("{-#") or not line.strip():
            insert_at += 1
            continue
        break
    lines.insert(insert_at, f"module {module_name} where")
    return "\n".join(lines) + "\n"


def collect_examples(component):
    examples = []
    for relative_path, expected_count in component["markdown"].items():
        blocks = markdown_blocks((ROOT / relative_path).read_text())
        if len(blocks) != expected_count:
            raise ValueError(
                f"{relative_path}: expected {expected_count} Haskell blocks, "
                f"found {len(blocks)}"
            )
        examples.extend(
            (relative_path, index, block)
            for index, block in enumerate(blocks, 1)
        )

    for relative_path, expected_count in component["haddock"].items():
        blocks = haddock_blocks((ROOT / relative_path).read_text())
        if len(blocks) != expected_count:
            raise ValueError(
                f"{relative_path}: expected {expected_count} Haddock blocks, "
                f"found {len(blocks)}"
            )
        examples.extend(
            (relative_path, index, decoded_haddock(block))
            for index, block in enumerate(blocks, 1)
        )
    return examples


def component_dependencies(component):
    dependency_document = component.get("dependency_document")
    if dependency_document is not None:
        return documented_dependencies(dependency_document)
    return component["dependencies"]


def cabal_component(name, dependencies, modules):
    dependency_lines = ",\n      ".join(dependencies)
    module_lines = "\n      ".join(modules)
    return f"""
library {name}
    exposed-modules:
      {module_lines}
    hs-source-dirs: {name}
    build-depends:
      {dependency_lines}
    default-language: GHC2021
"""


def main():
    try:
        component_examples = {
            name: collect_examples(component)
            for name, component in COMPONENTS.items()
        }
    except ValueError as error:
        print(f"public example discovery failed: {error}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="redis-public-examples-") as temp_dir:
        temp_root = Path(temp_dir)
        cabal_components = []
        example_count = 0

        for component_name, examples in component_examples.items():
            source_dir = temp_root / component_name
            source_dir.mkdir()
            modules = []

            for source_path, block_index, source in examples:
                example_count += 1
                module_name = f"PublicExample{example_count}"
                modules.append(module_name)
                output_path = source_dir / f"{module_name}.hs"
                output_path.write_text(
                    f"-- Source: {source_path} example {block_index}\n"
                    + add_module_name(source, module_name)
                )

            cabal_components.append(
                cabal_component(
                    component_name,
                    component_dependencies(COMPONENTS[component_name]),
                    modules,
                )
            )

        (temp_root / "public-haskell-examples.cabal").write_text(
            """cabal-version: 3.0
name: public-haskell-examples
version: 0.0.0
build-type: Simple
"""
            + "".join(cabal_components)
        )
        (temp_root / "cabal.project").write_text(
            f"""packages:
  {ROOT / "hask-redis-mux"}
  .
"""
        )

        result = subprocess.run(
            [
                "cabal",
                "build",
                "--offline",
                "--project-file=cabal.project",
                "all",
            ],
            cwd=temp_root,
        )
        if result.returncode != 0:
            return result.returncode

    print(
        f"Compiled {example_count} public Haskell examples "
        f"in {len(COMPONENTS)} isolated consumer components."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
