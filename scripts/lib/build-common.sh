#!/usr/bin/env bash

BUILD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$BUILD_COMMON_DIR/../.." && pwd -P)"
BUILD_DIR="$REPO_ROOT/build"
BUILD_CONFIG="$REPO_ROOT/config/build.env"
TARGET_PACKAGE_LIST="$REPO_ROOT/packages/target.txt"
# shellcheck disable=SC2034
TARGET_PACMAN_CONFIG="$REPO_ROOT/config/pacman-target.conf"
# shellcheck disable=SC2034
TARGET_OVERLAY="$REPO_ROOT/src/target-rootfs"

die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

is_dry_run() {
  [[ ${BLADE_DRY_RUN:-0} == 1 ]]
}

load_build_config() {
  [[ -r "$BUILD_CONFIG" ]] || die "missing build configuration: $BUILD_CONFIG"
  # shellcheck disable=SC1090,SC1091
  source "$BUILD_CONFIG"

  [[ ${CODEX_RELEASE:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die 'CODEX_RELEASE must be a pinned semantic version'
  [[ ${CODEX_INSTALLER_SHA256:-} =~ ^[0-9a-f]{64}$ ]] ||
    die 'CODEX_INSTALLER_SHA256 must be a lowercase SHA-256 digest'
  [[ ${YAY_AUR_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] ||
    die 'YAY_AUR_COMMIT must be a full lowercase Git commit'
}

assert_safe_build_child() {
  local candidate=${1-}
  local build_lexical
  local build_real
  local candidate_lexical
  local candidate_real
  local repo_real

  if [[ -z "$candidate" ]]; then
    die 'refusing an empty cleanup path'
    return 1
  fi
  if ! command -v realpath >/dev/null 2>&1; then
    die 'realpath is required for cleanup safety'
    return 1
  fi

  if ! repo_real=$(realpath -e -- "$REPO_ROOT"); then
    die "cannot resolve repository root: $REPO_ROOT"
    return 1
  fi
  if ! build_real=$(realpath -m -- "$BUILD_DIR"); then
    die "cannot resolve build directory: $BUILD_DIR"
    return 1
  fi
  if ! build_lexical=$(realpath -ms -- "$BUILD_DIR"); then
    die "cannot normalize build directory: $BUILD_DIR"
    return 1
  fi
  if ! candidate_real=$(realpath -m -- "$candidate"); then
    die "cannot resolve cleanup path: $candidate"
    return 1
  fi
  if ! candidate_lexical=$(realpath -ms -- "$candidate"); then
    die "cannot normalize cleanup path: $candidate"
    return 1
  fi

  if [[ "$build_real" != "$build_lexical" ]]; then
    die "repository build directory traverses a symlink: $BUILD_DIR"
    return 1
  fi
  if [[ "$candidate_real" != "$candidate_lexical" ]]; then
    die "cleanup path traverses a symlink: $candidate"
    return 1
  fi
  if [[ "$candidate_real" == / ]]; then
    die 'refusing to clean filesystem root'
    return 1
  fi
  if [[ "$candidate_real" == "$repo_real" ]]; then
    die 'refusing to clean repository root'
    return 1
  fi
  if [[ "$candidate_real" == "$build_real" ]]; then
    die 'refusing to clean build root'
    return 1
  fi
  case "$candidate_real" in
    "$build_real"/*) ;;
    *) die "cleanup path escapes repository build directory: $candidate_real" || return ;;
  esac

  printf '%s\n' "$candidate_real"
}

reset_build_directory() {
  local directory

  directory=$(assert_safe_build_child "${1-}") || return
  if [[ -e "$directory" || -L "$directory" ]]; then
    rm -rf -- "$directory"
  fi
  mkdir -p -- "$directory"
}

clear_build_directory() {
  local directory

  directory=$(assert_safe_build_child "${1-}") || return
  [[ -d "$directory" ]] || return 0
  [[ ! -L "$directory" ]] || die "refusing to clear symlink: $directory"
  find "$directory" -mindepth 1 -delete
}

require_privileged_arch() {
  [[ $(id -u) -eq 0 ]] || die 'this build must run as root'
  [[ -e /etc/arch-release ]] ||
    die 'this build requires a privileged Arch Linux environment'
  command -v pacstrap >/dev/null 2>&1 || die 'pacstrap is required'
  command -v arch-chroot >/dev/null 2>&1 || die 'arch-chroot is required'
}

read_target_packages() {
  local destination_name=${1-}
  local package
  local -a entries=()

  if [[ ! "$destination_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die 'read_target_packages requires an array variable name'
    return 1
  fi
  local -n destination=$destination_name
  destination=()
  if [[ ! -r "$TARGET_PACKAGE_LIST" ]]; then
    die "missing target package list: $TARGET_PACKAGE_LIST"
    return 1
  fi
  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -n "$package" && "$package" != \#* ]] || continue
    if [[ ! "$package" =~ ^[a-z0-9@._+-]+$ ]]; then
      die "unsafe package name in target list: $package"
      return 1
    fi
    entries+=("$package")
  done <"$TARGET_PACKAGE_LIST"
  # shellcheck disable=SC2034
  destination=("${entries[@]}")
}
