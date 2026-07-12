#!/usr/bin/env bash

_installer_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_installer_lib_dir/common.sh"
unset _installer_lib_dir

_lsblk_json() {
  if [[ -n "${LSBLK_JSON_FILE:-}" ]]; then
    [[ -r "$LSBLK_JSON_FILE" ]] || die "Cannot read injected lsblk data"
    command cat -- "$LSBLK_JSON_FILE"
    return
  fi

  "${LSBLK_BIN:-lsblk}" --json --bytes \
    --output NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,RM,MOUNTPOINTS
}

_live_root_source() {
  local source_path
  local live_mount=${LIVE_BOOT_MOUNT:-/run/archiso/bootmnt}

  if [[ -n "${LIVE_ROOT_SOURCE:-}" ]]; then
    source_path=$LIVE_ROOT_SOURCE
  elif ! source_path=$("${FINDMNT_BIN:-findmnt}" -nro SOURCE "$live_mount"); then
    die "Unable to identify the live-root source"
  fi

  source_path=${source_path%%\[*}
  [[ "$source_path" == /dev/* ]] || die "Live-root source is not a block device"
  printf '%s\n' "$source_path"
}

_fixture_parent_name() {
  local device=$1

  jq -er --arg target "$device" '
    def nodes($parent):
      . as $node
      | {path: (.path // ("/dev/" + .name)), parent: $parent},
        (.children[]? | nodes($node.name));
    [.blockdevices[] | nodes(null) | select(.path == $target)][0]
    | if . == null then error("device not present") else (.parent // "") end
  ' "$LSBLK_JSON_FILE"
}

_parent_name() {
  local device=$1

  if [[ -n "${LSBLK_JSON_FILE:-}" ]]; then
    _fixture_parent_name "$device"
    return
  fi

  "${LSBLK_BIN:-lsblk}" -ndo PKNAME -- "$device"
}

boot_disk() {
  local current
  local parent
  local depth=0

  current=$(_live_root_source)
  while true; do
    if ! parent=$(_parent_name "$current"); then
      die "Unable to resolve live boot-disk ancestry"
    fi
    [[ -n "$parent" ]] || break
    current="/dev/$parent"
    ((depth += 1))
    ((depth < 64)) || die "Live boot-disk ancestry is invalid"
  done

  printf '%s\n' "$current"
}

candidate_disks() {
  local boot
  local json

  boot=$(boot_disk)
  if ! json=$(_lsblk_json); then
    die "Unable to enumerate disks"
  fi

  if ! jq -er --arg boot "$boot" '
    def subtree: ., (.children[]? | subtree);
    .blockdevices[]
    | select(.type == "disk")
    | select(.rm == false)
    | select(.path != $boot)
    | select(
        [subtree
          | (.mountpoints // [])[]?
          | select(. != null and . != "")]
        | length == 0
      )
    | .path
  ' <<<"$json"; then
    die "Unable to filter candidate disks"
  fi
}

assert_safe_target() {
  local requested=${1-}
  local candidates
  local candidate

  [[ -n "$requested" ]] || die "No safe target disk was selected"
  if ! candidates=$(candidate_disks); then
    die "Unable to refresh safe target disks"
  fi
  while IFS= read -r candidate; do
    [[ "$candidate" == "$requested" ]] && return 0
  done <<<"$candidates"

  die "No safe target disk matches $requested"
}
