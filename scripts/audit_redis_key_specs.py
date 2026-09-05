#!/usr/bin/env python3
"""Audit the Redis grammar against immutable Redis OSS command metadata.

This intentionally fetches the JSON files, rather than accepting a successful
HTTP response as evidence.  `--negative` corrupts an expected entry and is
used by CI to prove the comparison is capable of detecting a mismatch.
"""
import argparse
import json
import sys
from urllib.request import urlopen

SHA = "9913c926510755fa0d241658f550338a02258edb"
BASE = "https://raw.githubusercontent.com/redis/redis/%s/src/commands/" % SHA

# Every movable/later/multiple-key grammar form maintained in Commands.hs.
# `arity` and the key-spec search/find mechanisms are semantic Redis metadata,
# not a merely successful download check.
EXPECTED = {
    "set": (-3, "index", "range"),
    "memory": (-2, None, None),
    "object": (-2, None, None),
    "zunion": (-3, "index", "keynum"),
    "zinter": (-3, "index", "keynum"),
    "zdiff": (-3, "index", "keynum"),
    "eval": (-3, "index", "keynum"),
    "evalsha": (-3, "index", "keynum"),
    "fcall": (-3, "index", "keynum"),
    "xread": (-4, "keyword", "range"),
    "xreadgroup": (-7, "keyword", "range"),
    "copy": (-3, "index", "range"),
    "geosearch": (-7, "index", "range"),
    "georadius": (-6, "index", "range"),
}

def fetch(path):
    url = BASE + path + ".json"
    with urlopen(url) as response:
        if response.status != 200 or SHA not in response.url:
            raise RuntimeError("unverified Redis source URL: %s" % response.url)
        return json.load(response)

def audit(expected):
    failures = []
    for path, (arity, search, finder) in expected.items():
        document = fetch(path)
        command, metadata = next(iter(document.items()))
        if command.lower().replace(" ", "-") != path:
            failures.append("%s: source command/path mismatch (%s)" % (path, command))
        if metadata.get("arity") != arity:
            failures.append("%s: arity %r != %r" % (path, metadata.get("arity"), arity))
        if search is not None:
            specs = metadata.get("key_specs", [])
            if not specs or search not in specs[0].get("begin_search", {}):
                failures.append("%s: missing %s key search" % (path, search))
            if not specs or finder not in specs[0].get("find_keys", {}):
                failures.append("%s: missing %s key finder" % (path, finder))
    return failures

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative", action="store_true",
                        help="intentionally prove mismatch detection")
    args = parser.parse_args()
    expected = dict(EXPECTED)
    if args.negative:
        arity, search, finder = expected["set"]
        expected["set"] = (arity - 1, search, finder)
    failures = audit(expected)
    if args.negative:
        if not failures:
            print("negative audit failed to detect deliberate mismatch", file=sys.stderr)
            return 1
        print("negative audit detected mismatch: " + failures[0])
        return 0
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Redis 7.2.12 key-spec audit passed (%d forms, %s)" % (len(expected), SHA))
    return 0

if __name__ == "__main__":
    sys.exit(main())
