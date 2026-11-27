#!/usr/bin/env python3
"""Check the proof run without trusting what the agent wrote.

Builds the library from clean sources in a fresh container, with no agent and no
model access, and compares the store path of its toolchain with the agent's
answer. The path's hash covers the toolchain's inputs, so it comes from Nix, not
from knowing a version. That the agent's own run fetched the toolchain comes
from the host's egress events.
"""

import argparse
import json
import re
import secrets
import sys
import tempfile
import threading
from pathlib import Path

import proxy
import run_agent
from workspace_patch import blob_id

BUILD = "nix-shell --run 'cabal build -v0 hask-redis-mux >&2 && ghc --print-libdir'"
TOOLCHAIN_BYTES = 100 * 1024 * 1024
LIBDIR = re.compile(r"/nix/store/[0-9a-z]{32}-ghc-[A-Za-z0-9.+_/-]+")


def expected_patch(content):
    """The only patch that adds factory-proof.txt with this one line."""
    line = content.removesuffix("\n")
    missing = "" if content.endswith("\n") else "\\ No newline at end of file\n"
    return (
        "diff --git a/factory-proof.txt b/factory-proof.txt\n"
        "new file mode 100644\n"
        f"index {'0' * 40}..{blob_id(content.encode())}\n"
        "--- /dev/null\n"
        "+++ b/factory-proof.txt\n"
        "@@ -0,0 +1 @@\n"
        f"+{line}\n{missing}"
    ).encode()


def failures(output, libdir):
    """Compare the agent's files with the toolchain path built independently."""
    found = []
    if json.loads((output / "result.json").read_text()).get("outcome") != "success":
        found.append("the run did not end in success")
    patch_file = output / "agent.patch"
    patch = patch_file.read_bytes() if patch_file.exists() else b""
    if not LIBDIR.fullmatch(libdir):
        found.append("the independent build did not report a toolchain path")
    elif patch not in (expected_patch(libdir + "\n"), expected_patch(libdir)):
        found.append("the patch is not exactly the toolchain path of the independent build")
    events = map(json.loads, (output / "proxy-events.jsonl").read_text().splitlines())
    fetched = sum(
        event["bytes"]
        for event in events
        if event["kind"] == "tunnel" and event["host"] == "cache.nixos.org"
    )
    if fetched < TOOLCHAIN_BYTES:
        found.append("the agent's run did not fetch the Nix toolchain")
    return found


def independent_build(image, sources):
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="factory-") as directory:
        scratch = Path(directory)
        sockets = scratch / "s"
        sockets.mkdir()
        egress = proxy.EgressProxy(sockets / "egress.sock", lambda event: None)
        threading.Thread(target=egress.serve_forever, daemon=True).start()
        name = f"factory-{secrets.token_hex(8)}"
        command = run_agent.sandbox_command(name, sources, sockets) + [
            image, "--relay-only", "bash", "-c", BUILD,
        ]  # fmt: skip
        code, _, gone = run_agent.run_container(
            command, name, 30 * 60, scratch / "out", scratch / "err"
        )
        if code != 0 or not gone:
            return ""
        return (scratch / "out").read_text(errors="replace").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True, help="a fresh export")
    arguments = parser.parse_args()
    libdir = independent_build(arguments.image, arguments.sources.resolve(strict=True))
    problems = failures(arguments.output, libdir)
    print("\n".join(problems) or "Proof task completed.")
    return bool(problems)


if __name__ == "__main__":
    sys.exit(main())
