#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

export AZURE_HELPER_SMOKE_MARKER="$tmp_dir/az-was-called"
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/az" <<'EOF'
#!/usr/bin/env bash
: >"$AZURE_HELPER_SMOKE_MARKER"
exit 99
EOF
chmod +x "$tmp_dir/bin/az"

cd "$REPO_ROOT"
package_path=${AZURE_HELPER_PACKAGE_PATH:-$(nix-build --no-out-link -A fullPackageWithScripts)}

check_help() {
  local name=$1
  shift
  local output="$tmp_dir/$name.help"

  PATH="$tmp_dir/bin:$PATH" "$@" --help >"$output"
  grep -qi '^usage:' "$output"
}

check_help source-helper python3 scripts/azure-redis-connect.py
check_help canonical-helper "$package_path/bin/azure-redis-connect"
check_help compatibility-alias "$package_path/bin/redis-connect"

if [[ -e "$AZURE_HELPER_SMOKE_MARKER" ]]; then
  echo "Azure CLI was invoked while printing helper usage" >&2
  exit 1
fi
