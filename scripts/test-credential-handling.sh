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

echo "Credential argv and help checks passed."
