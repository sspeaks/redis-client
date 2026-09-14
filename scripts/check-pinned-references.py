#!/usr/bin/env python3
"""Reject mutable GitHub Action and externally pulled container references."""

import argparse
import re
import sys
from pathlib import Path


ACTION_REFERENCE = re.compile(r"^\s*-\s*uses:\s*([^\s#]+)")
IMAGE_REFERENCE = re.compile(r"^\s*image:\s*([^\s#]+)")
PINNED_ACTION = re.compile(r"^[^@/\s]+/[^@\s]+@[0-9a-f]{40}$")
PINNED_IMAGE = re.compile(r"^[^@\s]+:[^@\s]+@sha256:[0-9a-f]{64}$")
REDIS_DOCKER_COMMAND = re.compile(r"\bdocker\s+(?:pull|run)\b.*?\b(redis[^\s\\]*)")
LOCAL_TEST_IMAGE = "${REDIS_E2E_IMAGE:-e2etests:latest}"


def references_in(path, pattern):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = pattern.match(line)
        if match:
            yield line_number, match.group(1).strip("'\"")


def validate_actions(root, failures):
    workflows = root / ".github" / "workflows"
    for path in sorted((*workflows.glob("*.yml"), *workflows.glob("*.yaml"))):
        for line_number, reference in references_in(path, ACTION_REFERENCE):
            if reference.startswith("./"):
                continue
            if not PINNED_ACTION.fullmatch(reference):
                failures.append(
                    f"{path.relative_to(root)}:{line_number}: mutable action reference {reference}"
                )


def is_local_test_image(reference):
    return reference == LOCAL_TEST_IMAGE


def validate_compose_images(root, failures):
    for path in sorted(root.glob("docker/**/docker-compose.y*ml")):
        for line_number, reference in references_in(path, IMAGE_REFERENCE):
            if is_local_test_image(reference):
                continue
            if not PINNED_IMAGE.fullmatch(reference):
                failures.append(
                    f"{path.relative_to(root)}:{line_number}: unpinned external image {reference}"
                )


def validate_redis_docker_commands(root, failures):
    for path in sorted((root / "docker").glob("**/*.sh")):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = REDIS_DOCKER_COMMAND.search(line)
            if match and not PINNED_IMAGE.fullmatch(match.group(1)):
                failures.append(
                    f"{path.relative_to(root)}:{line_number}: unpinned external image "
                    f"{match.group(1)}"
                )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[1])
    root = parser.parse_args().root.resolve()
    failures = []
    validate_actions(root, failures)
    validate_compose_images(root, failures)
    validate_redis_docker_commands(root, failures)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Pinned reference checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
