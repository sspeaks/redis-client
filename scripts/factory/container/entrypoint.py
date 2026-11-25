"""Container entry point: probe the sandbox, run the agent, probe again.

Also relays two loopback TCP ports to the proxy sockets, because the container
has no network and its tools cannot speak HTTP proxying over a Unix socket.
"""

import json
import os
import socket
import socketserver
import subprocess
import sys
import threading

import probe

ROUTES = {8080: "/run/factory/model.sock", 8081: "/run/factory/egress.sock"}


def pump(source, target):
    try:
        while data := source.recv(65536):
            target.sendall(data)
        target.shutdown(socket.SHUT_WR)
    except OSError:
        pass


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.socket(socket.AF_UNIX) as upstream:
            try:
                upstream.connect(ROUTES[self.server.server_address[1]])
            except OSError:
                return
            back = threading.Thread(target=pump, args=(upstream, self.request), daemon=True)
            back.start()
            pump(self.request, upstream)
            back.join()


class RelayServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def report(phase):
    failures = probe.run()
    print(
        json.dumps(
            {"type": "factory_probe", "phase": phase, "ok": not failures, "failures": failures}
        ),
        flush=True,
    )
    return not failures


def main():
    for port in ROUTES:
        server = RelayServer(("127.0.0.1", port), Relay)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    relay_only = sys.argv[1] == "--relay-only"  # For checks that run no agent.
    if not relay_only and not report("before"):
        return 97
    os.chdir("/workspace")
    subprocess.run(["git", "init", "-q", "."], check=True)  # The Nix shell hook needs one.
    if relay_only:
        return subprocess.run(sys.argv[2:], stdin=subprocess.DEVNULL).returncode
    for command in (
        ["git", "add", "-A"],
        ["git", "-c", "user.name=factory", "-c", "user.email=factory@localhost",
         "commit", "-q", "--no-verify", "-m", "base"],
    ):  # fmt: skip
        subprocess.run(command, check=True)
    with open("/prompt", "rb") as prompt:
        code = subprocess.run(sys.argv[1:], stdin=prompt).returncode
    return code if report("after") else 97


if __name__ == "__main__":
    sys.exit(main())
