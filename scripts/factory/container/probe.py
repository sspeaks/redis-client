"""Search the agent container for credentials and for ways out of it.

Every check returns a list of failures. Findings name a place, never a secret.
"""

import http.client
import json
import os
import re
import socket
import ssl
import stat
import subprocess
from pathlib import Path

BLOCK = 4 * 1024 * 1024
OVERLAP = 512
TOKEN = re.compile(
    rb"sk-ant-(?:oat|ort|api|admin|sid)[0-9]{2}-[A-Za-z0-9_-]{20,}"
    rb"|gh[pousr]_[A-Za-z0-9]{36,}"
    rb"|github_pat_[A-Za-z0-9_]{30,}"
    rb"|AUTHORIZATION: basic [A-Za-z0-9+/=]{20,}",
    re.IGNORECASE,
)
# Lower case. Every match of TOKEN, in any case, contains one of these, so
# looking for them first only saves time on a large disk.
MARKERS = (
    b"sk-ant-", b"ghp_", b"gho_", b"ghu_", b"ghs_", b"ghr_", b"github_pat_",
    b"authorization: basic ",
)  # fmt: skip


def has_token(data):
    lowered = data.lower()
    return any(marker in lowered for marker in MARKERS) and bool(TOKEN.search(data))


FORBIDDEN_NAMES = re.compile(
    r"^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_REFRESH_TOKEN|GITHUB_TOKEN"
    r"|GH_TOKEN|ACTIONS_.*TOKEN.*|DOCKER_HOST)$"
)
EXPECTED_SOCKETS = frozenset({"/run/factory/model.sock", "/run/factory/egress.sock"})
EGRESS = ("127.0.0.1", 8081)
MODEL = ("127.0.0.1", 8080)
ALLOWED_HOSTS = ["cache.nixos.org", "hackage.haskell.org", "raw.githubusercontent.com"]
FORBIDDEN_HOSTS = [
    "example.com",
    "api.anthropic.com",
    "github.com",
    "api.github.com",
    "gist.github.com",
    "registry-1.docker.io",
    "169.254.169.254",
    "127.0.0.1",
]
DIRECT_TARGETS = [("1.1.1.1", 443), ("8.8.8.8", 53), ("169.254.169.254", 80), ("172.17.0.1", 22)]


def contains_token(stream):
    tail = b""
    while block := stream.read(BLOCK):
        if has_token(tail + block):
            return True
        tail = block[-OVERLAP:]
    return False


def scan_files(root, expected_sockets=EXPECTED_SOCKETS, skip=frozenset()):
    failures = []
    for directory, names, files in os.walk(root):
        names[:] = [name for name in names if os.path.join(directory, name) not in skip]
        for name in files:
            path = os.path.join(directory, name)
            try:
                mode = os.lstat(path).st_mode
                if stat.S_ISSOCK(mode):
                    if path not in expected_sockets:
                        failures.append(f"unexpected socket: {path}")
                elif stat.S_ISREG(mode):
                    with open(path, "rb") as stream:
                        if contains_token(stream):
                            failures.append(f"token in file: {path}")
            except OSError:
                continue  # Unreadable to this user, so unreadable to the agent.
    return failures


def scan_processes(root=Path("/proc")):
    failures, seen = [], 0
    for process in root.iterdir():
        if not process.name.isdigit():
            continue
        for name in ("environ", "cmdline"):
            try:
                data = (process / name).read_bytes()
            except OSError:
                continue
            seen += 1
            if has_token(data):
                failures.append(f"token in {name} of process {process.name}")
            if name == "environ":
                for entry in data.split(b"\0"):
                    variable = entry.partition(b"=")[0].decode(errors="replace")
                    if FORBIDDEN_NAMES.match(variable):
                        failures.append(f"{variable} set in process {process.name}")
    if not seen:
        failures.append("no processes could be read")
    return failures


def can_connect(host, port):
    try:
        with socket.create_connection((host, port), timeout=3):
            return True
    except OSError:
        return False


def tunnel_status(host):
    """Ask the egress proxy for a tunnel and return its HTTP status, or None if it is down."""
    try:
        with socket.create_connection(EGRESS, timeout=45) as connection:
            connection.sendall(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
            reply = connection.recv(4096).split(b" ", 2)
            return int(reply[1])
    except (OSError, IndexError, ValueError):
        return None


def check_egress(status, allowed=ALLOWED_HOSTS, forbidden=FORBIDDEN_HOSTS):
    failures = [
        f"allowed host {host} answered {status(host)}" for host in allowed if status(host) != 200
    ]
    for host in forbidden:
        # A dead proxy answers nothing; only an explicit refusal proves the block.
        if status(host) != 403:
            failures.append(f"forbidden host {host} answered {status(host)}")
    return failures


def check_allowed_fetch():
    """Fetch a page end to end, so a refused host is known to differ from a dead network."""
    done = subprocess.run(
        ["curl", "-sSf", "--max-time", "60", "https://cache.nixos.org/nix-cache-info"],
        capture_output=True,
        text=True,
    )
    return [] if "StoreDir: /nix/store" in done.stdout else ["could not fetch from the Nix cache"]


def check_direct_network():
    failures = [
        f"direct connection to {host}:{port} succeeded"
        for host, port in DIRECT_TARGETS
        if can_connect(host, port)
    ]
    try:
        socket.getaddrinfo("example.com", 443)
        failures.append("direct DNS lookup succeeded")
    except OSError:
        pass
    return failures


def tunnel_answers(name=None):
    """Does an allowed tunnel answer TLS for this name, or plain HTTP if name is None?"""
    host = "cache.nixos.org"
    try:
        with socket.create_connection(EGRESS, timeout=45) as connection:
            connection.sendall(f"CONNECT {host}:443 HTTP/1.1\r\n\r\n".encode())
            if b" 200 " not in connection.recv(4096):
                return False
            if name is None:
                connection.sendall(f"GET / HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
                return bool(connection.recv(1))
            context = ssl.create_default_context()
            context.check_hostname, context.verify_mode = False, ssl.CERT_NONE
            with context.wrap_socket(connection, server_hostname=name):
                return True
    except OSError:
        return False


def check_tunnel_binding(answers=tunnel_answers):
    failures = []
    if not answers("cache.nixos.org"):
        failures.append("an allowed tunnel does not carry TLS")
    if answers("example.com"):
        failures.append("a tunnel carries TLS that names another host")
    if answers(None):
        failures.append("a tunnel carries plain text")
    return failures


def model_status(method, path, body=None):
    try:
        connection = http.client.HTTPConnection(*MODEL, timeout=10)
        connection.request(method, path, body)
        return connection.getresponse().status
    except (OSError, http.client.HTTPException):
        return None


def check_model_route(status=model_status):
    """These must be refused by the proxy; none may reach the model API."""
    request = {
        "model": "claude-sonnet-5-5",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "x"}],
        "tools": [{"type": "web_fetch_20250910", "name": "web_fetch"}],
    }
    failures = []
    for name, answer in (
        ("a forbidden route", status("GET", "/api/oauth/usage")),
        ("a server-side tool", status("POST", "/v1/messages", json.dumps(request))),
    ):
        if answer != 403:
            failures.append(f"model proxy answered {answer} to {name}")
    return failures


def check_privileges(status_file=Path("/proc/self/status")):
    fields = dict(
        line.split(":\t", 1) for line in status_file.read_text().splitlines() if ":\t" in line
    )
    failures = []
    if fields["CapEff"].strip("0") or fields["CapBnd"].strip("0"):
        failures.append("the container has Linux capabilities")
    if fields["NoNewPrivs"] != "1":
        failures.append("privilege escalation is not disabled")
    if fields["Uid"].split()[0] == "0":
        failures.append("the container runs as root")
    return failures


def run():
    return [
        *check_privileges(),
        *scan_processes(),
        *scan_files("/", skip=frozenset({"/proc", "/sys", "/dev"})),
        *check_direct_network(),
        *check_egress(tunnel_status),
        *check_allowed_fetch(),
        *check_tunnel_binding(),
        *check_model_route(),
    ]
