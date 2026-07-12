#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-installer-bats.$$.$BATS_TEST_NUMBER}"
  mkdir -p "$BATS_TEST_TMPDIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  if [[ -f "$REPO_ROOT/src/installer/lib/preflight.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/src/installer/lib/preflight.sh"
  fi
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  : >"$CMDLINE_FILE"
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

@test "physical install requires UEFI" {
  UEFI_PATH="$BATS_TEST_TMPDIR/missing" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *UEFI* ]]
}

@test "enabled Secure Boot is rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/efi"
  UEFI_PATH="$BATS_TEST_TMPDIR/efi" SECURE_BOOT_VALUE=1 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *Secure\ Boot* ]]
}

@test "exact Razer family is accepted" {
  mkdir -p "$BATS_TEST_TMPDIR/efi"
  UEFI_PATH="$BATS_TEST_TMPDIR/efi" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -eq 0 ]
}

@test "unsupported physical hardware is rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/efi"
  UEFI_PATH="$BATS_TEST_TMPDIR/efi" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-04210'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *unsupported* ]]
}

@test "cmdline flag matching is token-exact" {
  printf '%s\n' 'quiet blade.test=10 rescue=1' >"$CMDLINE_FILE"
  run cmdline_has 'blade.test=1'
  [ "$status" -ne 0 ]

  printf '%s\n' 'quiet blade.test=1 rescue=1' >"$CMDLINE_FILE"
  run cmdline_has 'blade.test=1'
  [ "$status" -eq 0 ]
}

@test "cmdline matching does not expand shell globs" {
  printf '%s\n' 'quiet blade.test=*' >"$CMDLINE_FILE"
  touch "$BATS_TEST_TMPDIR/blade.test=1"
  cd "$BATS_TEST_TMPDIR"

  run cmdline_has 'blade.test=1'
  [ "$status" -ne 0 ]
}

@test "QEMU without explicit test flag cannot bypass platform checks" {
  UEFI_PATH="$BATS_TEST_TMPDIR/missing" SECURE_BOOT_VALUE=1 DMI_VENDOR=QEMU DMI_PRODUCT='Standard PC (Q35 + ICH9, 2009)'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *UEFI* ]]
}

@test "test flag on physical hardware cannot bypass platform checks" {
  printf '%s\n' 'quiet blade.test=1' >"$CMDLINE_FILE"
  UEFI_PATH="$BATS_TEST_TMPDIR/missing" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *UEFI* ]]
}

@test "QEMU with explicit test flag may bypass physical platform checks" {
  printf '%s\n' 'quiet blade.test=1' >"$CMDLINE_FILE"
  UEFI_PATH="$BATS_TEST_TMPDIR/missing" SECURE_BOOT_VALUE=1 DMI_VENDOR=QEMU DMI_PRODUCT='Standard PC (Q35 + ICH9, 2009)'
  run require_supported_platform
  [ "$status" -eq 0 ]
}
