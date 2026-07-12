#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/build-common.sh disable=SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

LIVE_PACKAGE_LIST="$REPO_ROOT/packages/live.txt"
LIVE_OVERLAY="$REPO_ROOT/src/live-rootfs"
INSTALLER_SOURCE="$REPO_ROOT/src/installer"
PAYLOAD_DIR="$BUILD_DIR/payload"
PROFILE_DIR="$BUILD_DIR/archiso-profile"
RELENG_PROFILE=${RELENG_PROFILE:-/usr/share/archiso/configs/releng}
AIROOTFS_DIR="$PROFILE_DIR/airootfs"

SAFE_BOOT_ARGS='systemd.unit=multi-user.target modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm'
RESCUE_LABEL='Rescue shell (no installer)'
QEMU_TEST_LABEL='QEMU serial installer test'
QEMU_TEST_ARGS='blade.test=1 console=tty0 console=ttyS0,115200n8'
QEMU_RESCUE_LABEL='QEMU serial rescue test'

print_plan() {
  local library
  local package

  printf '%s\n' \
    'copy /usr/share/archiso/configs/releng to build/archiso-profile'
  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -z "$package" ]] && continue
    printf 'append live package: %s\n' "$package"
  done <"$LIVE_PACKAGE_LIST"
  printf '%s\n' 'install /usr/local/bin/blade-install mode 0755'
  printf '%s\n' 'install /usr/local/bin/blade-qemu-serial-gate mode 0755'
  for library in common disks identity install preflight; do
    printf 'install /usr/local/lib/blade-installer/%s.sh mode 0755\n' "$library"
  done
  printf '%s\n' \
    'profiledef permission /usr/local/bin/blade-install=0:0:755' \
    'profiledef permission /usr/local/bin/blade-qemu-serial-gate=0:0:755' \
    'profiledef permission /usr/local/lib/blade-installer/common.sh=0:0:755' \
    'enable blade-installer.service, blade-installer-serial.service, and blade-qemu-rescue.service' \
    'embed /usr/share/blade-installer/rootfs.tar.zst' \
    'embed /usr/share/blade-installer/rootfs.tar.zst.sha256' \
    'embed /usr/share/blade-installer/target-packages.txt' \
    'embed /usr/share/blade-installer/build-manifest.txt' \
    "patch UEFI default entry with $SAFE_BOOT_ARGS" \
    "patch GRUB default entry with $SAFE_BOOT_ARGS" \
    "patch Syslinux default entry with $SAFE_BOOT_ARGS" \
    "add $RESCUE_LABEL with blade.noinstaller=1" \
    "add $QEMU_TEST_LABEL with $QEMU_TEST_ARGS" \
    "add $QEMU_RESCUE_LABEL with $QEMU_TEST_ARGS blade.noinstaller=1"
}

require_file() {
  [[ -f "$1" && ! -L "$1" ]] || die "missing or unsafe required file: $1"
}

validate_inputs() {
  local library
  local payload

  [[ -d "$RELENG_PROFILE" && ! -L "$RELENG_PROFILE" ]] ||
    die "missing or unsafe archiso releng profile: $RELENG_PROFILE"
  require_file "$RELENG_PROFILE/profiledef.sh"
  require_file "$RELENG_PROFILE/packages.x86_64"
  [[ -d "$RELENG_PROFILE/airootfs" ]] ||
    die 'releng profile is missing airootfs'
  [[ -d "$RELENG_PROFILE/efiboot/loader/entries" ]] ||
    die 'releng profile is missing UEFI loader entries'
  require_file "$RELENG_PROFILE/efiboot/loader/loader.conf"
  require_file "$RELENG_PROFILE/grub/grub.cfg"
  require_file "$RELENG_PROFILE/grub/loopback.cfg"
  require_file "$RELENG_PROFILE/syslinux/archiso_sys-linux.cfg"
  require_file "$RELENG_PROFILE/syslinux/archiso_pxe-linux.cfg"

  require_file "$LIVE_PACKAGE_LIST"
  [[ -d "$LIVE_OVERLAY" ]] || die "missing live overlay: $LIVE_OVERLAY"
  require_file "$INSTALLER_SOURCE/blade-install"
  require_file "$LIVE_OVERLAY/usr/local/bin/blade-qemu-serial-gate"
  for library in common disks identity install preflight; do
    require_file "$INSTALLER_SOURCE/lib/$library.sh"
  done
  for payload in rootfs.tar.zst rootfs.tar.zst.sha256 \
    target-packages.txt build-manifest.txt; do
    require_file "$PAYLOAD_DIR/$payload"
  done
}

append_safe_args() {
  local file=$1
  local kind=$2
  local temporary

  temporary=$(mktemp "$BUILD_DIR/.task-6-boot.XXXXXX")
  if ! awk -v kind="$kind" -v args="$SAFE_BOOT_ARGS" '
    BEGIN { count = 0 }
    kind == "uefi" && $1 == "options" {
      print $0 " " args
      count++
      next
    }
    kind == "grub" && $1 == "linux" && $0 ~ /\/vmlinuz-linux([[:space:]]|$)/ {
      print $0 " " args
      count++
      next
    }
    kind == "syslinux" && $1 == "APPEND" {
      print $0 " " args
      count++
      next
    }
    { print }
    END { if (count == 0) exit 42 }
  ' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    die "no patchable $kind Linux entry in $file"
    return 1
  fi
  cat -- "$temporary" >"$file"
  rm -f -- "$temporary"
}

append_profile_settings() {
  cat >>"$PROFILE_DIR/profiledef.sh" <<'EOF'

# Blade installer additions. Keep modes explicit so mkarchiso does not inherit
# host checkout permissions.
bootmodes+=('uefi.grub')
file_permissions+=(
  ["/usr/local/bin/blade-install"]="0:0:755"
  ["/usr/local/bin/blade-qemu-serial-gate"]="0:0:755"
  ["/usr/local/lib/blade-installer/common.sh"]="0:0:755"
  ["/usr/local/lib/blade-installer/disks.sh"]="0:0:755"
  ["/usr/local/lib/blade-installer/identity.sh"]="0:0:755"
  ["/usr/local/lib/blade-installer/install.sh"]="0:0:755"
  ["/usr/local/lib/blade-installer/preflight.sh"]="0:0:755"
)
EOF
}

add_uefi_entries() {
  local default_entry
  local entry
  local entries_dir="$PROFILE_DIR/efiboot/loader/entries"
  local -a uefi_entries=()

  mapfile -t uefi_entries < <(grep -l '^options[[:space:]]' "$entries_dir"/*.conf)
  ((${#uefi_entries[@]} > 0)) || die 'no patchable UEFI Linux entries found'
  for entry in "${uefi_entries[@]}"; do
    append_safe_args "$entry" uefi
  done

  default_entry="$entries_dir/01-archiso-linux.conf"
  require_file "$default_entry"
  cp -- "$default_entry" "$entries_dir/90-blade-rescue.conf"
  sed -i 's/^title[[:space:]].*/title    Rescue shell (no installer)/' \
    "$entries_dir/90-blade-rescue.conf"
  sed -i '/^options[[:space:]]/s/$/ blade.noinstaller=1/' \
    "$entries_dir/90-blade-rescue.conf"
  cp -- "$default_entry" "$entries_dir/91-blade-qemu-test.conf"
  sed -i 's/^title[[:space:]].*/title    QEMU serial installer test/' \
    "$entries_dir/91-blade-qemu-test.conf"
  sed -i "/^options[[:space:]]/s|$| $QEMU_TEST_ARGS|" \
    "$entries_dir/91-blade-qemu-test.conf"
  cp -- "$default_entry" "$entries_dir/92-blade-qemu-rescue.conf"
  sed -i 's/^title[[:space:]].*/title    QEMU serial rescue test/' \
    "$entries_dir/92-blade-qemu-rescue.conf"
  sed -i "/^options[[:space:]]/s|$| $QEMU_TEST_ARGS blade.noinstaller=1|" \
    "$entries_dir/92-blade-qemu-rescue.conf"
}

append_grub_entries() {
  local file=$1
  local initrd_line
  local linux_line

  linux_line=$(awk '$1 == "linux" && /\/vmlinuz-linux([[:space:]]|$)/ { print; exit }' "$file")
  initrd_line=$(awk '$1 == "initrd" && /initramfs-linux\.img([[:space:]]|$)/ { print; exit }' "$file")
  [[ -n "$linux_line" && -n "$initrd_line" ]] ||
    die "cannot derive GRUB Linux entry from $file"
  append_safe_args "$file" grub
  linux_line="$linux_line $SAFE_BOOT_ARGS"
  cat >>"$file" <<EOF

menuentry '$RESCUE_LABEL' --id 'blade-rescue' {
$linux_line blade.noinstaller=1
$initrd_line
}

menuentry '$QEMU_TEST_LABEL' --id 'blade-qemu-test' {
$linux_line $QEMU_TEST_ARGS
$initrd_line
}

menuentry '$QEMU_RESCUE_LABEL' --id 'blade-qemu-rescue' {
$linux_line $QEMU_TEST_ARGS blade.noinstaller=1
$initrd_line
}
EOF
}

append_syslinux_entries() {
  local file=$1
  local append_line
  local initrd_line
  local linux_line

  linux_line=$(awk '$1 == "LINUX" { print; exit }' "$file")
  initrd_line=$(awk '$1 == "INITRD" { print; exit }' "$file")
  append_line=$(awk '$1 == "APPEND" { print; exit }' "$file")
  [[ -n "$linux_line" && -n "$initrd_line" && -n "$append_line" ]] ||
    die "cannot derive Syslinux Linux entry from $file"
  append_safe_args "$file" syslinux
  append_line="$append_line $SAFE_BOOT_ARGS"
  cat >>"$file" <<EOF

LABEL blade-rescue
MENU LABEL $RESCUE_LABEL
$linux_line
$initrd_line
$append_line blade.noinstaller=1

LABEL blade-qemu-test
MENU LABEL $QEMU_TEST_LABEL
$linux_line
$initrd_line
$append_line $QEMU_TEST_ARGS

LABEL blade-qemu-rescue
MENU LABEL $QEMU_RESCUE_LABEL
$linux_line
$initrd_line
$append_line $QEMU_TEST_ARGS blade.noinstaller=1
EOF
}

install_profile_contents() {
  local library
  local package
  local -a live_packages=()

  cp -a -- "$LIVE_OVERLAY/." "$AIROOTFS_DIR/"
  install -Dm0755 "$INSTALLER_SOURCE/blade-install" \
    "$AIROOTFS_DIR/usr/local/bin/blade-install"
  install -Dm0755 "$LIVE_OVERLAY/usr/local/bin/blade-qemu-serial-gate" \
    "$AIROOTFS_DIR/usr/local/bin/blade-qemu-serial-gate"
  for library in common disks identity install preflight; do
    install -Dm0755 "$INSTALLER_SOURCE/lib/$library.sh" \
      "$AIROOTFS_DIR/usr/local/lib/blade-installer/$library.sh"
  done
  install -d -m0755 "$AIROOTFS_DIR/usr/share/blade-installer"
  install -m0644 "$PAYLOAD_DIR/rootfs.tar.zst" \
    "$PAYLOAD_DIR/rootfs.tar.zst.sha256" \
    "$PAYLOAD_DIR/target-packages.txt" \
    "$PAYLOAD_DIR/build-manifest.txt" \
    "$AIROOTFS_DIR/usr/share/blade-installer/"

  install -d -m0755 \
    "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
  ln -s ../blade-installer.service \
    "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-installer.service"
  ln -s ../blade-installer-serial.service \
    "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-installer-serial.service"
  ln -s ../blade-qemu-rescue.service \
    "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-qemu-rescue.service"

  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -z "$package" || "$package" == \#* ]] && continue
    [[ "$package" =~ ^[a-z0-9@._+:-]+$ ]] ||
      die "invalid live package: $package"
    live_packages+=("$package")
  done <"$LIVE_PACKAGE_LIST"
  ((${#live_packages[@]} > 0)) || die 'live package list is empty'
  printf '%s\n' "${live_packages[@]}" >>"$PROFILE_DIR/packages.x86_64"
  LC_ALL=C sort -u -o "$PROFILE_DIR/packages.x86_64" \
    "$PROFILE_DIR/packages.x86_64"
}

verify_prepared_profile() {
  local library
  local package

  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -z "$package" || "$package" == \#* ]] && continue
    grep -Fx -- "$package" "$PROFILE_DIR/packages.x86_64" >/dev/null ||
      die "prepared profile is missing live package: $package"
  done <"$LIVE_PACKAGE_LIST"
  [[ -x "$AIROOTFS_DIR/usr/local/bin/blade-install" ]] ||
    die 'prepared installer is not executable'
  [[ -x "$AIROOTFS_DIR/usr/local/bin/blade-qemu-serial-gate" ]] ||
    die 'prepared QEMU serial gate is not executable'
  for library in common disks identity install preflight; do
    [[ -x "$AIROOTFS_DIR/usr/local/lib/blade-installer/$library.sh" ]] ||
      die "prepared installer library is not executable: $library.sh"
    grep -Fq "[\"/usr/local/lib/blade-installer/$library.sh\"]=\"0:0:755\"" \
      "$PROFILE_DIR/profiledef.sh" ||
      die "profiledef lacks explicit mode for $library.sh"
  done
  grep -Fq '["/usr/local/bin/blade-install"]="0:0:755"' \
    "$PROFILE_DIR/profiledef.sh" || die 'profiledef lacks explicit installer mode'
  grep -Fq '["/usr/local/bin/blade-qemu-serial-gate"]="0:0:755"' \
    "$PROFILE_DIR/profiledef.sh" || die 'profiledef lacks explicit QEMU gate mode'
  grep -Fq "bootmodes+=('uefi.grub')" "$PROFILE_DIR/profiledef.sh" ||
    die 'profiledef lacks the GRUB UEFI boot mode'
  [[ -L "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-installer.service" ]] ||
    die 'blade-installer.service is not enabled'
  [[ -L "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-installer-serial.service" ]] ||
    die 'blade-installer-serial.service is not enabled'
  [[ -L "$AIROOTFS_DIR/etc/systemd/system/multi-user.target.wants/blade-qemu-rescue.service" ]] ||
    die 'blade-qemu-rescue.service is not enabled'
  grep -R -Fq "$SAFE_BOOT_ARGS" "$PROFILE_DIR/efiboot/loader/entries" ||
    die 'UEFI entries lack safe boot arguments'
  grep -R -Fq "$SAFE_BOOT_ARGS" "$PROFILE_DIR/grub" ||
    die 'GRUB entries lack safe boot arguments'
  grep -R -Fq "$SAFE_BOOT_ARGS" "$PROFILE_DIR/syslinux" ||
    die 'Syslinux entries lack safe boot arguments'
  grep -R -Fq 'blade.noinstaller=1' "$PROFILE_DIR/efiboot" "$PROFILE_DIR/grub" \
    "$PROFILE_DIR/syslinux" || die 'rescue boot entries are missing'
  grep -R -Fq 'blade.test=1' "$PROFILE_DIR/efiboot" "$PROFILE_DIR/grub" \
    "$PROFILE_DIR/syslinux" || die 'QEMU test boot entries are missing'
  grep -R -Fq "$QEMU_RESCUE_LABEL" "$PROFILE_DIR/efiboot" "$PROFILE_DIR/grub" \
    "$PROFILE_DIR/syslinux" || die 'QEMU rescue boot entries are missing'
}

prepare_profile() {
  validate_inputs
  reset_build_directory "$PROFILE_DIR" >/dev/null
  cp -a -- "$RELENG_PROFILE/." "$PROFILE_DIR/"
  install_profile_contents
  append_profile_settings
  add_uefi_entries
  append_grub_entries "$PROFILE_DIR/grub/grub.cfg"
  append_grub_entries "$PROFILE_DIR/grub/loopback.cfg"
  append_syslinux_entries "$PROFILE_DIR/syslinux/archiso_sys-linux.cfg"
  append_syslinux_entries "$PROFILE_DIR/syslinux/archiso_pxe-linux.cfg"
  verify_prepared_profile
  printf 'archiso profile preparation: PASS\n'
}

main() {
  if is_dry_run || [[ ${1:-} == --dry-run ]]; then
    print_plan
    return 0
  fi
  (($# == 0)) || die 'usage: prepare-archiso.sh [--dry-run]'
  require_privileged_arch
  prepare_profile
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
