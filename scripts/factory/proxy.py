"""Proxies that run outside the agent container, each on a Unix socket.

ModelProxy holds the subscription token and adds it to model requests that pass
model_request.py. EgressProxy opens TLS tunnels to a fixed list of hosts. The
container has no network, so these two sockets are its only way out.

Residual risk: EgressProxy checks that a tunnel is TLS and names its host in
clear, but does not decrypt it. The HTTP Host inside may name another site on
the same CDN (domain fronting), so a tunnel may reach sites beyond the list, and
the client may never negotiate TLS for real. Closing this needs TLS interception.
hackage.haskell.org also accepts uploads from anyone holding credentials there;
the container holds none, but text the agent reads could supply some.
"""

import http.client
import ipaddress
import re
import select
import socket
import socketserver
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler

import model_request

# Only `claude setup-token` tokens: the probe inside the container searches for
# this prefix, so any other credential could leak without being noticed.
TOKEN_PATTERN = re.compile(r"sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{20,256}")
# github.com and api.github.com accept writes; these two hosts only serve content.
GITHUB_HOSTS = frozenset({"codeload.github.com", "raw.githubusercontent.com"})
ALLOWED_HOSTS = GITHUB_HOSTS | {
    "cache.nixos.org",
    "tarballs.nixos.org",
    "hackage.haskell.org",
}
MODEL_PATHS = {
    f"{path}{query}"
    for path in ("/v1/messages", "/v1/messages/count_tokens")
    for query in ("", "?beta=true")
}
MAX_REQUESTS = 100
MAX_BODY = 32 * 1024 * 1024
MODEL_CONNECTIONS, EGRESS_CONNECTIONS = 4, 64
LIMIT_PREFIX = "anthropic-ratelimit-unified-"
RESPONSE_HEADERS = re.compile(
    r"content-type|request-id|retry-after|x-should-retry|anthropic-ratelimit-[a-z0-9-]+",
    re.IGNORECASE,
)
SAFE_VALUE = re.compile(r"[\x20-\x7e]{0,256}")
TUNNEL_IDLE_SECONDS = 600
# Azure's host agent, which every hosted runner can reach.
AZURE_HOST = ipaddress.ip_address("168.63.129.16")


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, path, handler, connections):
        self.slots = threading.BoundedSemaphore(connections)
        super().__init__(str(path), handler)
        path.chmod(0o600)  # The container runs as this same user.

    def process_request(self, request, client_address):
        if self.slots.acquire(blocking=False):
            super().process_request(request, client_address)
        else:
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # A client that hangs up mid-reply is not worth a traceback.


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 120

    def address_string(self):
        return "container"

    def log_message(self, *_):
        pass

    def reply(self, status, message, headers=()):
        body = message.encode()
        self.close_connection = True
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def refuse(self, reason, status=403, headers=(), body_read=False):
        self.server.record({"kind": "refused", "reason": reason, "target": self.path[:200]})
        if not body_read and (length := self.body_length()):
            # Closing with unread data would reset the connection under the reply.
            self.rfile.read(min(length, 1024 * 1024))
        self.reply(status, reason, headers)

    def body_length(self):
        """The one plain Content-Length, or None."""
        values = self.headers.get_all("content-length", [])
        if len(values) == 1 and re.fullmatch(r"[0-9]{1,10}", values[0]):
            return int(values[0])
        return None


class TokenSearch:
    """Finds pieces of the token in text, including a stream split anywhere.

    Ignores case, because header names lose theirs. Catches the token as plain
    text only, not an encoded form of it.
    """

    WINDOW = 12

    def __init__(self, token):
        self.token = token.lower().encode()
        secret = self.token[self.token.index(b"-", 7) + 1 :]
        self.pieces = {
            secret[at : at + self.WINDOW] for at in range(len(secret) - self.WINDOW + 1)
        }

    def found(self, text):
        text = text.lower()
        return any(piece in text for piece in self.pieces)

    def found_in_headers(self, reason, headers):
        """Looks through names and values, joined in each order a split could use."""
        names, values = list(headers.keys()), list(headers.values())
        both = [part for pair in zip(names, values) for part in pair]
        return any(
            self.found(re.sub(r"[^A-Za-z0-9_-]", "", "".join(parts)).encode())
            for parts in ([reason], names, values, both)
        )

    def held(self, text):
        """How many final bytes of text could be the start of a piece."""
        text = text[-self.WINDOW :].lower()
        for size in range(min(self.WINDOW - 1, len(text)), 0, -1):
            if text[-size:] in self.token:
                return size
        return 0


def classify_response(status, headers):
    """Name a model response. Only a 429 that carries a rejected plan limit is a usage limit."""
    if 200 <= status < 300:
        return "ok"
    if status == 429:
        rejected = headers.get(f"{LIMIT_PREFIX}status", "").lower() == "rejected"
        return "usage_limit" if rejected else "throttled"
    return {401: "auth_failed", 403: "auth_failed", 529: "overloaded"}.get(
        status, "invalid_request" if 400 <= status < 500 else "upstream_error"
    )


class ModelProxy(UnixServer):
    def __init__(
        self,
        path,
        token,
        record,
        model,
        upstream="https://api.anthropic.com",
        max_requests=MAX_REQUESTS,
        connections=MODEL_CONNECTIONS,
    ):
        if not TOKEN_PATTERN.fullmatch(token):
            raise ValueError("the model token is not a `claude setup-token` token")
        url = urllib.parse.urlsplit(upstream)
        if url.scheme != "https" and url.hostname != "127.0.0.1":
            raise ValueError("a remote upstream must use https")
        self.token, self.record, self.model, self.upstream = token, record, model, url
        self.search = TokenSearch(token)
        self.remaining = max_requests
        self.lock = threading.Lock()
        self.stopped = None
        super().__init__(path, ModelHandler, connections)

    def admit(self):
        """Return (status, reason, headers) to refuse with, or None to forward."""
        with self.lock:
            if self.stopped:
                return self.stopped
            if self.remaining <= 0:
                return 403, "model request cap reached", ()
            self.remaining -= 1
        return None

    def stop(self, reason):
        """Send nothing more to the model API."""
        with self.lock:
            self.stopped = 403, reason, ()

    def echoed(self):
        self.stop("the model API echoed the token")
        self.record({"kind": "token_echoed"})

    def observe(self, status, headers):
        kind = classify_response(status, headers)
        limits = {
            name.lower()[len(LIMIT_PREFIX) :]: value
            for name, value in headers.items()
            if name.lower().startswith(LIMIT_PREFIX) and SAFE_VALUE.fullmatch(value)
        }
        # Best effort: these two header names are not documented, so their
        # absence proves nothing about the account setting.
        credits = limits.get("overage-status", "").startswith("allowed") or (
            limits.get("overage-in-use", "").lower() == "true"
        )
        with self.lock:
            if credits:
                self.stopped = 403, "usage credits are on", ()
            elif kind == "usage_limit" and not self.stopped:
                self.stopped = (
                    429,
                    '{"type":"error","error":{"type":"rate_limit_error","message":"usage limit"}}',
                    [(LIMIT_PREFIX + name, value) for name, value in limits.items()]
                    + [("content-type", "application/json"), ("x-should-retry", "false")],
                )
        self.record({"kind": kind, "status": status, "limits": limits})
        if credits:
            self.record({"kind": "usage_credits", "limits": limits})


class ModelHandler(Handler):
    def do_HEAD(self):
        if self.path == "/api/hello":
            self.reply(200, "")
        else:
            self.refuse("route not allowed")

    def refuse_method(self):
        self.refuse("route not allowed")

    do_GET = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = refuse_method

    def do_POST(self):
        if self.path not in MODEL_PATHS:
            return self.refuse("route not allowed")
        length = self.body_length()
        if length is None or "transfer-encoding" in self.headers:
            return self.refuse("content-length required", 411)
        if length > MAX_BODY:
            return self.refuse("request too large", 413)
        raw = self.rfile.read(length)
        try:
            headers = model_request.check_headers(self.headers)
            body = model_request.check_body(
                raw, self.server.model, "/count_tokens" in self.path
            )
        except model_request.Refused as error:
            return self.refuse(str(error), body_read=True)
        refusal = self.server.admit()
        if refusal:
            return self.refuse(refusal[1], refusal[0], refusal[2], body_read=True)
        self.forward(headers, body)

    def forward(self, headers, body):
        url = self.server.upstream
        connect = (
            http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        )
        connection = connect(url.hostname, url.port, timeout=600)
        headers["Content-Type"] = "application/json"
        headers["Authorization"] = f"Bearer {self.server.token}"
        try:
            try:
                connection.request("POST", self.path, body, headers)
                response = connection.getresponse()
            except (OSError, http.client.HTTPException) as error:
                self.server.record(
                    {"kind": "upstream_unreachable", "error": type(error).__name__}
                )
                return self.reply(502, "model upstream unreachable")
            if self.server.search.found_in_headers(response.reason, response.headers):
                self.server.echoed()
                return self.reply(502, "response withheld")
            self.server.observe(response.status, response.headers)
            if response.headers.get("content-encoding", "identity") != "identity" or (
                300 <= response.status < 400
            ):
                return self.reply(502, "response withheld")
            self.stream(response)
        finally:
            connection.close()

    def stream(self, response):
        self.close_connection = True
        try:
            self.send_response_only(response.status)
            for name, value in response.headers.items():
                if RESPONSE_HEADERS.fullmatch(name) and SAFE_VALUE.fullmatch(value):
                    self.send_header(name, value)
            self.send_header("transfer-encoding", "chunked")
            self.send_header("connection", "close")
            self.end_headers()
            complete = self.copy(response)
            if complete:
                self.wfile.write(b"0\r\n\r\n")
        except OSError:
            # Only writes to the client raise here; see copy.
            self.server.record({"kind": "client_gone"})

    def copy(self, response):
        """Send the body on, withholding any end that might begin the token."""
        pending = b""
        while True:
            try:
                data = response.read1(65536)
            except (OSError, http.client.HTTPException):
                self.server.record({"kind": "stream_broken"})
                return False
            pending += data
            if self.server.search.found(pending):
                self.server.echoed()
                return False
            if not data and response.length:
                self.server.record({"kind": "stream_broken"})
                return False
            keep = self.server.search.held(pending) if data else 0
            ready, pending = pending[: len(pending) - keep], pending[len(pending) - keep :]
            if ready:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(ready), ready))
                self.wfile.flush()
            if not data:
                return True


def is_dialable(address):
    """Public IPv4 only. IPv6 has several forms that embed an internal IPv4 address."""
    address = ipaddress.ip_address(address)
    return (
        address.version == 4
        and address.is_global
        and not address.is_multicast
        and not address.is_reserved
        and address != AZURE_HOST
    )


def dial_public(host, port):
    """Connect to a public address of host, never to one inside the runner's network."""
    found = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    for *_, address in found:
        if not is_dialable(address[0]):
            continue
        try:
            return socket.create_connection(address, timeout=30)
        except OSError:
            continue
    raise OSError(f"no reachable public address for {host}")


class Bytes:
    """Reads length-prefixed fields, raising ValueError past the end."""

    def __init__(self, data):
        self.data = data

    def take(self, size):
        if size > len(self.data):
            raise ValueError("truncated")
        taken, self.data = self.data[:size], self.data[size:]
        return taken

    def number(self, width):
        return int.from_bytes(self.take(width), "big")

    def field(self, width):
        return Bytes(self.take(self.number(width)))


def server_name(stream):
    """Return the server name in a TLS ClientHello, or None if more bytes are needed.

    Raises ValueError for anything else, including encrypted or repeated names.
    """
    handshake, rest = b"", stream
    while True:
        if handshake[:1] not in (b"", b"\x01"):
            raise ValueError("not a ClientHello")
        if len(handshake) >= 4:
            size = int.from_bytes(handshake[1:4], "big")
            if size > 16384:
                raise ValueError("oversized ClientHello")
            if len(handshake) >= 4 + size:
                break
        if rest[:1] not in (b"", b"\x16") or rest[1:2] not in (b"", b"\x03"):
            raise ValueError("not TLS")
        if len(rest) < 5:
            return None
        size = int.from_bytes(rest[3:5], "big")
        if not 0 < size <= 16384:
            raise ValueError("bad record length")
        if len(rest) < 5 + size:
            return None
        handshake, rest = handshake + rest[5 : 5 + size], rest[5 + size :]

    hello = Bytes(handshake[4 : 4 + size])
    hello.take(2 + 32)
    hello.field(1)
    hello.field(2)
    hello.field(1)
    extensions = hello.field(2)
    if hello.data:
        raise ValueError("trailing data")
    names = []
    while extensions.data:
        kind, body = extensions.number(2), extensions.field(2)
        if kind == 0xFE0D:
            raise ValueError("encrypted ClientHello")
        if kind == 0:
            entries = body.field(2)
            while entries.data:
                if entries.number(1) != 0:
                    raise ValueError("unknown name type")
                names.append(entries.field(2).data)
    if len(names) != 1:
        raise ValueError("no single server name")
    return names[0].decode("ascii").lower()


class TlsRecords:
    """Checks that a byte stream keeps the framing of TLS records."""

    def __init__(self):
        self.header, self.remaining = b"", 0

    def check(self, data):
        while data:
            if self.remaining:
                size = min(self.remaining, len(data))
                self.remaining -= size
                data = data[size:]
                continue
            self.header += data[:1]
            data = data[1:]
            if len(self.header) == 5:
                self.remaining = int.from_bytes(self.header[3:], "big")
                if not 0 < self.remaining <= 16384 + 256:
                    raise ValueError("bad record length")
                self.header = b""
            elif len(self.header) == 1 and not 20 <= self.header[0] <= 23:
                raise ValueError("not a TLS record")
            elif len(self.header) == 2 and self.header[1] != 3:
                raise ValueError("not a TLS record")


class EgressProxy(UnixServer):
    def __init__(self, path, record, dial=dial_public):
        self.record, self.dial = record, dial
        super().__init__(path, EgressHandler, EGRESS_CONNECTIONS)


class EgressHandler(Handler):
    rbufsize = 0  # Bytes after the CONNECT must stay in the socket for the tunnel.

    def refuse_method(self):
        self.refuse("only CONNECT is allowed")

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = refuse_method

    def do_CONNECT(self):
        host, _, port = self.path.rpartition(":")
        if host not in ALLOWED_HOSTS or port != "443":
            return self.refuse("host not allowed")
        try:
            remote = self.server.dial(host, 443)
        except OSError as error:
            self.server.record(
                {"kind": "egress_failed", "host": host, "error": type(error).__name__}
            )
            return self.reply(502, "host unreachable")
        self.close_connection = True
        with remote:
            self.send_response_only(200)
            self.end_headers()
            try:
                hello = self.read_hello(host)
            except (OSError, ValueError):
                # No HTTP reply: the client is already speaking inside the tunnel.
                self.server.record(
                    {"kind": "refused", "reason": "not TLS to the named host", "target": host}
                )
                return
            self.connection.settimeout(120)
            remote.settimeout(120)
            received = relay(self.connection, remote, hello)
        self.server.record({"kind": "tunnel", "host": host, "bytes": received})

    def read_hello(self, host):
        self.connection.settimeout(15)
        deadline, hello = time.monotonic() + 30, b""
        while time.monotonic() < deadline and len(hello) < 65536:
            data = self.connection.recv(4096)
            if not data:
                break
            hello += data
            name = server_name(hello)
            if name is not None:
                if name != host:
                    raise ValueError("names another host")
                return hello
        raise ValueError("no ClientHello")


def relay(client, remote, hello):
    """Copy bytes both ways, passing on each side's end of stream.

    Returns how many bytes came back from the remote.
    """
    records, received = TlsRecords(), 0
    sources = {client, remote}
    try:
        records.check(hello)
        remote.sendall(hello)
        while sources:
            ready = select.select(list(sources), [], [], TUNNEL_IDLE_SECONDS)[0]
            if not ready:
                break
            for source in ready:
                target = remote if source is client else client
                data = source.recv(65536)
                if not data:
                    target.shutdown(socket.SHUT_WR)
                    sources.discard(source)
                elif source is client:
                    records.check(data)
                    target.sendall(data)
                else:
                    target.sendall(data)
                    received += len(data)
    except (OSError, ValueError):
        pass
    return received
