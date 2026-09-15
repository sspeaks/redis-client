#!/usr/bin/env python3

import json
import sys
from pathlib import Path
from typing import Any, Dict, Tuple


KEYS = (
    ("metrics", "ops_per_second"),
    ("metrics", "latency_micros", "p50"),
    ("metrics", "latency_micros", "p95"),
    ("metrics", "latency_micros", "p99"),
    ("metrics", "latency_micros", "p999"),
    ("metrics", "allocation_bytes_per_op"),
    ("metrics", "peak_residency_bytes"),
    ("metrics", "gc_cpu_percent"),
    ("metrics", "queue_high_water"),
    ("metrics", "in_flight_high_water"),
)


def load(path: str) -> Dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def lookup(document: Dict[str, Any], path: Tuple[str, ...]) -> float:
    value = document
    for key in path:
        value = value[key]
    return value


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: compare-benchmark-results.py BEFORE.json AFTER.json", file=sys.stderr)
        return 2

    before = load(sys.argv[1])
    after = load(sys.argv[2])

    print(f"before: {sys.argv[1]}")
    print(f"after:  {sys.argv[2]}")
    print("")

    for path in KEYS:
        before_value = lookup(before, path)
        after_value = lookup(after, path)
        delta = after_value - before_value
        label = ".".join(path)
        print(f"{label}: before={before_value} after={after_value} delta={delta}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
