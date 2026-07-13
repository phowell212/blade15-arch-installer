#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/build-common.sh disable=SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

DIST_DIR="$REPO_ROOT/dist"
VERIFY_DIR="$BUILD_DIR/artifact-verify"
ISO_TREE="$VERIFY_DIR/iso"
INNER_ROOT="$VERIFY_DIR/airootfs"
SAFE_UNIT_ARG='systemd.unit=multi-user.target'
SAFE_BLACKLIST_ARG='modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm'
OFFLINE_TIME_MASK_ARG='systemd.mask=systemd-time-wait-sync.service'
PHYSICAL_TTY_MASK_ARG='systemd.mask=getty@tty1.service'
QEMU_SERIAL_GETTY_MASK_ARG='systemd.mask=serial-getty@ttyS0.service'
RESCUE_LABEL='Rescue shell (no installer)'
QEMU_TEST_LABEL='QEMU serial installer test'
QEMU_RESCUE_LABEL='QEMU serial rescue test'
TEST_ARG='blade.test=1'
TTY_CONSOLE_ARG='console=tty0'
SERIAL_CONSOLE_ARG='console=ttyS0,115200n8'

print_plan() {
  printf '%s\n' \
    'verify ISO SHA-256 sidecar' \
    'verify hybrid BIOS and UEFI boot structures' \
    'extract the airootfs image from the ISO' \
    'run unsquashfs into build/artifact-verify/airootfs' \
    'verify inner /usr/local/bin/blade-install mode 0755' \
    'verify inner /usr/share/blade-installer/build.env mode 0644 and required values' \
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

config_assignment_value() {
  local file=$1
  local variable=$2
  local -a assignments=()

  mapfile -t assignments < <(grep -E "^${variable}=" "$file" || true)
  ((${#assignments[@]} == 1)) || return 1
  printf '%s\n' "${assignments[0]#*=}"
}

verify_runtime_config() (
  local config="$INNER_ROOT/usr/share/blade-installer/build.env"
  local actual
  local expected
  local variable
  local -a required_variables=(
    TARGET_DMI_VENDOR
    TARGET_DMI_FAMILY
    DEFAULT_HOSTNAME
    DEFAULT_TIMEZONE
  )

  [[ -f "$config" && ! -L "$config" ]] || {
    die 'inner runtime configuration is missing or unsafe'
    return
  }
  [[ $(stat -c '%a' "$config") == 644 ]] || {
    die 'inner runtime configuration is not mode 0644'
    return
  }
  [[ -f "$BUILD_CONFIG" && ! -L "$BUILD_CONFIG" ]] || {
    die 'source build configuration is missing or unsafe'
    return
  }
  cmp -s "$BUILD_CONFIG" "$config" || {
    die 'inner runtime configuration differs from the source build configuration'
    return
  }

  for variable in "${required_variables[@]}"; do
    if ! actual=$(config_assignment_value "$config" "$variable") ||
      [[ -z "$actual" ]]; then
      die "inner runtime configuration lacks required value: $variable"
      return
    fi
    if ! expected=$(config_assignment_value "$BUILD_CONFIG" "$variable") ||
      [[ -z "$expected" ]]; then
      die "source build configuration lacks required value: $variable"
      return
    fi
    [[ "$actual" == "$expected" ]] || {
      die "inner runtime configuration has unexpected value: $variable"
      return
    }
  done
)

extract_grub_stanza() {
  local file=$1
  local marker=$2

  awk -v marker="$marker" '
    /^menuentry[[:space:]]/ {
      active = index($0, marker) > 0
      if (active) found++
    }
    active && $0 !~ /^[[:space:]]*#/ { print }
    active && /^}/ { active = 0 }
    END { if (found != 1 || active) exit 42 }
  ' "$file"
}

extract_grub_kernel_args() {
  local block=$1

  awk '
    $1 == "linux" && $2 ~ /\/vmlinuz-linux$/ {
      count++
      line = ""
      for (field = 3; field <= NF; field++) {
        line = line (line == "" ? "" : " ") $field
      }
      print line
    }
    END { if (count != 1) exit 42 }
  ' <<<"$block"
}

extract_syslinux_stanza() {
  local file=$1
  local target_label=$2

  awk -v target="$target_label" '
    $1 == "LABEL" {
      active = ($2 == target)
      if (active) found++
    }
    active && $0 !~ /^[[:space:]]*#/ { print }
    END { if (found != 1) exit 42 }
  ' "$file"
}

extract_syslinux_kernel_args() {
  local block=$1

  awk '
    $1 == "LINUX" && $2 ~ /\/vmlinuz-linux$/ { linux_count++ }
    $1 == "APPEND" {
      append_count++
      line = ""
      for (field = 2; field <= NF; field++) {
        line = line (line == "" ? "" : " ") $field
      }
      print line
    }
    END { if (linux_count != 1 || append_count != 1) exit 42 }
  ' <<<"$block"
}

require_stanza_values() {
  local block=$1
  local description=$2
  shift 2
  local required

  for required in "$@"; do
    if [[ "$block" != *"$required"* ]]; then
      die "$description lacks required value: $required"
      return
    fi
  done
}

kernel_token_count() {
  local arguments=$1
  local expected=$2
  local count=0
  local token
  local -a tokens=()

  read -r -a tokens <<<"$arguments"
  for token in "${tokens[@]}"; do
    [[ "$token" == "$expected" ]] && ((count += 1))
  done
  printf '%d\n' "$count"
}

require_kernel_token() {
  local arguments=$1
  local expected=$2
  local description=$3
  local count

  count=$(kernel_token_count "$arguments" "$expected")
  [[ "$count" -eq 1 ]] ||
    die "$description must contain exactly one kernel token: $expected"
}

forbid_kernel_token() {
  local arguments=$1
  local forbidden=$2
  local description=$3
  local count

  count=$(kernel_token_count "$arguments" "$forbidden")
  [[ "$count" -eq 0 ]] || die "$description contains forbidden kernel token: $forbidden"
}

forbid_kernel_token_near_match() {
  local arguments=$1
  local expected=$2
  local description=$3
  local token
  local -a tokens=()

  read -r -a tokens <<<"$arguments"
  for token in "${tokens[@]}"; do
    if [[ "$token" != "$expected" && "$token" == *"$expected"* ]]; then
      die "$description contains a near-match kernel token for $expected: $token"
      return
    fi
  done
}

validate_route_kernel_args() {
  local arguments=$1
  local route=$2
  local description=$3

  forbid_kernel_token_near_match "$arguments" "$OFFLINE_TIME_MASK_ARG" \
    "$description" || return
  forbid_kernel_token_near_match "$arguments" "$PHYSICAL_TTY_MASK_ARG" \
    "$description" || return
  forbid_kernel_token_near_match "$arguments" "$QEMU_SERIAL_GETTY_MASK_ARG" \
    "$description" || return
  require_kernel_token "$arguments" "$SAFE_UNIT_ARG" "$description" || return
  require_kernel_token "$arguments" "$SAFE_BLACKLIST_ARG" "$description" || return
  require_kernel_token "$arguments" "$OFFLINE_TIME_MASK_ARG" "$description" || return

  case "$route" in
    normal)
      require_kernel_token "$arguments" "$PHYSICAL_TTY_MASK_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$QEMU_SERIAL_GETTY_MASK_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$TEST_ARG" "$description" || return
      forbid_kernel_token "$arguments" 'blade.noinstaller=1' "$description" || return
      forbid_kernel_token "$arguments" "$TTY_CONSOLE_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$SERIAL_CONSOLE_ARG" "$description" || return
      ;;
    rescue)
      forbid_kernel_token "$arguments" "$PHYSICAL_TTY_MASK_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$QEMU_SERIAL_GETTY_MASK_ARG" "$description" || return
      require_kernel_token "$arguments" 'blade.noinstaller=1' "$description" || return
      forbid_kernel_token "$arguments" "$TEST_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$TTY_CONSOLE_ARG" "$description" || return
      forbid_kernel_token "$arguments" "$SERIAL_CONSOLE_ARG" "$description" || return
      ;;
    qemu-installer)
      forbid_kernel_token "$arguments" "$PHYSICAL_TTY_MASK_ARG" "$description" || return
      require_kernel_token "$arguments" "$QEMU_SERIAL_GETTY_MASK_ARG" "$description" || return
      require_kernel_token "$arguments" "$TEST_ARG" "$description" || return
      require_kernel_token "$arguments" "$TTY_CONSOLE_ARG" "$description" || return
      require_kernel_token "$arguments" "$SERIAL_CONSOLE_ARG" "$description" || return
      forbid_kernel_token "$arguments" 'blade.noinstaller=1' "$description" || return
      ;;
    qemu-rescue)
      forbid_kernel_token "$arguments" "$PHYSICAL_TTY_MASK_ARG" "$description" || return
      require_kernel_token "$arguments" "$QEMU_SERIAL_GETTY_MASK_ARG" "$description" || return
      require_kernel_token "$arguments" "$TEST_ARG" "$description" || return
      require_kernel_token "$arguments" "$TTY_CONSOLE_ARG" "$description" || return
      require_kernel_token "$arguments" "$SERIAL_CONSOLE_ARG" "$description" || return
      require_kernel_token "$arguments" 'blade.noinstaller=1' "$description" || return
      ;;
    *) die "unknown boot route: $route" || return ;;
  esac
}

verify_grub_block_route() {
  local block=$1
  local route=$2
  local description=$3
  local arguments

  arguments=$(extract_grub_kernel_args "$block") || {
    die "$description must contain exactly one active GRUB linux line"
    return
  }
  validate_route_kernel_args "$arguments" "$route" "$description"
}

verify_grub_normal_routes() {
  local file=$1
  local arguments
  local -a normal_arguments=()

  mapfile -t normal_arguments < <(
    awk '
      /^menuentry[[:space:]]/ { custom = index($0, "--id '\''blade-") > 0 }
      !custom && $1 == "linux" && $2 ~ /\/vmlinuz-linux$/ {
        line = ""
        for (field = 3; field <= NF; field++) {
          line = line (line == "" ? "" : " ") $field
        }
        print line
      }
    ' "$file"
  )
  ((${#normal_arguments[@]} > 0)) || {
    die "UEFI GRUB has no normal Linux route: $file"
    return
  }
  for arguments in "${normal_arguments[@]}"; do
    validate_route_kernel_args "$arguments" normal 'UEFI GRUB normal route' || return
  done
}

verify_grub_stanzas() {
  local file=$1
  local block

  verify_grub_normal_routes "$file" || return
  block=$(extract_grub_stanza "$file" "--id 'archlinux'") ||
    die "UEFI GRUB default stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'UEFI GRUB default stanza' \
    'Arch Linux install medium' || return
  verify_grub_block_route "$block" normal 'UEFI GRUB default stanza' || return
  block=$(extract_grub_stanza "$file" "--id 'blade-rescue'") ||
    die "UEFI GRUB rescue stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'UEFI GRUB rescue stanza' \
    "menuentry '$RESCUE_LABEL'" || return
  verify_grub_block_route "$block" rescue 'UEFI GRUB rescue stanza' || return
  block=$(extract_grub_stanza "$file" "--id 'blade-qemu-test'") ||
    die "UEFI GRUB QEMU test stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'UEFI GRUB QEMU test stanza' \
    "menuentry '$QEMU_TEST_LABEL'" || return
  verify_grub_block_route "$block" qemu-installer 'UEFI GRUB QEMU test stanza' || return
  block=$(extract_grub_stanza "$file" "--id 'blade-qemu-rescue'") ||
    die "UEFI GRUB QEMU rescue stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'UEFI GRUB QEMU rescue stanza' \
    "menuentry '$QEMU_RESCUE_LABEL'" || return
  verify_grub_block_route "$block" qemu-rescue 'UEFI GRUB QEMU rescue stanza' || return
}

verify_syslinux_normal_routes() {
  local file=$1
  local arguments
  local block
  local label
  local -a labels=()

  mapfile -t labels < <(
    awk '$1 == "LABEL" && $2 !~ /^blade-/ { print $2 }' "$file"
  )
  ((${#labels[@]} > 0)) || {
    die "BIOS Syslinux has no normal route: $file"
    return
  }
  for label in "${labels[@]}"; do
    block=$(extract_syslinux_stanza "$file" "$label") || {
      die "BIOS Syslinux normal stanza is missing or duplicated: $label"
      return
    }
    arguments=$(extract_syslinux_kernel_args "$block") || {
      die "BIOS Syslinux normal stanza lacks one active APPEND line: $label"
      return
    }
    validate_route_kernel_args "$arguments" normal \
      "BIOS Syslinux normal stanza $label" || return
  done
}

verify_syslinux_block_route() {
  local block=$1
  local route=$2
  local description=$3
  local arguments

  arguments=$(extract_syslinux_kernel_args "$block") || {
    die "$description must contain one active LINUX and APPEND line"
    return
  }
  validate_route_kernel_args "$arguments" "$route" "$description"
}

verify_syslinux_stanzas() {
  local file=$1
  local block

  verify_syslinux_normal_routes "$file" || return
  block=$(extract_syslinux_stanza "$file" blade-rescue) ||
    die "BIOS Syslinux rescue stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'BIOS Syslinux rescue stanza' \
    "MENU LABEL $RESCUE_LABEL" || return
  verify_syslinux_block_route "$block" rescue 'BIOS Syslinux rescue stanza' || return
  block=$(extract_syslinux_stanza "$file" blade-qemu-test) ||
    die "BIOS Syslinux QEMU test stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'BIOS Syslinux QEMU test stanza' \
    "MENU LABEL $QEMU_TEST_LABEL" || return
  verify_syslinux_block_route "$block" qemu-installer \
    'BIOS Syslinux QEMU test stanza' || return
  block=$(extract_syslinux_stanza "$file" blade-qemu-rescue) ||
    die "BIOS Syslinux QEMU rescue stanza is missing or duplicated: $file"
  require_stanza_values "$block" 'BIOS Syslinux QEMU rescue stanza' \
    "MENU LABEL $QEMU_RESCUE_LABEL" || return
  verify_syslinux_block_route "$block" qemu-rescue \
    'BIOS Syslinux QEMU rescue stanza' || return
}

verify_boot_entries() {
  local file
  local -a grub_files=()
  local -a syslinux_files=()

  mapfile -d '' -t grub_files < <(
    find "$ISO_TREE" -type f \( -name grub.cfg -o -name loopback.cfg \) -print0
  )
  ((${#grub_files[@]} >= 2)) || {
    die 'ISO lacks active UEFI GRUB configurations'
    return
  }
  for file in "${grub_files[@]}"; do
    verify_grub_stanzas "$file" || return
  done

  mapfile -d '' -t syslinux_files < <(
    find "$ISO_TREE" -type f \( -name archiso_sys-linux.cfg -o \
      -name archiso_pxe-linux.cfg \) -print0
  )
  ((${#syslinux_files[@]} >= 2)) || {
    die 'ISO lacks generated Syslinux configurations'
    return
  }
  for file in "${syslinux_files[@]}"; do
    verify_syslinux_stanzas "$file" || return
  done
}

require_unit_line() {
  local unit=$1
  local required=$2
  local count

  count=$(grep -Fxc -- "$required" "$unit" || true)
  [[ "$count" -eq 1 ]] ||
    die "service unit must contain one exact active line '$required': $unit"
}

require_only_unit_directive() {
  local unit=$1
  local directive=$2
  local required=$3
  local -a active=()

  mapfile -t active < <(
    grep -E "^[[:space:]]*${directive}[[:space:]]*=" "$unit" || true
  )
  [[ "${#active[@]}" -eq 1 && "${active[0]}" == "$required" ]] ||
    die "service unit must contain only exact active directive '$required': $unit"
}

reject_unit_dropins() {
  local service=$1
  local root
  local dropin
  local prefix=${service%.*}
  local unit_type=${service##*.}
  local -a dropin_names=("$service.d" "$unit_type.d")

  while [[ "$prefix" == *-* ]]; do
    prefix=${prefix%-*}
    dropin_names+=("$prefix-.$unit_type.d")
  done

  for root in etc run usr/local/lib usr/lib; do
    for dropin in "${dropin_names[@]}"; do
      dropin="$INNER_ROOT/$root/systemd/system/$dropin"
      [[ ! -e "$dropin" && ! -L "$dropin" ]] || {
        die "inner route service must not have applicable drop-ins: $dropin"
        return
      }
    done
  done
}

require_enabled_service() {
  local service=$1
  local system_dir="$INNER_ROOT/etc/systemd/system"
  local link="$system_dir/multi-user.target.wants/$service"
  local target

  [[ -f "$system_dir/$service" && ! -L "$system_dir/$service" ]] || {
    die "inner service unit is missing or unsafe: $service"
    return
  }
  [[ -L "$link" ]] || {
    die "inner service is not enabled: $service"
    return
  }
  target=$(readlink "$link")
  [[ "$target" == "../$service" ]] ||
    die "inner service enablement has the wrong target: $service -> $target"
}

verify_service_units() {
  local system_dir="$INNER_ROOT/etc/systemd/system"
  local physical="$system_dir/blade-installer.service"
  local rescue="$system_dir/blade-qemu-rescue.service"
  local serial="$system_dir/blade-installer-serial.service"

  require_enabled_service blade-installer.service || return
  require_enabled_service blade-installer-serial.service || return
  require_enabled_service blade-qemu-rescue.service || return
  reject_unit_dropins blade-installer.service || return
  reject_unit_dropins blade-installer-serial.service || return
  reject_unit_dropins blade-qemu-rescue.service || return

  require_unit_line "$physical" 'ConditionKernelCommandLine=!blade.noinstaller=1' || return
  require_unit_line "$physical" 'ConditionKernelCommandLine=!blade.test=1' || return
  require_only_unit_directive "$physical" Conflicts \
    'Conflicts=getty@tty1.service' || return
  require_unit_line "$physical" 'ExecStart=/usr/local/bin/blade-install' || return
  require_unit_line "$physical" 'TTYPath=/dev/tty1' || return

  require_unit_line "$serial" 'ConditionKernelCommandLine=blade.test=1' || return
  require_unit_line "$serial" 'ConditionKernelCommandLine=!blade.noinstaller=1' || return
  require_only_unit_directive "$serial" Conflicts \
    'Conflicts=serial-getty@ttyS0.service' || return
  require_unit_line "$serial" 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' || return
  require_unit_line "$serial" 'ExecStart=/usr/local/bin/blade-install' || return
  require_unit_line "$serial" 'TTYPath=/dev/ttyS0' || return

  require_unit_line "$rescue" 'ConditionKernelCommandLine=blade.test=1' || return
  require_unit_line "$rescue" 'ConditionKernelCommandLine=blade.noinstaller=1' || return
  require_only_unit_directive "$rescue" Conflicts \
    'Conflicts=serial-getty@ttyS0.service' || return
  require_unit_line "$rescue" 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' || return
  require_unit_line "$rescue" \
    'ExecStart=-/usr/bin/agetty --autologin root --noclear 115200 ttyS0 vt100' || return
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
  verify_runtime_config
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
  [[ -f "$INNER_ROOT/usr/local/bin/blade-qemu-serial-gate" &&
    $(stat -c '%a' "$INNER_ROOT/usr/local/bin/blade-qemu-serial-gate") == 755 ]] ||
    die 'inner QEMU serial gate is missing or not mode 0755'
  verify_service_units
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
