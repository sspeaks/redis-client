#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl coreutils -i bash
# shellcheck shell=bash

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 RUNTIME_ROOT" >&2
  exit 2
fi

RUNTIME_ROOT="$1"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
CERT_DIR=""

cleanup_on_failure() {
  local status=$?

  trap - EXIT INT TERM HUP
  if [[ "$status" -ne 0 && -n "$CERT_DIR" ]]; then
    rm -rf -- "$CERT_DIR"
  fi
  exit "$status"
}

trap cleanup_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if ! command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
  echo "Error: OpenSSL executable '$OPENSSL_BIN' is unavailable; cannot generate test TLS credentials." >&2
  exit 1
fi

# These credentials establish local test trust only. Never commit or reuse them.
umask 077
mkdir -p "$RUNTIME_ROOT"
chmod 700 "$RUNTIME_ROOT"
CERT_DIR="$(mktemp -d "$RUNTIME_ROOT/tls.XXXXXX")"

if ! "$OPENSSL_BIN" req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -nodes \
  -days 1 \
  -keyout "$CERT_DIR/redis-ca.key" \
  -out "$CERT_DIR/redis-ca.crt" \
  -subj "/CN=redis-client ephemeral test CA" >/dev/null 2>&1; then
  echo "Error: failed to generate the ephemeral test CA." >&2
  exit 1
fi

if ! "$OPENSSL_BIN" req \
  -newkey rsa:2048 \
  -sha256 \
  -nodes \
  -keyout "$CERT_DIR/redis-server.key" \
  -out "$CERT_DIR/redis-server.csr" \
  -subj "/CN=redis.local" >/dev/null 2>&1; then
  echo "Error: failed to generate the ephemeral Redis server private key and CSR." >&2
  exit 1
fi

cat >"$CERT_DIR/redis-server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:redis.local
EOF

if ! "$OPENSSL_BIN" x509 \
  -req \
  -sha256 \
  -days 1 \
  -in "$CERT_DIR/redis-server.csr" \
  -CA "$CERT_DIR/redis-ca.crt" \
  -CAkey "$CERT_DIR/redis-ca.key" \
  -CAcreateserial \
  -extfile "$CERT_DIR/redis-server.ext" \
  -out "$CERT_DIR/redis-server.crt" >/dev/null 2>&1; then
  echo "Error: failed to sign the ephemeral Redis server certificate." >&2
  exit 1
fi

rm -f "$CERT_DIR/redis-server.csr" "$CERT_DIR/redis-server.ext" "$CERT_DIR/redis-ca.srl"
chmod 600 "$CERT_DIR/redis-ca.key" "$CERT_DIR/redis-server.key"
chmod 644 "$CERT_DIR/redis-ca.crt" "$CERT_DIR/redis-server.crt"

printf '%s\n' "$CERT_DIR"
