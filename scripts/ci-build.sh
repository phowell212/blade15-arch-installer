#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

require_privileged_arch() {
  if ((EUID != 0)); then
    printf 'ci build: root is required\n' >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ ${ID:-} != arch ]]; then
    printf 'ci build: Arch Linux is required\n' >&2
    return 1
  fi
}

install_dependencies() {
  local -a packages=(
    arch-install-scripts
    archiso
    bats
    cdrtools
    cryptsetup
    curl
    dosfstools
    e2fsprogs
    edk2-ovmf
    expect
    git
    go
    gptfdisk
    jq
    libarchive
    parted
    qemu-img
    qemu-system-x86
    shellcheck
    shfmt
    squashfs-tools
    xorriso
    zstd
  )

  pacman -Syu --needed --noconfirm "${packages[@]}"
}

main() {
  (($# == 0)) || {
    printf 'usage: ci-build.sh\n' >&2
    return 1
  }
  require_privileged_arch
  cd -- "$REPO_ROOT"
  install_dependencies
  git config --global --add safe.directory "$REPO_ROOT"

  ./scripts/ci-static.sh
  ./scripts/build-rootfs.sh
  ./scripts/verify-rootfs.sh
  ./tests/integration/loop-install.sh
  ./scripts/build-iso.sh
  ./scripts/verify-artifacts.sh

  install -Dm0755 src/installer/blade-install /usr/local/bin/blade-install
  install -Dm0755 src/live-rootfs/usr/local/bin/blade-qemu-serial-gate \
    /usr/local/bin/blade-qemu-serial-gate
  install -Dm0755 src/target-rootfs/usr/local/sbin/blade-firstboot-gpu \
    /usr/local/sbin/blade-firstboot-gpu
  systemd-analyze verify \
    src/live-rootfs/etc/systemd/system/blade-installer.service \
    src/live-rootfs/etc/systemd/system/blade-installer-serial.service \
    src/live-rootfs/etc/systemd/system/blade-qemu-rescue.service \
    src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service
  ./tests/integration/qemu-boot.sh
}

main "$@"
