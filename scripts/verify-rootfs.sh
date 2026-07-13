#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

ROOTFS_DIR="$BUILD_DIR/rootfs"
PACKAGE_DIR="$BUILD_DIR/packages"
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
    'verify no NetworkManager, iwd, or wpa_supplicant network secrets' \
    'verify CODEX_HOME is not exported to users' \
    'verify yay --version and codex --version in arch-chroot' \
    "verify codex version contains $CODEX_RELEASE" \
    "verify payload checksum: $PAYLOAD_CHECKSUM" \
    "verify build manifest: $BUILD_MANIFEST"
}

verify_no_network_secrets() {
  local directory
  local secret
  local -a secret_directories=(
    "$ROOTFS_DIR/etc/NetworkManager/system-connections"
    "$ROOTFS_DIR/var/lib/iwd"
    "$ROOTFS_DIR/etc/iwd"
    "$ROOTFS_DIR/etc/wpa_supplicant"
  )

  for directory in "${secret_directories[@]}"; do
    [[ -d "$directory" ]] || continue
    secret=$(find "$directory" -mindepth 1 -print -quit)
    if [[ -n "$secret" ]]; then
      die "network secret/state file found: $secret"
      return 1
    fi
    if [[ $(stat -c '%a' "$directory") != 700 ]]; then
      die "network secret directory must have mode 0700: $directory"
      return 1
    fi
  done

  directory="$ROOTFS_DIR/var/lib/NetworkManager"
  if [[ -d "$directory" ]]; then
    secret=$(find "$directory" -mindepth 1 -maxdepth 1 \
      \( -name 'secret_key*' -o -name 'secret-key*' \) -print -quit)
    if [[ -n "$secret" ]]; then
      die "NetworkManager secret-key state found: $secret"
      return 1
    fi
    if [[ $(stat -c '%a' "$directory") != 700 ]]; then
      die "NetworkManager state directory must have mode 0700: $directory"
      return 1
    fi
  fi
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
    [[ -e "$ROOTFS_DIR/$path" || -L "$ROOTFS_DIR/$path" ]] ||
      die "required target file is missing: /$path"
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

  if ! read_target_packages packages; then
    return 1
  fi
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
  verify_no_network_secrets
}

verify_codex_permissions() {
  local bad_path

  [[ -d "$ROOTFS_DIR/opt/codex" ]] || die '/opt/codex is missing'
  bad_path=$(find "$ROOTFS_DIR/opt/codex" \
    \( ! -user root -o ! -group root \) -print -quit)
  [[ -z "$bad_path" ]] || die "non-root-owned Codex path: $bad_path"
  bad_path=$(find "$ROOTFS_DIR/opt/codex" -type d ! -perm -0005 -print -quit)
  [[ -z "$bad_path" ]] || die "Codex directory is not world-readable/executable: $bad_path"
  arch-chroot "$ROOTFS_DIR" test -x /usr/local/bin/codex ||
    die 'global Codex executable is missing'
}

load_build_manifest() {
  local destination_name=${1-}
  local key
  local line
  local required_key
  local value
  local -a required_keys=(
    project_slug
    codex_release
    codex_installer_url
    codex_installer_sha256
    yay_aur_url
    yay_aur_commit
    yay_package
    yay_package_sha256
    rootfs_sha256
  )

  if [[ ! "$destination_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die 'load_build_manifest requires an associative array variable name'
    return 1
  fi
  local -n destination=$destination_name
  destination=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ ! "$line" =~ ^([a-z0-9_]+)=([^[:space:]]+)$ ]]; then
      die "malformed build manifest line: $line"
      return 1
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    case "$key" in
      project_slug | codex_release | codex_installer_url | \
        codex_installer_sha256 | yay_aur_url | yay_aur_commit | \
        yay_package | yay_package_sha256 | rootfs_sha256) ;;
      *)
        die "unknown build manifest key: $key"
        return 1
        ;;
    esac
    if [[ ${destination[$key]+present} ]]; then
      die "duplicate build manifest key: $key"
      return 1
    fi
    # destination is a nameref to an associative array; $key must expand here.
    # shellcheck disable=SC2004
    destination[$key]=$value
  done <"$BUILD_MANIFEST"

  for required_key in "${required_keys[@]}"; do
    if [[ ! ${destination[$required_key]+present} ]]; then
      die "missing build manifest key: $required_key"
      return 1
    fi
  done

  if [[ ${destination[project_slug]} != "$PROJECT_SLUG" ||
    ${destination[codex_release]} != "$CODEX_RELEASE" ||
    ${destination[codex_installer_url]} != https://chatgpt.com/codex/install.sh ||
    ${destination[codex_installer_sha256]} != "$CODEX_INSTALLER_SHA256" ||
    ${destination[yay_aur_url]} != https://aur.archlinux.org/yay.git ||
    ${destination[yay_aur_commit]} != "$YAY_AUR_COMMIT" ]]; then
    die 'build manifest pinned inputs do not match build configuration'
    return 1
  fi
  if [[ ! ${destination[yay_package]} =~ ^yay-[0-9][a-zA-Z0-9._+-]*\.pkg\.tar\.zst$ ]]; then
    die 'malformed yay package name in build manifest'
    return 1
  fi
  for key in codex_installer_sha256 yay_package_sha256 rootfs_sha256; do
    if [[ ! ${destination[$key]} =~ ^[0-9a-f]{64}$ ]]; then
      die "malformed build manifest digest: $key"
      return 1
    fi
  done
}

verify_package_manifest() {
  local actual_manifest

  mkdir -p "$BUILD_DIR"
  assert_safe_build_child "$BUILD_DIR/.target-packages.verify" >/dev/null
  actual_manifest=$(mktemp "$BUILD_DIR/.target-packages.verify.XXXXXX")
  if ! LC_ALL=C arch-chroot "$ROOTFS_DIR" pacman -Q | LC_ALL=C sort >"$actual_manifest"; then
    rm -f "$actual_manifest"
    die 'failed to generate fresh target package manifest'
    return 1
  fi
  if ! cmp -s -- "$actual_manifest" "$PACKAGE_MANIFEST"; then
    rm -f "$actual_manifest"
    die 'target-packages.txt does not match fresh pacman -Q output'
    return 1
  fi
  rm -f "$actual_manifest"
}

verify_outputs() {
  local actual_sha
  local yay_path
  local -A manifest=()

  [[ -s "$PAYLOAD_PATH" ]] || die "missing rootfs payload: $PAYLOAD_PATH"
  [[ -s "$PAYLOAD_CHECKSUM" ]] || die "missing payload checksum: $PAYLOAD_CHECKSUM"
  [[ -s "$PACKAGE_MANIFEST" ]] || die "missing package manifest: $PACKAGE_MANIFEST"
  [[ -s "$BUILD_MANIFEST" ]] || die "missing build manifest: $BUILD_MANIFEST"
  (
    cd "$PAYLOAD_DIR"
    sha256sum --check rootfs.tar.zst.sha256
  )
  load_build_manifest manifest || return
  verify_package_manifest || return

  actual_sha=$(sha256sum "$PAYLOAD_PATH" | awk '{print $1}')
  if [[ "$actual_sha" != "${manifest[rootfs_sha256]}" ]]; then
    die 'rootfs payload digest does not match build manifest'
    return 1
  fi

  yay_path="$PACKAGE_DIR/${manifest[yay_package]}"
  if [[ ! -e "$yay_path" && ! -L "$yay_path" ]]; then
    die "local yay artifact is missing: $yay_path"
    return 1
  fi
  if [[ ! -f "$yay_path" || -L "$yay_path" ]]; then
    die "local yay artifact is not a regular file: $yay_path"
    return 1
  fi
  actual_sha=$(sha256sum "$yay_path" | awk '{print $1}')
  if [[ "$actual_sha" != "${manifest[yay_package_sha256]}" ]]; then
    die 'local yay package digest does not match build manifest'
    return 1
  fi
}

main() {
  local codex_version
  local yay_version
  # shellcheck disable=SC2034
  local -a target_packages

  load_build_config
  if ! read_target_packages target_packages; then
    return 1
  fi
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
