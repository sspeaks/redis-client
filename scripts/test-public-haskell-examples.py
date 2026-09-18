#!/usr/bin/env python3

import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

MARKDOWN_EXAMPLES = {
    Path("README.md"): 2,
    Path("hask-redis-mux/README.md"): 6,
}

HADDOCK_EXAMPLES = {
    Path("hask-redis-mux/lib/redis/Database/Redis.hs"): 3,
    Path("hask-redis-mux/lib/cluster/Database/Redis/Standalone.hs"): 4,
    Path("hask-redis-mux/lib/cluster/Database/Redis/Connector.hs"): 5,
}


def markdown_blocks(text):
    return re.findall(r"```haskell[ \t]*\n(.*?)```", text, re.DOTALL)


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


def collect_examples():
    examples = []
    for relative_path, expected_count in MARKDOWN_EXAMPLES.items():
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

    for relative_path, expected_count in HADDOCK_EXAMPLES.items():
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


def main():
    try:
        examples = collect_examples()
    except ValueError as error:
        print(f"public example discovery failed: {error}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="redis-public-examples-") as temp_dir:
        generated = []
        for sequence, (source_path, block_index, source) in enumerate(examples, 1):
            module_name = f"PublicExample{sequence}"
            source_name = re.sub(r"[^A-Za-z0-9]+", "-", str(source_path)).strip("-")
            output_path = Path(temp_dir) / f"{source_name}-example-{block_index}.hs"
            output_path.write_text(
                f"-- Source: {source_path} example {block_index}\n"
                + add_module_name(source, module_name)
            )
            generated.append(str(output_path))

        command = [
            "cabal",
            "exec",
            "--",
            "ghc",
            "-fno-code",
            "-fforce-recomp",
            "-XGHC2021",
            "-package",
            "hask-redis-mux",
            *generated,
        ]
        result = subprocess.run(command, cwd=ROOT)
        if result.returncode != 0:
            return result.returncode

    print(f"Compiled {len(examples)} public Haskell examples.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
