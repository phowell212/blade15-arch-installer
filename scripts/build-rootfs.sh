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
CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh
CODEX_INSTALLER="$BUILD_DIR/codex-install.sh"
CODEX_INSTALLER_CHROOT=/root/codex-install.sh
CODEX_INSTALLER_ACTUAL_SHA=

print_plan() {
  printf '%s\n' \
    "fixed build root: $BUILD_DIR" \
    "fresh target root: $ROOTFS_DIR" \
    "yay source pinned at $YAY_AUR_COMMIT" \
    "multilib enabled by $TARGET_PACMAN_CONFIG: [multilib]" \
    "pacstrap -C $TARGET_PACMAN_CONFIG -K $ROOTFS_DIR official target packages from packages/target.txt" \
    "after official pacstrap: pacman --root $ROOTFS_DIR --noconfirm --upgrade $PACKAGE_DIR/yay-*.pkg.tar.zst" \
    "copy target overlay: $TARGET_OVERLAY" \
    "download $CODEX_INSTALLER_URL" \
    "verify downloaded installer SHA-256 before execution: $CODEX_INSTALLER_SHA256" \
    "arch-chroot $ROOTFS_DIR /usr/bin/env CODEX_HOME=/opt/codex CODEX_INSTALL_DIR=/usr/local/bin CODEX_NON_INTERACTIVE=1 CODEX_RELEASE=$CODEX_RELEASE /bin/sh $CODEX_INSTALLER_CHROOT" \
    'record codex_installer_sha256= in build-manifest.txt' \
    "remove $CODEX_INSTALLER_CHROOT immediately after installer execution" \
    'verify no Codex auth/session files' \
    'verify CODEX_HOME is not exported to users' \
    'lock root account' \
    'verify no baked regular users, passwords, SSH host keys, or machine-id' \
    'remove NetworkManager, iwd, and wpa_supplicant network secrets' \
    'enable NetworkManager switcheroo-control power-profiles-daemon thermald fstrim.timer blade-firstboot-gpu.service' \
    'disable gdm.service' \
    'set-default multi-user.target' \
    "tar --acls --xattrs --numeric-owner -C $ROOTFS_DIR -cpf - . | zstd -T0 -3 -o $PAYLOAD_PATH" \
    "write $PAYLOAD_CHECKSUM" \
    "write $PACKAGE_MANIFEST" \
    "write $BUILD_MANIFEST"
}

sanitize_network_secrets() {
  local directory
  local -a secret_directories=(
    "$ROOTFS_DIR/etc/NetworkManager/system-connections"
    "$ROOTFS_DIR/var/lib/iwd"
    "$ROOTFS_DIR/etc/iwd"
    "$ROOTFS_DIR/etc/wpa_supplicant"
  )

  for directory in "${secret_directories[@]}"; do
    clear_build_directory "$directory"
    install -d -o root -g root -m0700 "$directory"
  done

  directory="$ROOTFS_DIR/var/lib/NetworkManager"
  assert_safe_build_child "$directory" >/dev/null
  install -d -o root -g root -m0700 "$directory"
  find "$directory" -mindepth 1 -maxdepth 1 \
    \( -name 'secret_key*' -o -name 'secret-key*' \) -delete
}

remove_codex_installer() {
  rm -f -- "$CODEX_INSTALLER" "$ROOTFS_DIR$CODEX_INSTALLER_CHROOT"
}

assert_no_codex_credentials() {
  local credential

  credential=$(find "$ROOTFS_DIR/opt/codex" "$ROOTFS_DIR/root" "$ROOTFS_DIR/home" \
    -type f \( -iname auth.json -o -iname credentials.json -o \
    -iname 'session*.jsonl' -o -iname history.jsonl -o -iname .netrc \) \
    -print -quit)
  [[ -z "$credential" ]] || die "Codex credential/session file found: $credential"

  if grep -R -E '(^|[[:space:]])(export[[:space:]]+)?CODEX_HOME=' \
    "$ROOTFS_DIR/etc/environment" "$ROOTFS_DIR/etc/profile" \
    "$ROOTFS_DIR/etc/profile.d" "$ROOTFS_DIR/root" "$ROOTFS_DIR/home" \
    >/dev/null 2>&1; then
    die 'CODEX_HOME must not be exported to installed users'
  fi
}

install_codex() {
  local actual_sha
  local install_status
  local version

  curl -fsSL "$CODEX_INSTALLER_URL" -o "$CODEX_INSTALLER"
  actual_sha=$(sha256sum "$CODEX_INSTALLER" | awk '{print $1}')
  if [[ "$actual_sha" != "$CODEX_INSTALLER_SHA256" ]]; then
    die "Codex installer SHA-256 mismatch: expected $CODEX_INSTALLER_SHA256, got $actual_sha"
    return 1
  fi

  install -Dm0700 "$CODEX_INSTALLER" "$ROOTFS_DIR$CODEX_INSTALLER_CHROOT"
  set +e
  arch-chroot "$ROOTFS_DIR" /usr/bin/env \
    CODEX_HOME=/opt/codex \
    CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_NON_INTERACTIVE=1 \
    CODEX_RELEASE="$CODEX_RELEASE" \
    /bin/sh "$CODEX_INSTALLER_CHROOT" >&2
  install_status=$?
  set -e
  remove_codex_installer
  if ((install_status != 0)); then
    die "Codex installer exited with status $install_status"
    return 1
  fi

  install -d -m0755 "$ROOTFS_DIR/opt/codex"
  chown -R root:root "$ROOTFS_DIR/opt/codex"
  chmod -R a+rX "$ROOTFS_DIR/opt/codex"
  version=$(arch-chroot "$ROOTFS_DIR" codex --version)
  if [[ "$version" != *"$CODEX_RELEASE"* ]]; then
    die "unexpected Codex version: $version"
    return 1
  fi
  assert_no_codex_credentials || return
  CODEX_INSTALLER_ACTUAL_SHA=$actual_sha
}

configure_rootfs() {
  install -Dm0644 "$TARGET_PACMAN_CONFIG" "$ROOTFS_DIR/etc/pacman.conf"
  cp -a -- "$TARGET_OVERLAY/." "$ROOTFS_DIR/"

  sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$ROOTFS_DIR/etc/locale.gen"
  printf 'LANG=en_US.UTF-8\n' >"$ROOTFS_DIR/etc/locale.conf"
  printf 'KEYMAP=us\n' >"$ROOTFS_DIR/etc/vconsole.conf"
  arch-chroot "$ROOTFS_DIR" locale-gen
  arch-chroot "$ROOTFS_DIR" passwd --lock root

  systemctl --root="$ROOTFS_DIR" enable \
    NetworkManager.service switcheroo-control.service \
    power-profiles-daemon.service thermald.service fstrim.timer \
    blade-firstboot-gpu.service
  systemctl --root="$ROOTFS_DIR" disable gdm.service
  systemctl --root="$ROOTFS_DIR" set-default multi-user.target
}

sanitize_rootfs() {
  local shadow_hash

  shadow_hash=$(awk -F: '$1 == "root" {print $2}' "$ROOTFS_DIR/etc/shadow")
  [[ "$shadow_hash" == '!'* || "$shadow_hash" == '*'* ]] ||
    die 'root account is not locked'
  if awk -F: '$3 >= 1000 && $3 < 65534 {found=1} END {exit found ? 0 : 1}' \
    "$ROOTFS_DIR/etc/passwd"; then
    die 'target root contains a baked regular user'
  fi

  rm -f -- "$ROOTFS_DIR/etc/crypttab" \
    "$ROOTFS_DIR/etc/machine-id" "$ROOTFS_DIR/var/lib/dbus/machine-id" \
    "$ROOTFS_DIR"/etc/ssh/ssh_host_*
  sanitize_network_secrets
  clear_build_directory "$ROOTFS_DIR/var/cache/pacman/pkg"
  clear_build_directory "$ROOTFS_DIR/var/log"
  clear_build_directory "$ROOTFS_DIR/tmp"
  clear_build_directory "$ROOTFS_DIR/var/tmp"
}

write_package_manifest() {
  LC_ALL=C arch-chroot "$ROOTFS_DIR" pacman -Q | LC_ALL=C sort >"$PACKAGE_MANIFEST"
}

write_manifests_and_archive() {
  local codex_installer_sha=$1
  local rootfs_sha
  local yay_package=$2
  local yay_sha

  write_package_manifest
  yay_sha=$(sha256sum "$yay_package" | awk '{print $1}')

  tar --acls --xattrs --numeric-owner -C "$ROOTFS_DIR" -cpf - . |
    zstd -T0 -3 -o "$PAYLOAD_PATH"
  (
    cd "$PAYLOAD_DIR"
    sha256sum rootfs.tar.zst >rootfs.tar.zst.sha256
  )
  rootfs_sha=$(sha256sum "$PAYLOAD_PATH" | awk '{print $1}')

  {
    printf 'project_slug=%s\n' "$PROJECT_SLUG"
    printf 'codex_release=%s\n' "$CODEX_RELEASE"
    printf 'codex_installer_url=%s\n' "$CODEX_INSTALLER_URL"
    printf 'codex_installer_sha256=%s\n' "$codex_installer_sha"
    printf 'yay_aur_url=%s\n' https://aur.archlinux.org/yay.git
    printf 'yay_aur_commit=%s\n' "$YAY_AUR_COMMIT"
    printf 'yay_package=%s\n' "${yay_package##*/}"
    printf 'yay_package_sha256=%s\n' "$yay_sha"
    printf 'rootfs_sha256=%s\n' "$rootfs_sha"
  } >"$BUILD_MANIFEST"
}

main() {
  local yay_package
  local -a target_packages
  local -a yay_packages

  load_build_config
  if ! read_target_packages target_packages; then
    return 1
  fi
  if is_dry_run; then
    print_plan
    return 0
  fi

  require_privileged_arch
  command -v curl >/dev/null 2>&1 || die 'curl is required'
  command -v zstd >/dev/null 2>&1 || die 'zstd is required'
  command -v tar >/dev/null 2>&1 || die 'tar is required'
  trap remove_codex_installer EXIT

  "$SCRIPT_DIR/build-yay.sh"
  mapfile -t yay_packages < <(
    find "$PACKAGE_DIR" -maxdepth 1 -type f -name 'yay-[0-9]*.pkg.tar.zst' -print
  )
  [[ ${#yay_packages[@]} -eq 1 ]] ||
    die "expected one local yay package, found ${#yay_packages[@]}"
  yay_package=${yay_packages[0]}

  [[ ${#target_packages[@]} -gt 0 ]] || die 'target package list is empty'
  reset_build_directory "$ROOTFS_DIR"
  reset_build_directory "$PAYLOAD_DIR"

  pacstrap -C "$TARGET_PACMAN_CONFIG" -K "$ROOTFS_DIR" "${target_packages[@]}"
  pacman --root "$ROOTFS_DIR" --noconfirm --upgrade "$yay_package"
  configure_rootfs
  install_codex
  sanitize_rootfs
  write_manifests_and_archive "$CODEX_INSTALLER_ACTUAL_SHA" "$yay_package"
  printf 'rootfs payload: %s\n' "$PAYLOAD_PATH"
}

main "$@"
