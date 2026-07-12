#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD_YAY="$REPO_ROOT/scripts/build-yay.sh"
  BUILD_ROOTFS="$REPO_ROOT/scripts/build-rootfs.sh"
  VERIFY_ROOTFS="$REPO_ROOT/scripts/verify-rootfs.sh"
}

@test "yay dry-run pins the AUR source and builds as an unprivileged user" {
  run env BLADE_DRY_RUN=1 "$BUILD_YAY"

  [ "$status" -eq 0 ]
  [[ "$output" == *'https://aur.archlinux.org/yay.git'* ]]
  [[ "$output" == *'cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0'* ]]
  [[ "$output" == *'pacstrap'*'base-devel git sudo'* ]]
  [[ "$output" == *'useradd --create-home --user-group builder'* ]]
  [[ "$output" == *'runuser -u builder -- makepkg --syncdeps --cleanbuild --noconfirm'* ]]
  [[ "$output" == *'verify git rev-parse HEAD equals cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0'* ]]
  [[ "$output" == *'/build/packages/yay-*.pkg.tar.zst'* ]]
  [[ "$output" != *'runuser -u root -- makepkg'* ]]
}

@test "rootfs dry-run orders official pacstrap before local yay installation" {
  run env BLADE_DRY_RUN=1 "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
  [[ "$output" == *'config/pacman-target.conf -K'* ]]
  [[ "$output" == *'[multilib]'* ]]
  [[ "$output" == *'official target packages from packages/target.txt'* ]]
  [[ "$output" == *'pacman --root'*'--upgrade'*'yay-*.pkg.tar.zst'* ]]

  pacstrap_line="$(printf '%s\n' "$output" | grep -n 'official target packages' | cut -d: -f1)"
  yay_line="$(printf '%s\n' "$output" | grep -n 'yay-\*\.pkg\.tar\.zst' | tail -n1 | cut -d: -f1)"
  [ "$pacstrap_line" -lt "$yay_line" ]
}

@test "rootfs dry-run verifies the pinned Codex installer before isolated execution" {
  run env BLADE_DRY_RUN=1 "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
  [[ "$output" == *'https://chatgpt.com/codex/install.sh'* ]]
  [[ "$output" == *'1154e9daf713aacd1534efca8042bfd6665ad24bc1d1dfd86b8f439fe60a7a5d'* ]]
  [[ "$output" == *'verify downloaded installer SHA-256 before execution'* ]]
  [[ "$output" == *'CODEX_HOME=/opt/codex'* ]]
  [[ "$output" == *'CODEX_INSTALL_DIR=/usr/local/bin'* ]]
  [[ "$output" == *'CODEX_NON_INTERACTIVE=1'* ]]
  [[ "$output" == *'CODEX_RELEASE=0.144.1'* ]]
  [[ "$output" == *'/bin/sh /tmp/codex-install.sh'* ]]
  [[ "$output" == *'record codex_installer_sha256='* ]]
  [[ "$output" == *'remove /tmp/codex-install.sh immediately'* ]]
  [[ "$output" == *'verify no Codex auth/session files'* ]]
  [[ "$output" == *'verify CODEX_HOME is not exported to users'* ]]
}

@test "a Codex installer checksum mismatch cannot fall through to execution" {
  run bash -c '
    export BLADE_DRY_RUN=1
    source "$1" >/dev/null
    marker="$BUILD_DIR/task-5-codex-executed"
    mkdir -p "$BUILD_DIR"
    rm -f "$marker" "$CODEX_INSTALLER"
    CODEX_INSTALLER_SHA256=0000000000000000000000000000000000000000000000000000000000000000
    curl() {
      local output=
      while (($#)); do
        if [[ $1 == -o ]]; then
          shift
          output=$1
        fi
        shift
      done
      printf tampered >"$output"
    }
    install() { :; }
    chown() { :; }
    chmod() { :; }
    assert_no_codex_credentials() { :; }
    arch-chroot() {
      : >"$marker"
      [[ "$*" == *"codex --version"* ]] && printf "codex-cli %s\n" "$CODEX_RELEASE"
    }

    set +e
    codex_installer_sha=$(install_codex)
    status=$?
    set -e
    rm -f "$CODEX_INSTALLER"
    [[ $status -ne 0 && ! -e $marker ]]
  ' _ "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
}

@test "rootfs dry-run hardens, enables required services, and preserves archive metadata" {
  run env BLADE_DRY_RUN=1 "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
  [[ "$output" == *'lock root account'* ]]
  [[ "$output" == *'verify no baked regular users, passwords, SSH host keys, or machine-id'* ]]
  [[ "$output" == *'enable NetworkManager switcheroo-control power-profiles-daemon thermald fstrim.timer blade-firstboot-gpu.service'* ]]
  [[ "$output" == *'disable gdm.service'* ]]
  [[ "$output" == *'set-default multi-user.target'* ]]
  [[ "$output" == *'tar --acls --xattrs --numeric-owner'* ]]
  [[ "$output" == *'zstd -T0 -3'* ]]
  [[ "$output" == *'rootfs.tar.zst.sha256'* ]]
  [[ "$output" == *'target-packages.txt'* ]]
  [[ "$output" == *'build-manifest.txt'* ]]
}

@test "dry-run output paths stay beneath the repository build directory" {
  run env BUILD_DIR=/tmp/not-allowed ROOT=/tmp/not-allowed BLADE_DRY_RUN=1 "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$REPO_ROOT/build/rootfs"* ]]
  [[ "$output" == *"$REPO_ROOT/build/payload/rootfs.tar.zst"* ]]
  [[ "$output" != *'/tmp/not-allowed'* ]]
}

@test "recursive cleanup guard rejects empty, root, repository, build root, and external paths" {
  local common="$REPO_ROOT/scripts/lib/build-common.sh"
  local candidate

  for candidate in '' / "$REPO_ROOT" "$REPO_ROOT/build" "$BATS_TEST_TMPDIR"; do
    run bash -c 'source "$1"; assert_safe_build_child "$2"' _ "$common" "$candidate"
    [ "$status" -ne 0 ]
  done

  run bash -c 'source "$1"; assert_safe_build_child "$2"' _ "$common" "$REPO_ROOT/build/task-5-fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/build/task-5-fixture" ]
}

@test "recursive cleanup guard rejects a symlink alias to a sibling build path" {
  local common="$REPO_ROOT/scripts/lib/build-common.sh"
  local link="$REPO_ROOT/build/task-5-link"
  local real="$REPO_ROOT/build/task-5-real"

  mkdir -p "$real/child"
  ln -s task-5-real "$link"
  run bash -c 'source "$1"; assert_safe_build_child "$2"' \
    _ "$common" "$link/child"
  guard_status=$status
  rm -f "$link"
  rmdir "$real/child" "$real"

  [ "$guard_status" -ne 0 ]
}

@test "rootfs verifier dry-run covers packages, lock state, services, and credentials" {
  run env BLADE_DRY_RUN=1 "$VERIFY_ROOTFS"

  [ "$status" -eq 0 ]
  [[ "$output" == *'verify every package in packages/target.txt and yay is installed'* ]]
  [[ "$output" == *'verify complete package groups from packages/target.txt'* ]]
  [[ "$output" == *'verify required target overlay and global Codex files'* ]]
  [[ "$output" == *'verify root is locked and no regular user exists'* ]]
  [[ "$output" == *'verify gdm.service is disabled and multi-user.target is default'* ]]
  [[ "$output" == *'verify enabled: NetworkManager switcheroo-control power-profiles-daemon thermald fstrim.timer blade-firstboot-gpu.service'* ]]
  [[ "$output" == *'verify /etc/crypttab is absent'* ]]
  [[ "$output" == *'verify no credentials, auth/session files, SSH host keys, or machine-id'* ]]
  [[ "$output" == *'verify yay --version and codex --version in arch-chroot'* ]]
  [[ "$output" == *'verify codex version contains 0.144.1'* ]]
}
