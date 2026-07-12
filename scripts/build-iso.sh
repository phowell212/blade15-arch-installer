#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/build-common.sh disable=SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

PROFILE_DIR="$BUILD_DIR/archiso-profile"
WORK_DIR="$BUILD_DIR/archiso-work"
DIST_DIR="$REPO_ROOT/dist"
PAYLOAD_DIR="$BUILD_DIR/payload"

print_plan() {
  # The placeholders are intentionally literal documentation of the release name.
  # shellcheck disable=SC2016
  printf '%s\n' \
    'run scripts/prepare-archiso.sh' \
    "run mkarchiso -v -w $REPO_ROOT/build/archiso-work -o $REPO_ROOT/dist $REPO_ROOT/build/archiso-profile" \
    'rename the single new ISO to blade15-arch-gnome-${BUILD_DATE}-${GIT_REV}.iso' \
    'generate ISO SHA-256 sidecar' \
    'copy target-packages.txt and build-manifest.txt to dist'
}

assert_safe_dist() {
  local dist_lexical
  local dist_real
  local repo_real

  repo_real=$(realpath -e -- "$REPO_ROOT") || return
  dist_real=$(realpath -m -- "$DIST_DIR") || return
  dist_lexical=$(realpath -ms -- "$DIST_DIR") || return
  [[ "$dist_real" == "$dist_lexical" ]] ||
    die "distribution directory traverses a symlink: $DIST_DIR"
  [[ "$dist_real" == "$repo_real/dist" ]] ||
    die "distribution directory escapes repository dist: $dist_real"
  printf '%s\n' "$dist_real"
}

build_iso() {
  local build_date
  local built_iso
  local dist_real
  local final_iso
  local git_rev
  local marker="$BUILD_DIR/task-6-mkarchiso-start"
  local -a built_isos=()

  dist_real=$(assert_safe_dist)
  mkdir -p -- "$dist_real"
  [[ -d "$dist_real" && ! -L "$dist_real" ]] ||
    die "unsafe distribution directory: $dist_real"
  for input in rootfs.tar.zst rootfs.tar.zst.sha256 target-packages.txt \
    build-manifest.txt; do
    [[ -f "$PAYLOAD_DIR/$input" && ! -L "$PAYLOAD_DIR/$input" ]] ||
      die "missing or unsafe build payload: $PAYLOAD_DIR/$input"
  done

  "$SCRIPT_DIR/prepare-archiso.sh"
  reset_build_directory "$WORK_DIR" >/dev/null
  : >"$marker"
  mkarchiso -v -w "$WORK_DIR" -o "$dist_real" "$PROFILE_DIR"
  mapfile -d '' -t built_isos < <(
    find "$dist_real" -maxdepth 1 -type f -name '*.iso' -newer "$marker" -print0
  )
  rm -f -- "$marker"
  ((${#built_isos[@]} == 1)) ||
    die "mkarchiso must create exactly one new ISO; found ${#built_isos[@]}"
  built_iso=${built_isos[0]}

  build_date=$(date -u +%Y%m%d)
  git_rev=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
  [[ "$build_date" =~ ^[0-9]{8}$ ]] || die 'invalid UTC build date'
  [[ "$git_rev" =~ ^[0-9a-f]+$ ]] || die 'invalid Git revision'
  final_iso="$dist_real/blade15-arch-gnome-$build_date-$git_rev.iso"
  [[ ! -e "$final_iso" && ! -L "$final_iso" ]] ||
    die "refusing to replace an existing release artifact: $final_iso"
  mv -- "$built_iso" "$final_iso"

  (
    cd -- "$dist_real"
    sha256sum "${final_iso##*/}" >"${final_iso##*/}.sha256.tmp"
    mv -- "${final_iso##*/}.sha256.tmp" "${final_iso##*/}.sha256"
  )
  install -m0644 "$PAYLOAD_DIR/target-packages.txt" \
    "$dist_real/target-packages.txt"
  install -m0644 "$PAYLOAD_DIR/build-manifest.txt" \
    "$dist_real/build-manifest.txt"
  printf 'ISO build: PASS (%s)\n' "$final_iso"
}

main() {
  if is_dry_run || [[ ${1:-} == --dry-run ]]; then
    print_plan
    return 0
  fi
  (($# == 0)) || die 'usage: build-iso.sh [--dry-run]'
  require_privileged_arch
  command -v mkarchiso >/dev/null || die 'mkarchiso is required'
  build_iso
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
