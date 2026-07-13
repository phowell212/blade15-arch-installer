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

  BLKID_BIN="$BATS_TEST_TMPDIR/blkid"
  BLKID_CALL_LOG="$BATS_TEST_TMPDIR/blkid-calls"
  export BLKID_CALL_LOG
  cat >"$BLKID_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BLKID_CALL_LOG"
[[ -z "${BLKID_OUTPUT:-}" ]] || printf '%s\n' "$BLKID_OUTPUT"
exit "${BLKID_STATUS:-0}"
EOF
  chmod +x "$BLKID_BIN"
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

use_copytoram_fallback() {
  unset LIVE_ROOT_SOURCE
  FINDMNT_BIN=false
  CMDLINE_FILE="$REPO_ROOT/tests/fixtures/cmdline-copytoram.txt"
  BLKID_OUTPUT=/dev/sdb1
  BLKID_STATUS=0
  export BLKID_OUTPUT BLKID_STATUS
}

assert_no_candidate_output() {
  [[ "$output" != *'/dev/nvme0n1'* ]]
  [[ "$output" != *'/dev/sdb'* ]]
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

@test "copy-to-RAM fallback resolves one ISO UUID match and excludes its whole disk" {
  use_copytoram_fallback

  run candidate_disks
  [ "$status" -eq 0 ]
  [ "$output" = /dev/nvme0n1 ]
  [ "$(<"$BLKID_CALL_LOG")" = '-t UUID=2026-07-13-12-34-56-00 -o device' ]
}

@test "copy-to-RAM fallback fails closed when the UUID token is missing" {
  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  printf '%s\n' 'quiet copytoram=auto' >"$CMDLINE_FILE"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
  [ ! -s "$BLKID_CALL_LOG" ]
}

@test "copy-to-RAM fallback fails closed when the UUID token is empty" {
  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  printf '%s\n' 'quiet archisosearchuuid= copytoram=auto' >"$CMDLINE_FILE"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
  [ ! -s "$BLKID_CALL_LOG" ]
}

@test "copy-to-RAM fallback fails closed when the ISO UUID is malformed" {
  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  printf '%s\n' \
    'quiet archisosearchuuid=../../dev/sdb1 copytoram=auto' >"$CMDLINE_FILE"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
  [ ! -s "$BLKID_CALL_LOG" ]
}

@test "copy-to-RAM fallback rejects a nonzero Archiso UUID suffix before blkid" {
  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  printf '%s\n' \
    'quiet archisosearchuuid=2026-07-13-12-34-56-01 copytoram=auto' \
    >"$CMDLINE_FILE"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
  [ ! -s "$BLKID_CALL_LOG" ]
}

@test "copy-to-RAM fallback rejects out-of-range Archiso UUID fields before blkid" {
  local invalid_uuid

  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  for invalid_uuid in \
    2026-00-13-12-34-56-00 \
    2026-13-13-12-34-56-00 \
    2026-07-00-12-34-56-00 \
    2026-07-32-12-34-56-00 \
    2026-07-13-24-34-56-00 \
    2026-07-13-12-60-56-00 \
    2026-07-13-12-34-60-00; do
    : >"$BLKID_CALL_LOG"
    printf 'quiet archisosearchuuid=%s copytoram=auto\n' \
      "$invalid_uuid" >"$CMDLINE_FILE"

    run candidate_disks
    [ "$status" -ne 0 ]
    assert_no_candidate_output
    [ ! -s "$BLKID_CALL_LOG" ]
  done
}

@test "copy-to-RAM fallback fails closed on duplicate UUID tokens" {
  use_copytoram_fallback
  CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  printf '%s\n' \
    'archisosearchuuid=2026-07-13-12-34-56-00 copytoram=auto archisosearchuuid=2026-07-13-12-34-56-00' \
    >"$CMDLINE_FILE"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
  [ ! -s "$BLKID_CALL_LOG" ]
}

@test "copy-to-RAM fallback fails closed when blkid finds no UUID match" {
  use_copytoram_fallback
  BLKID_OUTPUT=''
  BLKID_STATUS=2
  export BLKID_OUTPUT BLKID_STATUS

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
}

@test "copy-to-RAM fallback fails closed when blkid finds duplicate UUID matches" {
  use_copytoram_fallback
  BLKID_OUTPUT=$'/dev/sdb1\n/dev/sdb1'
  export BLKID_OUTPUT

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
}

@test "copy-to-RAM fallback fails closed when the UUID match is not a block device" {
  use_copytoram_fallback
  BLKID_OUTPUT=/dev/null
  export BLKID_OUTPUT
  unset LSBLK_JSON_FILE

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
}

@test "copy-to-RAM fallback fails closed when the UUID match is absent from lsblk" {
  use_copytoram_fallback
  BLKID_OUTPUT=/dev/sdz1
  export BLKID_OUTPUT

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
}

@test "copy-to-RAM fallback fails closed when a matched path was reused by another UUID" {
  local reused_fixture="$BATS_TEST_TMPDIR/reused-path.json"

  use_copytoram_fallback
  jq '.blockdevices[1].children[0].uuid = "2026-07-13-12-34-57-00"' \
    "$LSBLK_JSON_FILE" >"$reused_fixture"
  LSBLK_JSON_FILE="$reused_fixture"

  run candidate_disks
  [ "$status" -ne 0 ]
  assert_no_candidate_output
}

@test "installer preflight requires blkid" {
  run awk '/^_phase_preflight\(\)/,/^}/' \
    "$REPO_ROOT/src/installer/blade-install"
  [ "$status" -eq 0 ]
  [[ "$output" == *'blkid'* ]]
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

@test "non-boot disk mounted below the live ISO path is rejected" {
  local live_fixture="$BATS_TEST_TMPDIR/live-mount.json"
  jq '.blockdevices[0].children[0].mountpoints = ["/run/archiso/bootmnt/extra"]' "$LSBLK_JSON_FILE" >"$live_fixture"
  LSBLK_JSON_FILE="$live_fixture"

  run assert_safe_target /dev/nvme0n1
  [ "$status" -ne 0 ]
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
  cp "$LSBLK_JSON_FILE" "$malformed_fixture"
  printf '%s\n' 'not-json' >>"$malformed_fixture"
  LSBLK_JSON_FILE="$malformed_fixture"

  run assert_safe_target /dev/nvme0n1
  [ "$status" -ne 0 ]
}
