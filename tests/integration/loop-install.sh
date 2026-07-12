#!/usr/bin/env bash
set -Eeuo pipefail
set +x

if ((EUID != 0)); then
  printf 'loop install: root is required\n' >&2
  exit 1
fi
if [[ ! -c /dev/loop-control ]]; then
  printf 'loop install: BLOCKED_BY_ENVIRONMENT: /dev/loop-control is unavailable\n' >&2
  exit 77
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/blade-loop-install.XXXXXX")
IMAGE_PATH=$TEST_ROOT/installer-disk.img
PAYLOAD_ROOT=$TEST_ROOT/payload-root
PAYLOAD_PATH=$TEST_ROOT/rootfs.tar.zst
PAYLOAD_CHECKSUM_PATH=$PAYLOAD_PATH.sha256
TARGET_MOUNT=$TEST_ROOT/target
TARGET_CONFIG_SOURCE=$REPO_ROOT/src/target-rootfs
LOOP_DEVICE=''
VERIFIED_LOOP_DEVICE=''

fail() {
  printf 'loop install: FAIL: %s\n' "$*" >&2
  exit 1
}

trim_whitespace() {
  local value=${1-}

  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

confirm_loop_backing() {
  local device=${1-}
  local actual_backing
  local expected_backing

  [[ -n "$VERIFIED_LOOP_DEVICE" ]] || fail "loop device was not verified"
  [[ "$device" == "$VERIFIED_LOOP_DEVICE" ]] ||
    fail "refusing unexpected target $device"
  [[ "$device" =~ ^/dev/loop[0-9]+$ && -b "$device" ]] ||
    fail "target is not a loop block device: $device"
  actual_backing=$(losetup --noheadings --raw --output BACK-FILE "$device") ||
    fail "cannot query exact loop target $device"
  actual_backing=$(trim_whitespace "$actual_backing")
  actual_backing=$(readlink -f -- "$actual_backing")
  expected_backing=$(readlink -f -- "$IMAGE_PATH")
  [[ "$actual_backing" == "$expected_backing" ]] ||
    fail "$device is not attached to the fresh sparse image"
}

cleanup() {
  local status=$?
  local current_backing=''
  local detach_candidate=${VERIFIED_LOOP_DEVICE:-$LOOP_DEVICE}

  trap - EXIT INT TERM
  set +e
  if [[ -n "$TARGET_MOUNT" && "$TARGET_MOUNT" == "$TEST_ROOT/target" ]]; then
    mountpoint -q "$TARGET_MOUNT/boot" && umount "$TARGET_MOUNT/boot"
    mountpoint -q "$TARGET_MOUNT" && umount "$TARGET_MOUNT"
  fi
  if [[ -n "$detach_candidate" && "$detach_candidate" =~ ^/dev/loop[0-9]+$ ]]; then
    current_backing=$(losetup --noheadings --raw --output BACK-FILE "$detach_candidate" 2>/dev/null)
    current_backing=$(trim_whitespace "$current_backing")
    if [[ -n "$current_backing" ]] &&
      [[ "$(readlink -f -- "$current_backing")" == "$(readlink -f -- "$IMAGE_PATH")" ]]; then
      losetup --detach "$detach_candidate"
    else
      printf 'loop install: cleanup refused to detach an unverified loop device\n' >&2
    fi
  fi
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/blade-loop-install.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'loop install: cleanup refused unexpected path %s\n' "$TEST_ROOT" >&2 ;;
  esac
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in losetup truncate readlink mountpoint umount findmnt wipefs \
  sgdisk partprobe udevadm mkfs.fat mkfs.ext4 mount sha256sum zstd bsdtar \
  blkid cryptsetup; do
  command -v "$command_name" >/dev/null || fail "required command is missing: $command_name"
done

# shellcheck source=/dev/null
source "$REPO_ROOT/src/installer/lib/install.sh"

mkdir -p "$PAYLOAD_ROOT/usr/bin" "$PAYLOAD_ROOT/boot" "$PAYLOAD_ROOT/etc"
printf '#!/usr/bin/env bash\n' >"$PAYLOAD_ROOT/usr/bin/bash"
chmod 0755 "$PAYLOAD_ROOT/usr/bin/bash"
printf 'integration-test-kernel\n' >"$PAYLOAD_ROOT/boot/vmlinuz-linux"
printf 'integration-test-initramfs\n' >"$PAYLOAD_ROOT/boot/initramfs-linux.img"
bsdtar --acls --xattrs --numeric-owner -cpf - -C "$PAYLOAD_ROOT" . |
  zstd -q -T0 -o "$PAYLOAD_PATH"
(
  cd -- "$TEST_ROOT"
  sha256sum "$(basename -- "$PAYLOAD_PATH")" >"$(basename -- "$PAYLOAD_CHECKSUM_PATH")"
)

truncate --size 6G "$IMAGE_PATH"
LOOP_DEVICE=$(losetup --find --show --partscan "$IMAGE_PATH")
VERIFIED_LOOP_DEVICE=$(readlink -f -- "$LOOP_DEVICE")
confirm_loop_backing "$VERIFIED_LOOP_DEVICE"

# This is the sole test-only safety override. It accepts exactly the loop path
# already proven to back IMAGE_PATH and rechecks that association immediately
# before partition_target reaches its wipe operation.
assert_safe_target() {
  local requested=${1-}

  [[ "$requested" == "$VERIFIED_LOOP_DEVICE" ]] ||
    fail "safety override rejected unexpected target $requested"
  confirm_loop_backing "$requested"
}

BLADE_TEST_MODE=1
WIPE_CONFIRMATION=WIPE
export BLADE_TEST_MODE WIPE_CONFIRMATION TARGET_MOUNT PAYLOAD_PATH \
  PAYLOAD_CHECKSUM_PATH TARGET_CONFIG_SOURCE
partition_target "$VERIFIED_LOOP_DEVICE"

BOOT_PARTITION=$(_partition_path "$VERIFIED_LOOP_DEVICE" 1)
ROOT_PARTITION=$(_partition_path "$VERIFIED_LOOP_DEVICE" 2)
[[ -b "$BOOT_PARTITION" && -b "$ROOT_PARTITION" ]] ||
  fail "partition block devices were not created"

extract_target "$VERIFIED_LOOP_DEVICE"
write_target_config "$TARGET_MOUNT" blade blade15
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PARTITION")
ARCH_CHROOT_BIN=/bin/true SYSTEMCTL_BIN=/bin/true \
  install_systemd_boot "$TARGET_MOUNT" "$ROOT_UUID"
verify_target "$TARGET_MOUNT"

sgdisk -i 1 "$VERIFIED_LOOP_DEVICE" |
  grep -Fq 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' ||
  fail "partition 1 is not the EFI System Partition type"
sgdisk -i 2 "$VERIFIED_LOOP_DEVICE" |
  grep -Fq '4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709' ||
  fail "partition 2 is not the Linux x86-64 root type"
[[ "$(blkid -s TYPE -o value "$BOOT_PARTITION")" == vfat ]] ||
  fail "EFI filesystem is not FAT"
[[ "$(blkid -s LABEL -o value "$BOOT_PARTITION")" == EFI ]] ||
  fail "EFI filesystem label is wrong"
[[ "$(blkid -s TYPE -o value "$ROOT_PARTITION")" == ext4 ]] ||
  fail "root filesystem is not ext4"
[[ "$(blkid -s LABEL -o value "$ROOT_PARTITION")" == ARCHROOT ]] ||
  fail "root filesystem label is wrong"
grep -Eq "^UUID=${BOOT_UUID}[[:space:]]+/boot[[:space:]]+vfat[[:space:]]" \
  "$TARGET_MOUNT/etc/fstab" || fail "fstab EFI UUID is wrong"
grep -Eq "^UUID=${ROOT_UUID}[[:space:]]+/[[:space:]]+ext4[[:space:]]" \
  "$TARGET_MOUNT/etc/fstab" || fail "fstab root UUID is wrong"
for entry in blade-linux blade-intel-recovery blade-text-recovery; do
  [[ -s "$TARGET_MOUNT/boot/loader/entries/$entry.conf" ]] ||
    fail "missing loader entry $entry"
done
[[ ! -e "$TARGET_MOUNT/etc/crypttab" ]] || fail "crypttab was created"
if cryptsetup isLuks "$BOOT_PARTITION" || cryptsetup isLuks "$ROOT_PARTITION"; then
  fail "unexpected LUKS signature"
fi

printf 'loop install: PASS\n'
