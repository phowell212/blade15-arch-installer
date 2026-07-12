#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/build-common.sh"

YAY_AUR_URL=https://aur.archlinux.org/yay.git
YAY_BUILD_ROOT="$BUILD_DIR/yay-root"
PACKAGE_DIR="$BUILD_DIR/packages"

print_plan() {
  printf '%s\n' \
    "yay source: $YAY_AUR_URL" \
    "yay commit: $YAY_AUR_COMMIT" \
    "reset clean Arch build root: $YAY_BUILD_ROOT" \
    "pacstrap -C $TARGET_PACMAN_CONFIG -K $YAY_BUILD_ROOT base base-devel git sudo" \
    "arch-chroot $YAY_BUILD_ROOT useradd --create-home --user-group builder" \
    "clone $YAY_AUR_URL as builder" \
    "verify git rev-parse HEAD equals $YAY_AUR_COMMIT" \
    'runuser -u builder -- makepkg --syncdeps --cleanbuild --noconfirm' \
    "copy only /home/builder/yay/yay-[0-9]*.pkg.tar.zst to $PACKAGE_DIR/yay-*.pkg.tar.zst" \
    'never execute makepkg as root'
}

cleanup_build_root() {
  if [[ -e "$YAY_BUILD_ROOT" || -L "$YAY_BUILD_ROOT" ]]; then
    reset_build_directory "$YAY_BUILD_ROOT"
    rmdir -- "$YAY_BUILD_ROOT"
  fi
}

main() {
  local actual_commit
  local package
  local package_name
  local -a built_packages

  load_build_config
  if is_dry_run; then
    print_plan
    return 0
  fi

  require_privileged_arch
  command -v git >/dev/null 2>&1 || die 'git is required'
  trap cleanup_build_root EXIT

  reset_build_directory "$YAY_BUILD_ROOT"
  mkdir -p -- "$PACKAGE_DIR"
  assert_safe_build_child "$PACKAGE_DIR" >/dev/null
  find "$PACKAGE_DIR" -maxdepth 1 -type f -name 'yay-*.pkg.tar.zst' -delete

  pacstrap -C "$TARGET_PACMAN_CONFIG" -K "$YAY_BUILD_ROOT" \
    base base-devel git sudo
  arch-chroot "$YAY_BUILD_ROOT" useradd --create-home --user-group builder
  install -Dm0440 /dev/stdin "$YAY_BUILD_ROOT/etc/sudoers.d/builder" <<'EOF'
builder ALL=(root) NOPASSWD: /usr/bin/pacman
EOF
  arch-chroot "$YAY_BUILD_ROOT" chown root:root /etc/sudoers.d/builder

  arch-chroot "$YAY_BUILD_ROOT" /usr/bin/runuser -u builder -- \
    git clone "$YAY_AUR_URL" /home/builder/yay
  arch-chroot "$YAY_BUILD_ROOT" /usr/bin/runuser -u builder -- \
    git -C /home/builder/yay checkout --detach "$YAY_AUR_COMMIT"
  actual_commit=$(arch-chroot "$YAY_BUILD_ROOT" /usr/bin/runuser -u builder -- \
    git -C /home/builder/yay rev-parse HEAD)
  [[ "$actual_commit" == "$YAY_AUR_COMMIT" ]] ||
    die "yay commit mismatch: expected $YAY_AUR_COMMIT, got $actual_commit"

  arch-chroot "$YAY_BUILD_ROOT" /usr/bin/runuser -u builder -- \
    /bin/bash -c 'cd /home/builder/yay && exec makepkg --syncdeps --cleanbuild --noconfirm'

  mapfile -t built_packages < <(
    find "$YAY_BUILD_ROOT/home/builder/yay" -maxdepth 1 -type f \
      -name 'yay-[0-9]*.pkg.tar.zst' -print
  )
  [[ ${#built_packages[@]} -eq 1 ]] ||
    die "expected exactly one yay package, found ${#built_packages[@]}"

  package=${built_packages[0]}
  package_name=${package##*/}
  install -m0644 -- "$package" "$PACKAGE_DIR/$package_name"
  printf 'yay package: %s\n' "$PACKAGE_DIR/$package_name"
}

main "$@"
