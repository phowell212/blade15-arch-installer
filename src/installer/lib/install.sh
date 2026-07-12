#!/usr/bin/env bash

_install_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_install_lib_dir/common.sh"
# shellcheck source=/dev/null
source "$_install_lib_dir/identity.sh"
# shellcheck source=/dev/null
source "$_install_lib_dir/disks.sh"
_build_env_file=${BUILD_ENV_FILE:-"$_install_lib_dir/../../../config/build.env"}
if [[ -r "$_build_env_file" ]]; then
  # shellcheck source=/dev/null
  source "$_build_env_file"
fi
DEFAULT_TARGET_CONFIG_SOURCE="$_install_lib_dir/../../target-rootfs"
unset _install_lib_dir _build_env_file

: "${DEFAULT_TIMEZONE:?DEFAULT_TIMEZONE is required}"

_partition_path() {
  local device=${1-}
  local number=${2-}

  [[ -n "$device" && "$number" =~ ^[1-9][0-9]*$ ]] ||
    die "A whole-disk path and partition number are required"
  if [[ "$device" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$device" "$number"
  else
    printf '%s%s\n' "$device" "$number"
  fi
}

_target_mounts_in_use() {
  local target_mount=${1-}
  local mount_targets
  local mounted_path

  [[ "$target_mount" == /* && "$target_mount" != / ]] ||
    die "Target mount path must be an absolute non-root path"
  while [[ "$target_mount" == */ ]]; do
    target_mount=${target_mount%/}
  done

  if ! mount_targets=$("${FINDMNT_BIN:-findmnt}" \
    --raw --noheadings --output TARGET); then
    die "Unable to inspect active mountpoints"
  fi
  while IFS= read -r mounted_path; do
    [[ -n "$mounted_path" ]] || continue
    while [[ "$mounted_path" != / && "$mounted_path" == */ ]]; do
      mounted_path=${mounted_path%/}
    done
    if [[ "$mounted_path" == "$target_mount" ||
      "$mounted_path" == "$target_mount/"* ]]; then
      return 0
    fi
  done <<<"$mount_targets"
  return 1
}

partition_target() {
  local device=${1-}
  local target_mount=${TARGET_MOUNT:-/mnt}
  local boot_partition
  local root_partition

  [[ -n "$device" ]] || die "Target disk is required"
  require_wipe_confirmation "${WIPE_CONFIRMATION:-}" ||
    die "Exact WIPE confirmation is required"

  boot_partition=$(_partition_path "$device" 1)
  root_partition=$(_partition_path "$device" 2)
  if _target_mounts_in_use "$target_mount"; then
    die "Target mount path is already in use: $target_mount"
  fi

  assert_safe_target "$device" || die "Target disk failed the safety check"
  "${WIPEFS_BIN:-wipefs}" --all -- "$device"
  "${SGDISK_BIN:-sgdisk}" --zap-all "$device"
  "${SGDISK_BIN:-sgdisk}" -n 1:0:+1G -t 1:ef00 -c 1:EFI "$device"
  "${SGDISK_BIN:-sgdisk}" -n 2:0:0 -t 2:8304 -c 2:ARCHROOT "$device"
  "${PARTPROBE_BIN:-partprobe}" "$device"
  "${UDEVADM_BIN:-udevadm}" settle
  "${MKFS_FAT_BIN:-mkfs.fat}" -F 32 -n EFI "$boot_partition"
  "${MKFS_EXT4_BIN:-mkfs.ext4}" -F -L ARCHROOT "$root_partition"

  mkdir -p "$target_mount"
  "${MOUNT_BIN:-mount}" -- "$root_partition" "$target_mount"
  mkdir -p "$target_mount/boot"
  "${MOUNT_BIN:-mount}" -- "$boot_partition" "$target_mount/boot"
}

_payload_checksum_digest() {
  local checksum=${1-}
  local line
  local digest=''
  local entry_count=0

  [[ -r "$checksum" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    ((entry_count += 1))
    ((entry_count == 1)) || return 1
    if [[ "$line" =~ ^([[:xdigit:]]{64})([[:space:]]|$) ]]; then
      digest=${BASH_REMATCH[1],,}
    else
      return 1
    fi
  done <"$checksum"

  ((entry_count == 1)) || return 1
  printf '%s\n' "$digest"
}

extract_target() {
  local device=${1-}
  local target_mount=${TARGET_MOUNT:-/mnt}
  local payload=${PAYLOAD_PATH:-/usr/share/blade-installer/rootfs.tar.zst}
  local checksum=${PAYLOAD_CHECKSUM_PATH:-$payload.sha256}
  local expected_digest
  local actual_output
  local actual_digest

  [[ -n "$device" ]] || die "Target disk is required"
  [[ -r "$payload" ]] || die "Cannot read root filesystem payload: $payload"
  [[ -r "$checksum" ]] || die "Cannot read payload checksum: $checksum"
  [[ -d "$target_mount" ]] || die "Target root is not mounted"

  if ! expected_digest=$(_payload_checksum_digest "$checksum"); then
    die "Payload checksum sidecar must contain exactly one 64-hex digest"
  fi
  if ! actual_output=$("${SHA256SUM_BIN:-sha256sum}" "$payload"); then
    die "Root filesystem payload checksum verification failed"
  fi
  if [[ "$actual_output" =~ ^([[:xdigit:]]{64})([[:space:]]|$) ]]; then
    actual_digest=${BASH_REMATCH[1],,}
  else
    die "Unable to parse the root filesystem payload digest"
  fi
  [[ "$actual_digest" == "$expected_digest" ]] ||
    die "Root filesystem payload checksum verification failed"

  if ! "${ZSTD_BIN:-zstd}" -dc "$payload" |
    "${BSDTAR_BIN:-bsdtar}" --acls --xattrs --numeric-owner \
      -xpf - -C "$target_mount"; then
    die "Root filesystem payload extraction failed"
  fi
}

_filesystem_uuid() {
  local root=$1
  local relative_mount=$2
  local injected_name=$3
  local mount_path=$root$relative_mount
  local source_device
  local uuid

  if [[ -n "${!injected_name:-}" ]]; then
    printf '%s\n' "${!injected_name}"
    return 0
  fi

  if ! source_device=$("${FINDMNT_BIN:-findmnt}" -nro SOURCE --target "$mount_path"); then
    die "Unable to identify the filesystem mounted at $mount_path"
  fi
  source_device=${source_device%%\[*}
  if ! uuid=$("${BLKID_BIN:-blkid}" -s UUID -o value -- "$source_device"); then
    die "Unable to identify the filesystem UUID for $source_device"
  fi
  [[ -n "$uuid" ]] || die "Filesystem $source_device has no UUID"
  printf '%s\n' "$uuid"
}

_install_shared_config() {
  local root=$1
  local relative_path=$2
  local mode=$3
  local source_root=${TARGET_CONFIG_SOURCE:-$DEFAULT_TARGET_CONFIG_SOURCE}
  local source_path=$source_root/$relative_path
  local target_path=$root/$relative_path

  if [[ -f "$source_path" ]]; then
    "${INSTALL_BIN:-install}" -D -m "$mode" -- "$source_path" "$target_path"
  else
    [[ -s "$target_path" ]] || die "Missing shared target configuration: /$relative_path"
    chmod "$mode" "$target_path"
  fi
}

write_target_config() {
  local root=${1-}
  local username=${2-}
  local hostname=${3-}
  local root_uuid
  local boot_uuid

  [[ -n "$root" ]] || die "Target root is required"
  valid_username "$username" || die "A valid username is required"
  valid_hostname "$hostname" || die "A valid hostname is required"

  root_uuid=$(_filesystem_uuid "$root" '' ROOT_UUID)
  boot_uuid=$(_filesystem_uuid "$root" /boot BOOT_UUID)

  mkdir -p \
    "$root/etc/NetworkManager/system-connections" \
    "$root/etc/sudoers.d" \
    "$root/var/lib/blade-installer"
  chmod 0700 "$root/etc/NetworkManager/system-connections"

  printf 'UUID=%s\t/boot\tvfat\tdefaults,noatime\t0\t2\n' "$boot_uuid" >"$root/etc/fstab"
  printf 'UUID=%s\t/\text4\tdefaults,noatime\t0\t1\n' "$root_uuid" >>"$root/etc/fstab"
  rm -f -- "$root/etc/crypttab"

  printf 'LANG=en_US.UTF-8\n' >"$root/etc/locale.conf"
  printf 'en_US.UTF-8 UTF-8\n' >"$root/etc/locale.gen"
  printf 'KEYMAP=us\n' >"$root/etc/vconsole.conf"
  ln -sfn "/usr/share/zoneinfo/$DEFAULT_TIMEZONE" "$root/etc/localtime"
  printf '%s\n' "$hostname" >"$root/etc/hostname"
  printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' \
    "$hostname" "$hostname" >"$root/etc/hosts"
  : >"$root/etc/machine-id"

  _install_shared_config "$root" etc/zram-generator.conf 0644
  _install_shared_config "$root" etc/modprobe.d/nvidia.conf 0644
  _install_shared_config "$root" etc/mkinitcpio.conf.d/graphics.conf 0644
  _install_shared_config "$root" etc/sudoers.d/10-wheel 0440
}

install_systemd_boot() {
  local root=${1-}
  local root_uuid=${2-}
  local loader_dir

  [[ -n "$root" ]] || die "Target root is required"
  [[ -n "$root_uuid" ]] || die "Root filesystem UUID is required"
  loader_dir=$root/boot/loader

  "${ARCH_CHROOT_BIN:-arch-chroot}" "$root" bootctl --esp-path=/boot install
  mkdir -p "$loader_dir/entries"
  printf 'default blade-linux.conf\ntimeout 10\nconsole-mode max\neditor no\n' \
    >"$loader_dir/loader.conf"

  cat >"$loader_dir/entries/blade-linux.conf" <<EOF
title Blade Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=UUID=$root_uuid rw nvidia_drm.modeset=1
EOF

  cat >"$loader_dir/entries/blade-intel-recovery.conf" <<EOF
title Blade Arch Linux (Intel-only recovery)
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=UUID=$root_uuid rw module_blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm
EOF

  cat >"$loader_dir/entries/blade-text-recovery.conf" <<EOF
title Blade Arch Linux (text recovery)
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=UUID=$root_uuid rw systemd.unit=multi-user.target
EOF

  "${ARCH_CHROOT_BIN:-arch-chroot}" "$root" mkinitcpio -P
  "${SYSTEMCTL_BIN:-systemctl}" --root="$root" enable \
    NetworkManager switcheroo-control power-profiles-daemon fstrim.timer \
    blade-firstboot-gpu.service
  "${SYSTEMCTL_BIN:-systemctl}" --root="$root" disable gdm.service
  "${SYSTEMCTL_BIN:-systemctl}" --root="$root" set-default multi-user.target
}

verify_target() {
  local root=${1-}
  local root_uuid
  local boot_uuid
  local entry

  [[ -n "$root" ]] || die "Target root is required"
  root_uuid=$(_filesystem_uuid "$root" '' ROOT_UUID)
  boot_uuid=$(_filesystem_uuid "$root" /boot BOOT_UUID)

  [[ -x "$root/usr/bin/bash" ]] || die "Target shell is missing"
  [[ -s "$root/boot/vmlinuz-linux" ]] || die "Target kernel is missing"
  [[ -s "$root/boot/initramfs-linux.img" ]] || die "Target initramfs is missing"
  [[ -s "$root/etc/zram-generator.conf" ]] || die "Target zram configuration is missing"
  [[ ! -e "$root/etc/crypttab" ]] || die "Unexpected crypttab in unencrypted target"
  grep -Eq "^UUID=${boot_uuid}[[:space:]]+/boot[[:space:]]+vfat[[:space:]]" \
    "$root/etc/fstab" || die "EFI fstab entry is invalid"
  grep -Eq "^UUID=${root_uuid}[[:space:]]+/[[:space:]]+ext4[[:space:]]" \
    "$root/etc/fstab" || die "Root fstab entry is invalid"
  grep -Fx 'timeout 10' "$root/boot/loader/loader.conf" >/dev/null ||
    die "systemd-boot timeout is invalid"

  for entry in blade-linux blade-intel-recovery blade-text-recovery; do
    [[ -s "$root/boot/loader/entries/$entry.conf" ]] ||
      die "Missing systemd-boot entry: $entry"
  done
}
