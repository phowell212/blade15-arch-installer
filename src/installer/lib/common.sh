#!/usr/bin/env bash
set -Eeuo pipefail
set +x

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "${1-}" >&2
  exit 1
}

cmdline_has() {
  local expected=${1-}
  local cmdline_file=${CMDLINE_FILE:-/proc/cmdline}
  local cmdline=''
  local -a tokens=()
  local token

  [[ -n "$expected" && -r "$cmdline_file" ]] || return 1
  IFS= read -r cmdline <"$cmdline_file" || [[ -n "$cmdline" ]] || return 1

  read -r -a tokens <<<"$cmdline"
  for token in "${tokens[@]}"; do
    [[ "$token" == "$expected" ]] && return 0
  done
  return 1
}
