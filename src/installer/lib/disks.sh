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

_archiso_search_uuid() {
  local cmdline_file=${CMDLINE_FILE:-/proc/cmdline}
  local cmdline=''
  local match_count=0
  local token
  local uuid=''
  local -a tokens=()

  [[ -r "$cmdline_file" ]] || die "Cannot read the kernel command line"
  IFS= read -r cmdline <"$cmdline_file" || [[ -n "$cmdline" ]] ||
    die "Cannot read the kernel command line"
  read -r -a tokens <<<"$cmdline"

  for token in "${tokens[@]}"; do
    [[ "$token" == archisosearchuuid=* ]] || continue
    ((match_count += 1))
    uuid=${token#archisosearchuuid=}
  done

  ((match_count == 1)) || die "Expected exactly one archisosearchuuid token"
  [[ "$uuid" =~ ^[0-9]{4}(-[0-9]{2}){6}$ ]] ||
    die "The archisosearchuuid value is malformed"
  printf '%s\n' "$uuid"
}

_device_present_in_lsblk() {
  local device=$1
  local json

  if ! json=$(_lsblk_json); then
    return 1
  fi
  jq -e --arg device "$device" '
    def subtree: ., (.children[]? | subtree);
    [.blockdevices[]? | subtree
      | select((.path // ("/dev/" + .name)) == $device)]
    | length == 1
  ' <<<"$json" >/dev/null
}

_live_root_source_from_uuid() {
  local matches
  local source_path
  local uuid

  if ! uuid=$(_archiso_search_uuid); then
    die "Unable to identify the live-root UUID"
  fi
  if ! matches=$("${BLKID_BIN:-blkid}" -t "UUID=$uuid" -o device); then
    die "Unable to resolve the live-root UUID"
  fi
  [[ -n "$matches" && "$matches" != *$'\n'* ]] ||
    die "The live-root UUID did not resolve uniquely"
  source_path=$matches
  [[ "$source_path" == /dev/* ]] || die "Live-root source is not a block device"
  if [[ -z "${LSBLK_JSON_FILE:-}" && ! -b "$source_path" ]]; then
    die "Live-root source is not a current block device"
  fi
  _device_present_in_lsblk "$source_path" ||
    die "Live-root source is absent from current block-device data"

  printf '%s\n' "$source_path"
}

_live_root_source() {
  local source_path
  local live_mount=${LIVE_BOOT_MOUNT:-/run/archiso/bootmnt}

  if [[ -n "${LIVE_ROOT_SOURCE:-}" ]]; then
    source_path=$LIVE_ROOT_SOURCE
  elif source_path=$("${FINDMNT_BIN:-findmnt}" -nro SOURCE "$live_mount"); then
    :
  elif ! source_path=$(_live_root_source_from_uuid); then
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

  if ! current=$(_live_root_source); then
    die "Unable to identify the live boot disk"
  fi
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

  if ! boot=$(boot_disk); then
    die "Unable to identify the live boot disk"
  fi
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
