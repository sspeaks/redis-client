#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl coreutils gnugrep -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  rm -rf -- "$WORK_DIR"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

CERT_DIR="$("$SCRIPT_DIR/generate-test-tls-certs.sh" "$WORK_DIR/success")"

[[ "$(stat -c '%a' "$CERT_DIR")" == "700" ]]
[[ "$(stat -c '%a' "$CERT_DIR/redis-ca.key")" == "600" ]]
[[ "$(stat -c '%a' "$CERT_DIR/redis-server.key")" == "600" ]]
openssl verify -CAfile "$CERT_DIR/redis-ca.crt" "$CERT_DIR/redis-server.crt" >/dev/null
openssl x509 -in "$CERT_DIR/redis-server.crt" -noout -checkhost redis.local >/dev/null

rm -rf -- "$CERT_DIR"
[[ ! -e "$CERT_DIR" ]]

FAKE_OPENSSL="$WORK_DIR/fake-openssl"
CALL_COUNT_FILE="$WORK_DIR/openssl-call-count"
cat >"$FAKE_OPENSSL" <<'EOF'
#!/usr/bin/env bash
count="$(cat "$OPENSSL_CALL_COUNT" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$OPENSSL_CALL_COUNT"
[[ "$count" -lt 2 ]]
EOF
chmod 700 "$FAKE_OPENSSL"

FAILURE_ROOT="$WORK_DIR/failure"
if OPENSSL_BIN="$FAKE_OPENSSL" OPENSSL_CALL_COUNT="$CALL_COUNT_FILE" \
  "$SCRIPT_DIR/generate-test-tls-certs.sh" "$FAILURE_ROOT" \
  >"$WORK_DIR/failure.out" 2>"$WORK_DIR/failure.err"; then
  echo "Error: TLS generator unexpectedly succeeded with a failing OpenSSL command." >&2
  exit 1
fi

grep -Fq "failed to generate the ephemeral Redis server private key and CSR" "$WORK_DIR/failure.err"
if find "$FAILURE_ROOT" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
  echo "Error: partial TLS credentials were not removed after generation failure." >&2
  exit 1
fi

printf '%s\n' "Ephemeral TLS fixture checks passed."
