#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run-with-rts-profile.sh --print-flags PROFILE
  scripts/run-with-rts-profile.sh PROFILE -- COMMAND [ARG...]

Profiles:
  conservative       No explicit RTS flags.
  legacy-high-memory Reproduces the old global defaults for comparison only.
  fill-throughput    Measured fill / bench profile with a CPU-aware capability cap.
  fill-bounded       Lower-memory fill profile for local validation with -f.
EOF
}

visible_caps() {
  if [[ -n "${REDIS_CLIENT_RTS_CAPS:-}" ]]; then
    printf '%s\n' "$REDIS_CLIENT_RTS_CAPS"
    return
  fi

  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
    return
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return
  fi

  printf '1\n'
}

clamp_caps() {
  local caps="$1"
  local max_caps="$2"

  if [[ "$caps" -lt 1 ]]; then
    caps=1
  fi

  if [[ "$caps" -gt "$max_caps" ]]; then
    caps="$max_caps"
  fi

  printf '%s\n' "$caps"
}

profile_flags() {
  local profile="$1"
  local caps

  case "$profile" in
    conservative)
      printf '\n'
      ;;
    legacy-high-memory)
      printf '%s\n' "-N -H1024M -A128m -n8m -qb"
      ;;
    fill-throughput)
      caps="$(clamp_caps "$(visible_caps)" 4)"
      printf '%s\n' "-N${caps} -A64m -n4m -qb"
      ;;
    fill-bounded)
      caps="$(clamp_caps "$(visible_caps)" 2)"
      printf '%s\n' "-N${caps} -A16m -n4m -qb"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

if [[ "${1:-}" == "--print-flags" ]]; then
  if [[ $# -ne 2 ]]; then
    usage >&2
    exit 1
  fi

  profile_flags "$2"
  exit 0
fi

if [[ $# -lt 3 ]]; then
  usage >&2
  exit 1
fi

profile="$1"
shift

if [[ "$1" != "--" ]]; then
  usage >&2
  exit 1
fi
shift

flags="$(profile_flags "$profile")"

if [[ -z "$flags" ]]; then
  exec "$@"
fi

exec "$@" +RTS $flags -RTS
