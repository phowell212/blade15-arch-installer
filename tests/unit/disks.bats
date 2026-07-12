#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-installer-bats.$$.$BATS_TEST_NUMBER}"
  mkdir -p "$BATS_TEST_TMPDIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  if [[ -f "$REPO_ROOT/src/installer/lib/disks.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/src/installer/lib/disks.sh"
  fi
  LSBLK_JSON_FILE="$REPO_ROOT/tests/fixtures/lsblk-two-disks.json"
  LIVE_ROOT_SOURCE=/dev/sdb1
  LIVE_BOOT_MOUNT=/run/archiso/bootmnt
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

@test "boot disk resolves the live-root partition to its whole parent disk" {
  run boot_disk
  [ "$status" -eq 0 ]
  [ "$output" = /dev/sdb ]
}

@test "candidate disks exclude the whole live boot disk" {
  run candidate_disks
  [ "$status" -eq 0 ]
  [ "$output" = /dev/nvme0n1 ]
  [[ "$output" != *'/dev/sdb'* ]]
}

@test "safe internal whole disk is accepted" {
  run assert_safe_target /dev/nvme0n1
  [ "$status" -eq 0 ]
}

@test "partition paths are rejected as targets" {
  run assert_safe_target /dev/nvme0n1p1
  [ "$status" -ne 0 ]
  [[ "$output" == *safe*target* ]]
}

@test "whole live boot disk is rejected as a target" {
  run assert_safe_target /dev/sdb
  [ "$status" -ne 0 ]
}

@test "disk with a mounted child outside the live ISO is rejected" {
  local mounted_fixture="$BATS_TEST_TMPDIR/mounted.json"
  jq '.blockdevices[0].children[0].mountpoints = ["/mnt/data"]' "$LSBLK_JSON_FILE" >"$mounted_fixture"
  LSBLK_JSON_FILE="$mounted_fixture"

  run assert_safe_target /dev/nvme0n1
  [ "$status" -ne 0 ]
}

@test "disk mounted only below the live ISO mount remains eligible" {
  local live_fixture="$BATS_TEST_TMPDIR/live-mount.json"
  jq '.blockdevices[0].children[0].mountpoints = ["/run/archiso/bootmnt/cache"]' "$LSBLK_JSON_FILE" >"$live_fixture"
  LSBLK_JSON_FILE="$live_fixture"

  run candidate_disks
  [ "$status" -eq 0 ]
  [ "$output" = /dev/nvme0n1 ]
}

@test "removable disks are rejected as targets" {
  local removable_fixture="$BATS_TEST_TMPDIR/removable.json"
  jq '.blockdevices[0].rm = true' "$LSBLK_JSON_FILE" >"$removable_fixture"
  LSBLK_JSON_FILE="$removable_fixture"

  run assert_safe_target /dev/nvme0n1
  [ "$status" -ne 0 ]
}

@test "target assertion fails closed when disk enumeration later errors" {
  local malformed_fixture="$BATS_TEST_TMPDIR/malformed.json"
  jq '(.blockdevices[0]
      | .name = "sdc"
      | .path = "/dev/sdc"
      | .children = []
      | .mountpoints = [42]) as $bad
      | .blockdevices += [$bad]' "$LSBLK_JSON_FILE" >"$malformed_fixture"
  LSBLK_JSON_FILE="$malformed_fixture"

  run assert_safe_target /dev/nvme0n1
  [ "$status" -ne 0 ]
}
