#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDIS_CLIENT_BIN="$(cd "$ROOT_DIR" && cabal list-bin redis-client)"
SYNTHETIC_SECRET='eyJhbGciOiJub25lIn0.eyJvaWQiOiJ0ZXN0LXVzZXJfMSJ9.c2lnbmF0dXJlLXNhZmU'

set +e
output="$("$REDIS_CLIENT_BIN" cli -h localhost "--password=$SYNTHETIC_SECRET" 2>&1)"
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "Error: credential-bearing argv was accepted." >&2
  exit 1
fi

if [[ "$output" == *"$SYNTHETIC_SECRET"* ]]; then
  echo "Error: credential-bearing argv was echoed in an error." >&2
  exit 1
fi

help_output="$("$REDIS_CLIENT_BIN" --help)"
if [[ "$help_output" == *"--password"* || "$help_output" == *"-a PASSWORD"* ]]; then
  echo "Error: help still advertises credential argv." >&2
  exit 1
fi

if [[ "$help_output" != *"REDIS_CLIENT_PASSWORD_FILE"* || "$help_output" != *"REDIS_CLIENT_PASSWORD"* ]]; then
  echo "Error: help does not document secure credential channels." >&2
  exit 1
fi

set +e
plaintext_output="$(
  REDIS_CLIENT_PASSWORD="$SYNTHETIC_SECRET" \
    "$REDIS_CLIENT_BIN" cli -h localhost -p 1 2>&1
)"
plaintext_status=$?
set -e

if [[ $plaintext_status -eq 0 || "$plaintext_output" != *"Refusing to send Redis credentials over plaintext"* ]]; then
  echo "Error: credentialed plaintext connection was not rejected." >&2
  exit 1
fi

if [[ "$plaintext_output" == *"$SYNTHETIC_SECRET"* ]]; then
  echo "Error: plaintext rejection disclosed the credential." >&2
  exit 1
fi

set +e
override_output="$(
  REDIS_CLIENT_PASSWORD="$SYNTHETIC_SECRET" \
    "$REDIS_CLIENT_BIN" cli -h localhost -p 1 --allow-insecure-plaintext-auth </dev/null 2>&1
)"
set -e

if [[ "$override_output" != *"WARNING: INSECURE PLAINTEXT AUTHENTICATION ENABLED"* \
  || "$override_output" != *"localhost"* \
  || "$override_output" != *"credentials will be sent unencrypted"* ]]; then
  echo "Error: plaintext-auth override warning is incomplete." >&2
  exit 1
fi

if [[ "$override_output" == *"$SYNTHETIC_SECRET"* ]]; then
  echo "Error: plaintext-auth override warning disclosed the credential." >&2
  exit 1
fi

echo "Credential argv and help checks passed."
