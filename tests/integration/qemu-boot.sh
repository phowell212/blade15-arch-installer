#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/lib/build-common.sh disable=SC1091
source "$REPO_ROOT/scripts/lib/build-common.sh"

TEST_DIR="$BUILD_DIR/qemu-boot"
DISK_IMAGE="$TEST_DIR/installer-target.qcow2"
OVMF_VARS_COPY="$TEST_DIR/OVMF_VARS.fd"
EXPECT_SCRIPT="$SCRIPT_DIR/qemu-boot.exp"

cleanup_qemu_test() {
  if [[ -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    clear_build_directory "$TEST_DIR" >/dev/null || true
    rmdir -- "$TEST_DIR" 2>/dev/null || true
  fi
}

find_ovmf_pair() {
  local code
  local vars
  local pair
  local -a pairs=(
    '/usr/share/edk2/x64/OVMF_CODE.4m.fd|/usr/share/edk2/x64/OVMF_VARS.4m.fd'
    '/usr/share/edk2/x64/OVMF_CODE.fd|/usr/share/edk2/x64/OVMF_VARS.fd'
    '/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd'
    '/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd'
  )

  if [[ -n ${OVMF_CODE:-} || -n ${OVMF_VARS:-} ]]; then
    [[ -r ${OVMF_CODE:-} && -r ${OVMF_VARS:-} ]] ||
      die 'both OVMF_CODE and OVMF_VARS must name readable files'
    printf '%s|%s\n' "$OVMF_CODE" "$OVMF_VARS"
    return
  fi
  for pair in "${pairs[@]}"; do
    code=${pair%%|*}
    vars=${pair#*|}
    if [[ -r "$code" && -r "$vars" ]]; then
      printf '%s\n' "$pair"
      return
    fi
  done
  die 'unable to find a matching OVMF CODE/VARS pair'
}

assert_disk_unmodified() {
  local mapping

  mapping=$(qemu-img map --output=json "$DISK_IMAGE")
  jq -e 'all(.[]; .data == false)' <<<"$mapping" >/dev/null ||
    die 'QEMU target contains allocated guest data before exact WIPE confirmation'
}

run_qemu_tests() {
  local accel=tcg
  local iso
  local ovmf_code
  local ovmf_pair
  local ovmf_vars
  local -a isos=()

  mapfile -d '' -t isos < <(
    find "$REPO_ROOT/dist" -maxdepth 1 -type f \
      -name 'blade15-arch-gnome-[0-9]*-[0-9a-f]*.iso' -print0
  )
  ((${#isos[@]} == 1)) ||
    die "expected exactly one release ISO; found ${#isos[@]}"
  iso=${isos[0]}
  ovmf_pair=$(find_ovmf_pair)
  ovmf_code=${ovmf_pair%%|*}
  ovmf_vars=${ovmf_pair#*|}
  [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] && accel=kvm

  reset_build_directory "$TEST_DIR" >/dev/null
  trap cleanup_qemu_test EXIT
  qemu-img create -q -f qcow2 "$DISK_IMAGE" 64G
  cp -- "$ovmf_vars" "$OVMF_VARS_COPY"
  expect "$EXPECT_SCRIPT" rescue "$iso" "$DISK_IMAGE" "$ovmf_code" \
    "$OVMF_VARS_COPY" "$accel"
  assert_disk_unmodified

  cp -- "$ovmf_vars" "$OVMF_VARS_COPY"
  expect "$EXPECT_SCRIPT" installer "$iso" "$DISK_IMAGE" "$ovmf_code" \
    "$OVMF_VARS_COPY" "$accel"
  assert_disk_unmodified

  cleanup_qemu_test
  trap - EXIT
  printf 'qemu boot: PASS\n'
}

main() {
  if is_dry_run || [[ ${1:-} == --dry-run ]]; then
    printf '%s\n' \
      'boot release ISO with QEMU/OVMF and a disposable NVMe disk' \
      'verify QEMU bypass rejection without blade.test=1 from serial rescue' \
      'boot QEMU serial installer test and send CANCEL instead of WIPE' \
      'verify qemu-img map contains no allocated guest data' \
      'qemu boot: CI-DEFERRED'
    return 0
  fi
  (($# == 0)) || die 'usage: qemu-boot.sh [--dry-run]'
  for command_name in qemu-system-x86_64 qemu-img expect jq; do
    command -v "$command_name" >/dev/null || die "$command_name is required"
  done
  [[ -x "$EXPECT_SCRIPT" ]] || die "Expect harness is not executable: $EXPECT_SCRIPT"
  run_qemu_tests
}

main "$@"
