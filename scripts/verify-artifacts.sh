#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/build-common.sh disable=SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

DIST_DIR="$REPO_ROOT/dist"
VERIFY_DIR="$BUILD_DIR/artifact-verify"
ISO_TREE="$VERIFY_DIR/iso"
INNER_ROOT="$VERIFY_DIR/airootfs"
SAFE_BOOT_ARGS='systemd.unit=multi-user.target modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm'

print_plan() {
  printf '%s\n' \
    'verify ISO SHA-256 sidecar' \
    'verify hybrid BIOS and UEFI boot structures' \
    'extract the airootfs image from the ISO' \
    'run unsquashfs into build/artifact-verify/airootfs' \
    'verify inner /usr/local/bin/blade-install mode 0755' \
    'verify inner /usr/share/blade-installer/rootfs.tar.zst' \
    'verify inner payload checksum and manifests' \
    'verify inner blade-installer.service and serial test service' \
    'verify active UEFI GRUB and BIOS Syslinux boot stanzas' \
    'verify rescue and QEMU-only test entries'
}

cleanup_verify_dir() {
  if [[ -d "$VERIFY_DIR" && ! -L "$VERIFY_DIR" ]]; then
    clear_build_directory "$VERIFY_DIR" >/dev/null || true
    rmdir -- "$VERIFY_DIR" 2>/dev/null || true
  fi
}

verify_iso_sidecar() {
  local iso=$1
  local actual
  local expected
  local recorded_name
  local -a lines=()

  [[ -f "$iso" && ! -L "$iso" ]] || die 'selected ISO is missing or unsafe'
  [[ -f "$iso.sha256" && ! -L "$iso.sha256" ]] ||
    die 'ISO checksum sidecar is missing or unsafe'
  mapfile -t lines < <(sed '/^[[:space:]]*$/d' "$iso.sha256")
  ((${#lines[@]} == 1)) || die 'ISO checksum sidecar must contain one entry'
  [[ ${lines[0]} =~ ^([0-9a-f]{64})[[:space:]][\ \*](.+)$ ]] ||
    die 'ISO checksum sidecar has an invalid format'
  expected=${BASH_REMATCH[1]}
  recorded_name=${BASH_REMATCH[2]}
  [[ "$recorded_name" == "${iso##*/}" ]] ||
    die 'ISO checksum sidecar names a different artifact'
  actual=$(sha256sum "$iso")
  actual=${actual%% *}
  [[ "$actual" == "$expected" ]] || die 'ISO checksum does not match'
}

verify_payload_sidecar() {
  local payload_dir="$INNER_ROOT/usr/share/blade-installer"
  local actual
  local expected
  local manifest_digest
  local line
  local -a lines=()
  local -a manifest_lines=()

  mapfile -t lines < <(sed '/^[[:space:]]*$/d' "$payload_dir/rootfs.tar.zst.sha256")
  ((${#lines[@]} == 1)) || die 'inner payload checksum must contain one entry'
  line=${lines[0]}
  [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][\ \*]rootfs\.tar\.zst$ ]] ||
    die 'inner payload checksum has an invalid format or filename'
  expected=${BASH_REMATCH[1]}
  actual=$(sha256sum "$payload_dir/rootfs.tar.zst")
  actual=${actual%% *}
  [[ "$actual" == "$expected" ]] || die 'inner payload checksum does not match'
  mapfile -t manifest_lines < <(
    grep '^rootfs_sha256=' "$payload_dir/build-manifest.txt"
  )
  ((${#manifest_lines[@]} == 1)) ||
    die 'inner build manifest must contain one rootfs_sha256 key'
  manifest_digest=${manifest_lines[0]#rootfs_sha256=}
  [[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] ||
    die 'inner build manifest rootfs_sha256 is malformed'
  [[ "$manifest_digest" == "$expected" ]] ||
    die 'inner build manifest digest does not match the payload'
}

verify_boot_file_lines() {
  local file=$1
  local family=$2
  local kind=$3

  awk -v args="$SAFE_BOOT_ARGS" -v kind="$kind" '
    kind == "uefi" && $1 == "options" { count++; if (index($0, args) == 0) exit 42 }
    kind == "grub" && $1 == "linux" && /\/vmlinuz-linux([[:space:]]|$)/ {
      count++
      if (index($0, args) == 0) exit 42
    }
    kind == "syslinux" && $1 == "APPEND" { count++; if (index($0, args) == 0) exit 42 }
    END { if (count == 0) exit 43 }
  ' "$file" || die "$family artifact has an unsafe or missing Linux boot entry: $file"
}

verify_boot_entries() {
  local file
  local -a grub_files=()
  local -a syslinux_files=()

  mapfile -d '' -t grub_files < <(
    find "$ISO_TREE" -type f \( -name grub.cfg -o -name loopback.cfg \) -print0
  )
  ((${#grub_files[@]} >= 2)) || die 'ISO lacks active UEFI GRUB configurations'
  for file in "${grub_files[@]}"; do
    verify_boot_file_lines "$file" 'UEFI GRUB' grub
  done

  mapfile -d '' -t syslinux_files < <(
    find "$ISO_TREE" -type f \( -name archiso_sys-linux.cfg -o \
      -name archiso_pxe-linux.cfg \) -print0
  )
  ((${#syslinux_files[@]} >= 2)) || die 'ISO lacks generated Syslinux configurations'
  for file in "${syslinux_files[@]}"; do
    verify_boot_file_lines "$file" Syslinux syslinux
  done

  grep -R -Fq 'Rescue shell (no installer)' "$ISO_TREE" ||
    die 'ISO lacks the rescue boot label'
  grep -R -Fq 'blade.noinstaller=1' "$ISO_TREE" ||
    die 'ISO rescue entry lacks blade.noinstaller=1'
  grep -R -Fq 'QEMU serial installer test' "$ISO_TREE" ||
    die 'ISO lacks the QEMU test label'
  grep -R -Fq 'blade.test=1' "$ISO_TREE" ||
    die 'ISO QEMU test entry lacks blade.test=1'
}

verify_inner_root() {
  local library
  local payload_dir="$INNER_ROOT/usr/share/blade-installer"

  [[ -f "$INNER_ROOT/usr/local/bin/blade-install" &&
    $(stat -c '%a' "$INNER_ROOT/usr/local/bin/blade-install") == 755 ]] ||
    die 'inner installer is missing or not mode 0755'
  for library in common disks identity install preflight; do
    [[ -f "$INNER_ROOT/usr/local/lib/blade-installer/$library.sh" &&
      $(stat -c '%a' "$INNER_ROOT/usr/local/lib/blade-installer/$library.sh") == 755 ]] ||
      die "inner installer library is missing or not mode 0755: $library.sh"
  done
  for artifact in rootfs.tar.zst rootfs.tar.zst.sha256 target-packages.txt \
    build-manifest.txt; do
    [[ -f "$payload_dir/$artifact" && ! -L "$payload_dir/$artifact" ]] ||
      die "inner payload artifact is missing or unsafe: $artifact"
  done
  verify_payload_sidecar
  cmp -s "$payload_dir/target-packages.txt" "$DIST_DIR/target-packages.txt" ||
    die 'published package manifest differs from the inner manifest'
  cmp -s "$payload_dir/build-manifest.txt" "$DIST_DIR/build-manifest.txt" ||
    die 'published build manifest differs from the inner manifest'
  [[ -f "$INNER_ROOT/etc/systemd/system/blade-installer.service" ]] ||
    die 'inner physical installer service is missing'
  [[ -f "$INNER_ROOT/etc/systemd/system/blade-installer-serial.service" ]] ||
    die 'inner serial test service is missing'
  [[ -f "$INNER_ROOT/etc/systemd/system/blade-qemu-rescue.service" ]] ||
    die 'inner serial rescue service is missing'
  [[ -f "$INNER_ROOT/usr/local/bin/blade-qemu-serial-gate" &&
    $(stat -c '%a' "$INNER_ROOT/usr/local/bin/blade-qemu-serial-gate") == 755 ]] ||
    die 'inner QEMU serial gate is missing or not mode 0755'
  [[ -L "$INNER_ROOT/etc/systemd/system/multi-user.target.wants/blade-installer.service" ]] ||
    die 'inner physical installer service is not enabled'
  [[ -L "$INNER_ROOT/etc/systemd/system/multi-user.target.wants/blade-installer-serial.service" ]] ||
    die 'inner serial test service is not enabled'
  [[ -L "$INNER_ROOT/etc/systemd/system/multi-user.target.wants/blade-qemu-rescue.service" ]] ||
    die 'inner serial rescue service is not enabled'
  grep -Fq 'TTYPath=/dev/tty1' \
    "$INNER_ROOT/etc/systemd/system/blade-installer.service" ||
    die 'physical installer service no longer uses tty1'
  grep -Fq 'blade.test=1' \
    "$INNER_ROOT/etc/systemd/system/blade-installer-serial.service" ||
    die 'serial test service is not conditioned on blade.test=1'
  grep -Fq 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' \
    "$INNER_ROOT/etc/systemd/system/blade-installer-serial.service" ||
    die 'serial test service lacks the QEMU DMI gate'
  grep -Fq 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' \
    "$INNER_ROOT/etc/systemd/system/blade-qemu-rescue.service" ||
    die 'serial rescue service lacks the QEMU DMI gate'
}

verify_artifacts() {
  local airootfs_image
  local el_torito
  local iso
  local system_area
  local -a airootfs_images=()
  local -a isos=()

  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] ||
    die "missing or unsafe distribution directory: $DIST_DIR"
  mapfile -d '' -t isos < <(
    find "$DIST_DIR" -maxdepth 1 -type f \
      -name 'blade15-arch-gnome-[0-9]*-[0-9a-f]*.iso' -print0
  )
  ((${#isos[@]} == 1)) ||
    die "expected exactly one release ISO; found ${#isos[@]}"
  iso=${isos[0]}
  verify_iso_sidecar "$iso"

  el_torito=$(xorriso -indev "$iso" -report_el_torito plain 2>&1)
  grep -Fq 'BIOS' <<<"$el_torito" || die 'ISO lacks a BIOS El Torito image'
  grep -Fq 'UEFI' <<<"$el_torito" || die 'ISO lacks a UEFI El Torito image'
  system_area=$(xorriso -indev "$iso" -report_system_area plain 2>&1)
  grep -Eiq 'isohybrid|protective msdos|mbr partition' <<<"$system_area" ||
    die 'ISO lacks a hybrid system area'

  reset_build_directory "$VERIFY_DIR" >/dev/null
  trap cleanup_verify_dir EXIT
  mkdir -p -- "$ISO_TREE"
  xorriso -osirrox on -indev "$iso" -extract / "$ISO_TREE" >/dev/null 2>&1
  mapfile -d '' -t airootfs_images < <(
    find "$ISO_TREE" -type f -name airootfs.sfs -print0
  )
  ((${#airootfs_images[@]} == 1)) ||
    die "expected exactly one inner airootfs image; found ${#airootfs_images[@]}"
  airootfs_image=${airootfs_images[0]}
  unsquashfs -no-progress -d "$INNER_ROOT" "$airootfs_image" >/dev/null

  verify_inner_root
  verify_boot_entries
  cleanup_verify_dir
  trap - EXIT
  printf 'artifact verification: PASS\n'
}

main() {
  if is_dry_run || [[ ${1:-} == --dry-run ]]; then
    print_plan
    return 0
  fi
  (($# == 0)) || die 'usage: verify-artifacts.sh [--dry-run]'
  for command_name in xorriso unsquashfs sha256sum; do
    command -v "$command_name" >/dev/null || die "$command_name is required"
  done
  verify_artifacts
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
