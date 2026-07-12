#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-installer-bats.$$.$BATS_TEST_NUMBER}"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TARGET_ROOT="$BATS_TEST_TMPDIR/target"
  TARGET_CONFIG_SOURCE="$REPO_ROOT/src/target-rootfs"
  ROOT_UUID=11111111-2222-3333-4444-555555555555
  BOOT_UUID=AAAA-BBBB
  REAL_SHA256SUM=$(command -v sha256sum)
  mkdir -p "$TARGET_ROOT"

  if [[ -f "$REPO_ROOT/src/installer/lib/install.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/src/installer/lib/install.sh"
  fi
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

generate_config() {
  write_target_config "$TARGET_ROOT" blade blade15
  ARCH_CHROOT_BIN=/bin/true SYSTEMCTL_BIN=/bin/true \
    install_systemd_boot "$TARGET_ROOT" "$ROOT_UUID"
}

assert_success() {
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

make_fake_block_tools() {
  local tool

  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/tool" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >>"$COMMAND_LOG"
if [[ "$tool" == findmnt ]]; then
  if [[ " $* " == *' --target '* ]]; then
    exit 1
  fi
  if [[ -n "${FAKE_MOUNT_TARGETS:-}" ]]; then
    printf '%s\n' "$FAKE_MOUNT_TARGETS"
  fi
fi
SCRIPT
  chmod +x "$FAKE_BIN/tool"
  for tool in findmnt wipefs sgdisk partprobe udevadm mkfs.fat mkfs.ext4 mount; do
    ln -s tool "$FAKE_BIN/$tool"
  done
  export COMMAND_LOG
  PATH="$FAKE_BIN:$PATH"
}

make_fake_extract_tools() {
  local tool

  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/tool" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
tool=${0##*/}
case "$tool" in
  sha256sum)
    printf 'sha256sum %s\n' "$*" >>"$COMMAND_LOG"
    if [[ "${SHA256SUM_STATUS:-0}" -ne 0 ]]; then
      exit "$SHA256SUM_STATUS"
    fi
    if [[ "${1-}" == --check ]]; then
      exit 0
    fi
    printf '%s  %s\n' "$FAKE_SHA256" "${1-}"
    ;;
  zstd)
    printf 'zstd %s\n' "$*" >>"$COMMAND_LOG"
    printf 'archive\n'
    ;;
  bsdtar)
    IFS= read -r archive
    printf 'bsdtar %s|%s\n' "$*" "$archive" >>"$COMMAND_LOG"
    [[ "$archive" = archive ]]
    ;;
esac
SCRIPT
  chmod +x "$FAKE_BIN/tool"
  for tool in sha256sum zstd bsdtar; do
    ln -s tool "$FAKE_BIN/$tool"
  done
  export COMMAND_LOG
  FAKE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export FAKE_SHA256
  PATH="$FAKE_BIN:$PATH"
}

@test "fstab uses filesystem UUIDs and no crypttab" {
  run generate_config
  assert_success

  grep -Eq '^UUID=AAAA-BBBB[[:space:]]+/boot[[:space:]]+vfat[[:space:]]+defaults,noatime[[:space:]]+0[[:space:]]+2$' "$TARGET_ROOT/etc/fstab"
  grep -Eq '^UUID=11111111-2222-3333-4444-555555555555[[:space:]]+/[[:space:]]+ext4[[:space:]]+defaults,noatime[[:space:]]+0[[:space:]]+1$' "$TARGET_ROOT/etc/fstab"
  [ ! -e "$TARGET_ROOT/etc/crypttab" ]
}

@test "systemd-boot has a ten-second menu and three recovery-aware entries" {
  run generate_config
  assert_success

  grep -Fx 'timeout 10' "$TARGET_ROOT/boot/loader/loader.conf"
  grep -Eq '^options .*nvidia_drm\.modeset=1([[:space:]]|$)' "$TARGET_ROOT/boot/loader/entries/blade-linux.conf"
  grep -Eq '^options .*module_blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm([[:space:]]|$)' "$TARGET_ROOT/boot/loader/entries/blade-intel-recovery.conf"
  grep -Eq '^options .*systemd\.unit=multi-user\.target([[:space:]]|$)' "$TARGET_ROOT/boot/loader/entries/blade-text-recovery.conf"
  [ "$(find "$TARGET_ROOT/boot/loader/entries" -maxdepth 1 -type f -name '*.conf' | wc -l)" -eq 3 ]
}

@test "zram and NVIDIA configuration come from the shared target overlay" {
  run generate_config
  assert_success

  grep -Fx 'compression-algorithm = lz4' "$TARGET_ROOT/etc/zram-generator.conf"
  grep -Fx 'zram-size = min(ram / 2, 8192)' "$TARGET_ROOT/etc/zram-generator.conf"
  grep -Fx 'swap-priority = 100' "$TARGET_ROOT/etc/zram-generator.conf"
  grep -Fx 'options nvidia_drm modeset=1 fbdev=1' "$TARGET_ROOT/etc/modprobe.d/nvidia.conf"
  cmp "$TARGET_CONFIG_SOURCE/etc/zram-generator.conf" "$TARGET_ROOT/etc/zram-generator.conf"
  cmp "$TARGET_CONFIG_SOURCE/etc/modprobe.d/nvidia.conf" "$TARGET_ROOT/etc/modprobe.d/nvidia.conf"
}

@test "identity locale sudo and NetworkManager state are generated" {
  run generate_config
  assert_success

  [ "$(<"$TARGET_ROOT/etc/hostname")" = blade15 ]
  grep -Fx '127.0.1.1 blade15.localdomain blade15' "$TARGET_ROOT/etc/hosts"
  grep -Fx 'LANG=en_US.UTF-8' "$TARGET_ROOT/etc/locale.conf"
  grep -Fx 'KEYMAP=us' "$TARGET_ROOT/etc/vconsole.conf"
  [ "$(readlink "$TARGET_ROOT/etc/localtime")" = /usr/share/zoneinfo/America/New_York ]
  grep -Fx '%wheel ALL=(ALL:ALL) ALL' "$TARGET_ROOT/etc/sudoers.d/10-wheel"
  [ "$(stat -c '%a' "$TARGET_ROOT/etc/sudoers.d/10-wheel")" = 440 ]
  [ "$(stat -c '%a' "$TARGET_ROOT/etc/NetworkManager/system-connections")" = 700 ]
  [ -f "$TARGET_ROOT/etc/machine-id" ]
  [ ! -s "$TARGET_ROOT/etc/machine-id" ]
}

@test "boot installation runs bootctl initramfs and bounded service setup against the target" {
  local fake_chroot="$BATS_TEST_TMPDIR/arch-chroot"
  local fake_systemctl="$BATS_TEST_TMPDIR/systemctl"
  local command_log="$BATS_TEST_TMPDIR/commands"

  cat >"$fake_chroot" <<'SCRIPT'
#!/usr/bin/env bash
printf 'arch-chroot %s\n' "$*" >>"$COMMAND_LOG"
SCRIPT
  cat >"$fake_systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
SCRIPT
  chmod +x "$fake_chroot" "$fake_systemctl"

  run env COMMAND_LOG="$command_log" ARCH_CHROOT_BIN="$fake_chroot" SYSTEMCTL_BIN="$fake_systemctl" \
    bash -c 'source "$1"; install_systemd_boot "$2" "$3"' _ \
    "$REPO_ROOT/src/installer/lib/install.sh" "$TARGET_ROOT" "$ROOT_UUID"
  assert_success

  grep -Fx "arch-chroot $TARGET_ROOT bootctl --esp-path=/boot install" "$command_log"
  grep -Fx "arch-chroot $TARGET_ROOT mkinitcpio -P" "$command_log"
  grep -Fx "systemctl --root=$TARGET_ROOT enable NetworkManager switcheroo-control power-profiles-daemon fstrim.timer blade-firstboot-gpu.service" "$command_log"
  grep -Fx "systemctl --root=$TARGET_ROOT disable gdm.service" "$command_log"
  grep -Fx "systemctl --root=$TARGET_ROOT set-default multi-user.target" "$command_log"
}

@test "partition paths distinguish digit-ending disk names" {
  run _partition_path /dev/sda 1
  assert_success
  [ "$output" = /dev/sda1 ]

  run _partition_path /dev/nvme0n1 2
  assert_success
  [ "$output" = /dev/nvme0n1p2 ]

  run _partition_path /dev/mmcblk0 1
  assert_success
  [ "$output" = /dev/mmcblk0p1 ]

  run _partition_path /dev/loop7 2
  assert_success
  [ "$output" = /dev/loop7p2 ]
}

@test "partitioning completes all checks before a final guard immediately preceding wipe" {
  local expected="$BATS_TEST_TMPDIR/expected"
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  WIPE_CONFIRMATION=WIPE
  assert_safe_target() { printf 'guard %s\n' "$1" >>"$COMMAND_LOG"; }

  run partition_target /dev/nvme0n1
  assert_success

  cat >"$expected" <<EOF
findmnt --raw --noheadings --output TARGET
guard /dev/nvme0n1
wipefs --all -- /dev/nvme0n1
sgdisk --zap-all /dev/nvme0n1
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI /dev/nvme0n1
sgdisk -n 2:0:0 -t 2:8304 -c 2:ARCHROOT /dev/nvme0n1
partprobe /dev/nvme0n1
udevadm settle
mkfs.fat -F 32 -n EFI /dev/nvme0n1p1
mkfs.ext4 -F -L ARCHROOT /dev/nvme0n1p2
mount -- /dev/nvme0n1p2 $TARGET_MOUNT
mount -- /dev/nvme0n1p1 $TARGET_MOUNT/boot
EOF
  diff -u "$expected" "$COMMAND_LOG"
}

@test "an ordinary existing but unmounted target directory is allowed" {
  local real_findmnt
  real_findmnt=$(command -v findmnt)
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/existing-target"
  FINDMNT_BIN=$real_findmnt
  WIPE_CONFIRMATION=WIPE
  mkdir -p "$TARGET_MOUNT"
  assert_safe_target() { printf 'guard %s\n' "$1" >>"$COMMAND_LOG"; }

  run partition_target /dev/nvme0n1
  assert_success
  grep -Fx 'guard /dev/nvme0n1' "$COMMAND_LOG"
  grep -Fx 'wipefs --all -- /dev/nvme0n1' "$COMMAND_LOG"
}

@test "exact target and descendant mounts are rejected before the final guard" {
  local mounted_path
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/target"
  WIPE_CONFIRMATION=WIPE
  assert_safe_target() { printf 'guard %s\n' "$1" >>"$COMMAND_LOG"; }

  for mounted_path in "$TARGET_MOUNT" "$TARGET_MOUNT/boot" "$TARGET_MOUNT/nested/data"; do
    : >"$COMMAND_LOG"
    FAKE_MOUNT_TARGETS=$mounted_path
    export FAKE_MOUNT_TARGETS
    run partition_target /dev/nvme0n1
    [ "$status" -ne 0 ]
    [ "$(<"$COMMAND_LOG")" = 'findmnt --raw --noheadings --output TARGET' ]
  done
}

@test "a similarly prefixed mount outside the target directory is allowed" {
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/target"
  WIPE_CONFIRMATION=WIPE
  FAKE_MOUNT_TARGETS="$TARGET_MOUNT-other"
  export FAKE_MOUNT_TARGETS
  assert_safe_target() { printf 'guard %s\n' "$1" >>"$COMMAND_LOG"; }

  run partition_target /dev/nvme0n1
  assert_success
  grep -Fx 'guard /dev/nvme0n1' "$COMMAND_LOG"
  grep -Fx 'wipefs --all -- /dev/nvme0n1' "$COMMAND_LOG"
}

@test "test-mode environment alone never bypasses the target guard" {
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  WIPE_CONFIRMATION=WIPE
  BLADE_TEST_MODE=1
  assert_safe_target() {
    printf 'guard %s\n' "$1" >>"$COMMAND_LOG"
    return 1
  }

  run partition_target /dev/loop7
  [ "$status" -ne 0 ]
  [ "$(<"$COMMAND_LOG")" = $'findmnt --raw --noheadings --output TARGET\nguard /dev/loop7' ]
}

@test "partitioning rejects a non-exact wipe confirmation before tools run" {
  make_fake_block_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  WIPE_CONFIRMATION=wipe
  assert_safe_target() { printf 'guard %s\n' "$1" >>"$COMMAND_LOG"; }

  run partition_target /dev/nvme0n1
  [ "$status" -ne 0 ]
  [ ! -e "$COMMAND_LOG" ]
}

@test "extraction verifies the sidecar before streaming the payload" {
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  : >"$PAYLOAD_PATH"
  printf '%s  ignored-name\n' "$FAKE_SHA256" >"$PAYLOAD_PATH.sha256"
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  assert_success

  [ "$(sed -n '1p' "$COMMAND_LOG")" = "sha256sum $PAYLOAD_PATH" ]
  grep -Fx "zstd -dc $PAYLOAD_PATH" "$COMMAND_LOG"
  grep -Fx "bsdtar --acls --xattrs --numeric-owner -xpf - -C $TARGET_MOUNT|archive" "$COMMAND_LOG"
}

@test "a failed payload checksum prevents decompression and extraction" {
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  SHA256SUM_STATUS=1
  export SHA256SUM_STATUS
  : >"$PAYLOAD_PATH"
  printf '%s  ignored-name\n' "$FAKE_SHA256" >"$PAYLOAD_PATH.sha256"
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  [ "$status" -ne 0 ]
  [ "$(wc -l <"$COMMAND_LOG")" -eq 1 ]
  [ "$(<"$COMMAND_LOG")" = "sha256sum $PAYLOAD_PATH" ]
}

@test "payload digest is bound directly while the sidecar filename is ignored" {
  local digest
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  SHA256SUM_BIN=$REAL_SHA256SUM
  printf 'selected payload\n' >"$PAYLOAD_PATH"
  digest=$("$REAL_SHA256SUM" "$PAYLOAD_PATH")
  digest=${digest%% *}
  printf '%s  deliberately-wrong-name\n' "$digest" >"$PAYLOAD_PATH.sha256"
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  assert_success
  grep -Fx "zstd -dc $PAYLOAD_PATH" "$COMMAND_LOG"
}

@test "a valid decoy checksum cannot authorize a tampered selected payload" {
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  SHA256SUM_BIN=$REAL_SHA256SUM
  printf 'tampered selected payload\n' >"$PAYLOAD_PATH"
  printf 'valid decoy payload\n' >"$BATS_TEST_TMPDIR/decoy.tar.zst"
  (
    cd "$BATS_TEST_TMPDIR"
    "$REAL_SHA256SUM" decoy.tar.zst >rootfs.tar.zst.sha256
  )
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  [ "$status" -ne 0 ]
  [ ! -e "$COMMAND_LOG" ]
}

@test "multiple nonblank checksum entries are rejected" {
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  SHA256SUM_BIN=$REAL_SHA256SUM
  printf 'selected payload\n' >"$PAYLOAD_PATH"
  printf 'second payload\n' >"$BATS_TEST_TMPDIR/second.tar.zst"
  (
    cd "$BATS_TEST_TMPDIR"
    "$REAL_SHA256SUM" rootfs.tar.zst second.tar.zst >rootfs.tar.zst.sha256
  )
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  [ "$status" -ne 0 ]
  [ ! -e "$COMMAND_LOG" ]
}

@test "tagged or otherwise malformed checksum entries are rejected" {
  make_fake_extract_tools
  TARGET_MOUNT="$BATS_TEST_TMPDIR/mnt"
  PAYLOAD_PATH="$BATS_TEST_TMPDIR/rootfs.tar.zst"
  SHA256SUM_BIN=$REAL_SHA256SUM
  printf 'selected payload\n' >"$PAYLOAD_PATH"
  (
    cd "$BATS_TEST_TMPDIR"
    "$REAL_SHA256SUM" --tag rootfs.tar.zst >rootfs.tar.zst.sha256
  )
  mkdir -p "$TARGET_MOUNT"

  run extract_target /dev/loop7
  [ "$status" -ne 0 ]
  [ ! -e "$COMMAND_LOG" ]
}

@test "target validation requires the configured system and all loader entries" {
  generate_config
  mkdir -p "$TARGET_ROOT/usr/bin"
  printf '#!/usr/bin/env bash\n' >"$TARGET_ROOT/usr/bin/bash"
  printf 'kernel\n' >"$TARGET_ROOT/boot/vmlinuz-linux"
  printf 'initramfs\n' >"$TARGET_ROOT/boot/initramfs-linux.img"
  chmod +x "$TARGET_ROOT/usr/bin/bash"

  run verify_target "$TARGET_ROOT"
  assert_success

  rm "$TARGET_ROOT/boot/loader/entries/blade-text-recovery.conf"
  run verify_target "$TARGET_ROOT"
  [ "$status" -ne 0 ]
}
