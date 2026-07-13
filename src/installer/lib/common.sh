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

_installer_config_path() {
  printf '%s\n' /usr/share/blade-installer/build.env
}

load_installer_config() {
  local source_tree_path=${1-}
  local canonical_path
  local config_file

  if ! canonical_path=$(_installer_config_path) || [[ -z "$canonical_path" ]]; then
    die 'canonical installer configuration path is unavailable'
  fi

  if [[ -n "${BUILD_ENV_FILE+x}" ]]; then
    config_file=$BUILD_ENV_FILE
  elif [[ -e "$canonical_path" || -L "$canonical_path" ]]; then
    config_file=$canonical_path
  elif [[ -n "$source_tree_path" &&
    (-e "$source_tree_path" || -L "$source_tree_path") ]]; then
    config_file=$source_tree_path
  else
    config_file=$canonical_path
  fi

  [[ -n "$config_file" && -f "$config_file" && ! -L "$config_file" &&
    -r "$config_file" ]] ||
    die "missing or unsafe installer configuration: ${config_file:-<empty>}"
  # shellcheck source=/dev/null
  source "$config_file"
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
