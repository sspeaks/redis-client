#! /usr/bin/env nix-shell
#! nix-shell -p bash coreutils gnugrep gnumake -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

fail() {
  echo "Error: $*" >&2
  exit 1
}

create_fixture() {
  local name=$1
  local fixture="$WORK_DIR/$name"
  local bin_dir="$fixture/bin"

  mkdir -p \
    "$bin_dir" \
    "$fixture/scripts" \
    "$fixture/docker/standalone" \
    "$fixture/nix"
  cp "$SCRIPT_DIR/run-e2e-tests.sh" "$fixture/scripts/run-e2e-tests.sh"
  chmod 700 "$fixture/scripts/run-e2e-tests.sh"
  : >"$fixture/docker/standalone/docker-compose.yml"
  : >"$fixture/nix/e2e-docker.nix"

  cat >"$fixture/scripts/generate-test-tls-certs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "generate-certs" >>"$STUB_LOG"
if [[ "$STUB_PHASE" == "cert-failure" ]]; then
  exit 21
fi
cert_dir="$1/tls.stub"
mkdir -p "$cert_dir"
printf '%s\n' "$cert_dir"
EOF

  cat >"$fixture/scripts/test-tls-fixtures.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "test-tls-fixtures" >>"$STUB_LOG"
EOF

  cat >"$bin_dir/nix-build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "nix-build $*" >>"$STUB_LOG"
if [[ "$STUB_PHASE" == "build-failure" ]]; then
  exit 23
fi
archive="$STUB_ROOT/e2e-image.tar"
: >"$archive"
printf '%s\n' "$archive"
EOF

  cat >"$bin_dir/nix-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="${!#}"
exec /bin/bash "$script"
EOF

  cat >"$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "docker $*" >>"$STUB_LOG"

if [[ "$1" == "load" ]]; then
  if [[ "$STUB_PHASE" == "load-failure" ]]; then
    exit 24
  fi
  exit 0
fi

if [[ "$1" == "compose" && " $* " == *" up "* ]]; then
  case "$STUB_PHASE" in
    compose-start-failure) exit 25 ;;
    compose-failure|primary-and-cleanup-failure) exit 42 ;;
    signal)
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
  exit 0
fi

if [[ "$1" == "compose" && " $* " == *" down "* ]]; then
  if [[ "$STUB_PHASE" == "primary-and-cleanup-failure" \
    || "$STUB_PHASE" == "success-cleanup-failure" ]]; then
    exit 33
  fi
  exit 0
fi

if [[ "$1" == "image" && "$2" == "rm" ]]; then
  if [[ "$STUB_PHASE" == "image-cleanup-failure" ]]; then
    exit 34
  fi
  exit 0
fi

exit 99
EOF

  chmod 700 \
    "$fixture/scripts/generate-test-tls-certs.sh" \
    "$fixture/scripts/test-tls-fixtures.sh" \
    "$bin_dir/docker" \
    "$bin_dir/nix-build" \
    "$bin_dir/nix-shell"

  printf '%s\n' "$fixture"
}

run_runner() {
  local fixture=$1
  local phase=$2
  local output=$3
  local log=$4

  PATH="$fixture/bin:$PATH" \
    STUB_LOG="$log" \
    STUB_PHASE="$phase" \
    STUB_ROOT="$fixture" \
    /bin/bash "$fixture/scripts/run-e2e-tests.sh" \
    >"$output" 2>&1
}

assert_status() {
  local expected=$1
  local actual=$2
  local scenario=$3
  if [[ "$actual" -ne "$expected" ]]; then
    fail "$scenario returned $actual; expected $expected"
  fi
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" ||
    fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

assert_ordered() {
  local file=$1
  shift
  local previous=0
  local expected
  local line

  for expected in "$@"; do
    line="$(grep -n -F -m1 -- "$expected" "$file" | cut -d: -f1)"
    if [[ -z "$line" || "$line" -le "$previous" ]]; then
      fail "$file does not contain ordered entry: $expected"
    fi
    previous=$line
  done
}

assert_runtime_removed() {
  local fixture=$1
  if [[ -e "$fixture/docker/standalone/.runtime" ]]; then
    fail "standalone TLS runtime directory survived cleanup"
  fi
}

run_case() {
  local name=$1
  local phase=$2
  local expected_status=$3
  local fixture
  local output
  local log
  local status

  fixture="$(create_fixture "$name")"
  output="$fixture/output"
  log="$fixture/commands.log"
  : >"$log"

  set +e
  run_runner "$fixture" "$phase" "$output" "$log"
  status=$?
  set -e
  assert_status "$expected_status" "$status" "$name"
  assert_runtime_removed "$fixture"
  printf '%s\n' "$fixture"
}

fixture="$(run_case success success 0)"
assert_ordered "$fixture/commands.log" \
  "generate-certs" \
  "nix-build --no-out-link --argstr imageName redis-client-e2e-tests-" \
  "docker load" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm redis-client-e2e-tests-"
assert_contains "$fixture/commands.log" \
  "docker compose -p redis-client-standalone-e2e-"
assert_contains "$fixture/commands.log" ":latest"

fixture="$(run_case cert-failure cert-failure 1)"
assert_contains "$fixture/output" \
  "failed to generate ephemeral TLS credentials"
assert_not_contains "$fixture/commands.log" "nix-build"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case build-failure build-failure 23)"
assert_contains "$fixture/commands.log" \
  "nix-build --no-out-link --argstr imageName redis-client-e2e-tests-"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case load-failure load-failure 24)"
assert_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" " compose "
assert_not_contains "$fixture/commands.log" "image rm"

fixture="$(run_case compose-start-failure compose-start-failure 25)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm redis-client-e2e-tests-"

fixture="$(run_case compose-failure compose-failure 42)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm redis-client-e2e-tests-"

fixture="$(run_case primary-and-cleanup-failure primary-and-cleanup-failure 42)"
assert_contains "$fixture/output" \
  "failed to stop the standalone E2E Compose project (exit 33)"
assert_contains "$fixture/commands.log" \
  "docker image rm redis-client-e2e-tests-"

fixture="$(run_case success-cleanup-failure success-cleanup-failure 33)"
assert_contains "$fixture/output" \
  "failed to stop the standalone E2E Compose project (exit 33)"
assert_contains "$fixture/commands.log" \
  "docker image rm redis-client-e2e-tests-"

fixture="$(run_case image-cleanup-failure image-cleanup-failure 34)"
assert_contains "$fixture/output" \
  "failed to remove the standalone E2E image (exit 34)"

fixture="$(run_case signal signal 143)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm redis-client-e2e-tests-"

fixture="$(create_fixture make-propagation)"
cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
: >"$fixture/commands.log"
set +e
PATH="$fixture/bin:$PATH" \
  STUB_LOG="$fixture/commands.log" \
  STUB_PHASE="compose-failure" \
  STUB_ROOT="$fixture" \
  make --no-print-directory -C "$fixture" test-e2e \
  >"$fixture/make.out" 2>&1
make_status=$?
set -e
# GNU Make normalizes a failed recipe to status 2 but retains the exact runner
# status in its diagnostic, so CI still fails and the primary code is visible.
assert_status 2 "$make_status" "make test-e2e"
assert_contains "$fixture/make.out" "Error 42"
assert_contains "$fixture/commands.log" "test-tls-fixtures"
assert_contains "$fixture/commands.log" " up --exit-code-from e2etests"
assert_contains "$fixture/commands.log" " down"

printf '%s\n' "Standalone E2E runner exit and cleanup checks passed."
