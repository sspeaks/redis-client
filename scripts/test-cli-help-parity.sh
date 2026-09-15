#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

tmp_help_expected=$(mktemp)
tmp_help_actual=$(mktemp)
tmp_help_mode_actual=$(mktemp)
tmp_readme_expected=$(mktemp)
tmp_readme_actual=$(mktemp)

cleanup() {
  rm -f "$tmp_help_expected" "$tmp_help_actual" "$tmp_help_mode_actual" \
    "$tmp_readme_expected" "$tmp_readme_actual"
}
trap cleanup EXIT

cd "$REPO_ROOT"

cabal build redis-client >/dev/null
redis_bin=$(cabal list-bin redis-client)

"$redis_bin" --help >"$tmp_help_actual"
"$redis_bin" fill --help >"$tmp_help_mode_actual"

cabal exec runghc -- -iapp "$SCRIPT_DIR/render-cli-reference.hs" help >"$tmp_help_expected"
cabal exec runghc -- -iapp "$SCRIPT_DIR/render-cli-reference.hs" readme >"$tmp_readme_expected"

grep -q '^<!-- BEGIN GENERATED CLI REFERENCE -->$' README.md
grep -q '^<!-- END GENERATED CLI REFERENCE -->$' README.md

awk '
  /^<!-- BEGIN GENERATED CLI REFERENCE -->$/ { capture = 1; next }
  /^<!-- END GENERATED CLI REFERENCE -->$/ { capture = 0; exit }
  capture { print }
' README.md >"$tmp_readme_actual"

diff -u "$tmp_help_expected" "$tmp_help_actual"
diff -u "$tmp_help_expected" "$tmp_help_mode_actual"
diff -u "$tmp_readme_expected" "$tmp_readme_actual"
