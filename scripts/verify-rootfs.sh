#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

ROOTFS_DIR="$BUILD_DIR/rootfs"
PAYLOAD_DIR="$BUILD_DIR/payload"
PAYLOAD_PATH="$PAYLOAD_DIR/rootfs.tar.zst"
PAYLOAD_CHECKSUM="$PAYLOAD_DIR/rootfs.tar.zst.sha256"
PACKAGE_MANIFEST="$PAYLOAD_DIR/target-packages.txt"
BUILD_MANIFEST="$PAYLOAD_DIR/build-manifest.txt"

print_plan() {
  printf '%s\n' \
    "rootfs: $ROOTFS_DIR" \
    'verify every package in packages/target.txt and yay is installed' \
    'verify complete package groups from packages/target.txt' \
    'verify required target overlay and global Codex files' \
    'verify root is locked and no regular user exists' \
    'verify gdm.service is disabled and multi-user.target is default' \
    'verify enabled: NetworkManager switcheroo-control power-profiles-daemon thermald fstrim.timer blade-firstboot-gpu.service' \
    'verify /etc/crypttab is absent' \
    'verify no credentials, auth/session files, SSH host keys, or machine-id' \
    'verify CODEX_HOME is not exported to users' \
    'verify yay --version and codex --version in arch-chroot' \
    "verify codex version contains $CODEX_RELEASE" \
    "verify payload checksum: $PAYLOAD_CHECKSUM" \
    "verify build manifest: $BUILD_MANIFEST"
}

verify_required_files() {
  local path
  local -a required_paths=(
    etc/pacman.conf
    etc/locale.conf
    etc/vconsole.conf
    etc/zram-generator.conf
    etc/modprobe.d/nvidia.conf
    etc/mkinitcpio.conf.d/graphics.conf
    etc/sudoers.d/10-wheel
    etc/systemd/system/blade-firstboot-gpu.service
    usr/local/lib/blade-firstboot/gpu.sh
    usr/local/sbin/blade-firstboot-gpu
    usr/local/bin/codex
    usr/bin/yay
  )

  for path in "${required_paths[@]}"; do
    [[ -e "$ROOTFS_DIR/$path" ]] || die "required target file is missing: /$path"
  done
  [[ -x "$ROOTFS_DIR/usr/local/lib/blade-firstboot/gpu.sh" ]] ||
    die 'GPU gate library is not executable'
  [[ -x "$ROOTFS_DIR/usr/local/sbin/blade-firstboot-gpu" ]] ||
    die 'GPU gate executable is not executable'
  [[ $(stat -c '%a' "$ROOTFS_DIR/etc/sudoers.d/10-wheel") == 440 ]] ||
    die 'wheel sudoers file must have mode 0440'
}

verify_packages() {
  local group_output
  local member
  local package
  local -a group_members
  local -a packages

  mapfile -t packages < <(read_target_packages)
  packages+=(yay)
  for package in "${packages[@]}"; do
    if arch-chroot "$ROOTFS_DIR" pacman -Q "$package" >/dev/null 2>&1; then
      continue
    fi
    if ! group_output=$(arch-chroot "$ROOTFS_DIR" pacman -Sgq "$package" 2>/dev/null); then
      die "missing target package or group: $package"
      return 1
    fi
    mapfile -t group_members <<<"$group_output"
    [[ ${#group_members[@]} -gt 0 && -n ${group_members[0]} ]] ||
      die "empty target package group: $package"
    for member in "${group_members[@]}"; do
      arch-chroot "$ROOTFS_DIR" pacman -Q "$member" >/dev/null 2>&1 ||
        die "missing member of target group $package: $member"
    done
  done
}

verify_services() {
  local service
  local state
  local -a enabled_services=(
    NetworkManager.service
    switcheroo-control.service
    power-profiles-daemon.service
    thermald.service
    fstrim.timer
    blade-firstboot-gpu.service
  )

  for service in "${enabled_services[@]}"; do
    state=$(systemctl --root="$ROOTFS_DIR" is-enabled "$service" 2>/dev/null) ||
      die "required service is not enabled: $service"
    [[ "$state" == enabled ]] || die "unexpected $service state: $state"
  done

  state=$(systemctl --root="$ROOTFS_DIR" is-enabled gdm.service 2>/dev/null || true)
  [[ "$state" == disabled ]] || die "gdm.service must be disabled, got: $state"
  state=$(systemctl --root="$ROOTFS_DIR" get-default)
  [[ "$state" == multi-user.target ]] || die "unexpected default target: $state"
}

verify_accounts_and_credentials() {
  local credential
  local root_hash

  root_hash=$(awk -F: '$1 == "root" {print $2}' "$ROOTFS_DIR/etc/shadow")
  [[ "$root_hash" == '!'* || "$root_hash" == '*'* ]] || die 'root is not locked'
  if awk -F: '$3 >= 1000 && $3 < 65534 {found=1} END {exit found ? 0 : 1}' \
    "$ROOTFS_DIR/etc/passwd"; then
    die 'baked regular user found'
  fi
  if awk -F: '$2 !~ /^[!*]/ {found=1} END {exit found ? 0 : 1}' \
    "$ROOTFS_DIR/etc/shadow"; then
    die 'usable or empty password found in target shadow file'
  fi

  [[ ! -e "$ROOTFS_DIR/etc/crypttab" ]] || die '/etc/crypttab must be absent'
  [[ ! -e "$ROOTFS_DIR/etc/machine-id" ]] || die '/etc/machine-id must be absent'
  [[ ! -e "$ROOTFS_DIR/var/lib/dbus/machine-id" ]] ||
    die '/var/lib/dbus/machine-id must be absent'
  if compgen -G "$ROOTFS_DIR/etc/ssh/ssh_host_*" >/dev/null; then
    die 'SSH host key found'
  fi
  [[ -z $(find "$ROOTFS_DIR/home" -mindepth 1 -print -quit) ]] ||
    die 'baked home-directory content found'

  credential=$(find "$ROOTFS_DIR/opt/codex" "$ROOTFS_DIR/root" "$ROOTFS_DIR/home" \
    -type f \( -iname auth.json -o -iname credentials.json -o \
    -iname 'session*.jsonl' -o -iname history.jsonl -o -iname .netrc \) \
    -print -quit)
  [[ -z "$credential" ]] || die "credential/session file found: $credential"
  if grep -R -E '(^|[[:space:]])(export[[:space:]]+)?CODEX_HOME=' \
    "$ROOTFS_DIR/etc/environment" "$ROOTFS_DIR/etc/profile" \
    "$ROOTFS_DIR/etc/profile.d" "$ROOTFS_DIR/root" "$ROOTFS_DIR/home" \
    >/dev/null 2>&1; then
    die 'CODEX_HOME is exported to installed users'
  fi
}

verify_codex_permissions() {
  local bad_path

  [[ -d "$ROOTFS_DIR/opt/codex" ]] || die '/opt/codex is missing'
  bad_path=$(find "$ROOTFS_DIR/opt/codex" \
    \( ! -user root -o ! -group root \) -print -quit)
  [[ -z "$bad_path" ]] || die "non-root-owned Codex path: $bad_path"
  bad_path=$(find "$ROOTFS_DIR/opt/codex" -type d ! -perm -0005 -print -quit)
  [[ -z "$bad_path" ]] || die "Codex directory is not world-readable/executable: $bad_path"
  [[ -x "$ROOTFS_DIR/usr/local/bin/codex" ]] || die 'global Codex executable is missing'
}

verify_outputs() {
  local manifest_sha

  [[ -s "$PAYLOAD_PATH" ]] || die "missing rootfs payload: $PAYLOAD_PATH"
  [[ -s "$PAYLOAD_CHECKSUM" ]] || die "missing payload checksum: $PAYLOAD_CHECKSUM"
  [[ -s "$PACKAGE_MANIFEST" ]] || die "missing package manifest: $PACKAGE_MANIFEST"
  [[ -s "$BUILD_MANIFEST" ]] || die "missing build manifest: $BUILD_MANIFEST"
  (
    cd "$PAYLOAD_DIR"
    sha256sum --check rootfs.tar.zst.sha256
  )
  manifest_sha=$(awk -F= '$1 == "codex_installer_sha256" {print $2}' "$BUILD_MANIFEST")
  [[ "$manifest_sha" == "$CODEX_INSTALLER_SHA256" ]] ||
    die 'build manifest does not record the pinned Codex installer digest'
  grep -Fx "codex_release=$CODEX_RELEASE" "$BUILD_MANIFEST" >/dev/null ||
    die 'build manifest does not record the pinned Codex release'
  grep -Fx "yay_aur_commit=$YAY_AUR_COMMIT" "$BUILD_MANIFEST" >/dev/null ||
    die 'build manifest does not record the pinned yay commit'
}

main() {
  local codex_version
  local yay_version

  load_build_config
  if is_dry_run; then
    print_plan
    return 0
  fi

  require_privileged_arch
  [[ -d "$ROOTFS_DIR" ]] || die "missing target root: $ROOTFS_DIR"
  verify_required_files
  verify_packages
  verify_services
  verify_accounts_and_credentials
  verify_codex_permissions

  yay_version=$(arch-chroot "$ROOTFS_DIR" yay --version)
  [[ -n "$yay_version" ]] || die 'yay --version returned no output'
  codex_version=$(arch-chroot "$ROOTFS_DIR" codex --version)
  [[ "$codex_version" == *"$CODEX_RELEASE"* ]] ||
    die "unexpected Codex version: $codex_version"
  verify_outputs
  printf 'rootfs verification: PASS\n'
}

main "$@"
