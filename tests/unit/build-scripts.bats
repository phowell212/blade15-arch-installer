#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD_YAY="$REPO_ROOT/scripts/build-yay.sh"
  BUILD_ROOTFS="$REPO_ROOT/scripts/build-rootfs.sh"
  VERIFY_ROOTFS="$REPO_ROOT/scripts/verify-rootfs.sh"
}

prepare_manifest_fixture() {
  source "$REPO_ROOT/scripts/lib/build-common.sh"
  MANIFEST_FIXTURE="$BUILD_DIR/task-5-manifest-fixture"
  reset_build_directory "$MANIFEST_FIXTURE" >/dev/null
  mkdir -p "$MANIFEST_FIXTURE/root" "$MANIFEST_FIXTURE/payload" \
    "$MANIFEST_FIXTURE/packages"

  printf 'rootfs payload bytes\n' >"$MANIFEST_FIXTURE/payload/rootfs.tar.zst"
  (
    cd "$MANIFEST_FIXTURE/payload"
    sha256sum rootfs.tar.zst >rootfs.tar.zst.sha256
  )
  printf 'base 1.0-1\nyay 12.4.2-1\n' \
    >"$MANIFEST_FIXTURE/payload/target-packages.txt"
  printf 'yay package bytes\n' \
    >"$MANIFEST_FIXTURE/packages/yay-12.4.2-1-x86_64.pkg.tar.zst"

  local rootfs_sha
  local yay_sha
  rootfs_sha=$(sha256sum "$MANIFEST_FIXTURE/payload/rootfs.tar.zst" | awk '{print $1}')
  yay_sha=$(sha256sum \
    "$MANIFEST_FIXTURE/packages/yay-12.4.2-1-x86_64.pkg.tar.zst" | awk '{print $1}')
  {
    printf 'project_slug=blade15-arch-gnome\n'
    printf 'codex_release=0.144.1\n'
    printf 'codex_installer_url=https://chatgpt.com/codex/install.sh\n'
    printf 'codex_installer_sha256=1154e9daf713aacd1534efca8042bfd6665ad24bc1d1dfd86b8f439fe60a7a5d\n'
    printf 'yay_aur_url=https://aur.archlinux.org/yay.git\n'
    printf 'yay_aur_commit=cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0\n'
    printf 'yay_package=yay-12.4.2-1-x86_64.pkg.tar.zst\n'
    printf 'yay_package_sha256=%s\n' "$yay_sha"
    printf 'rootfs_sha256=%s\n' "$rootfs_sha"
  } >"$MANIFEST_FIXTURE/payload/build-manifest.txt"
}

verify_manifest_fixture() {
  run bash -c '
    export BLADE_DRY_RUN=1
    source "$1" >/dev/null
    ROOTFS_DIR=$2/root
    PAYLOAD_DIR=$2/payload
    PAYLOAD_PATH=$PAYLOAD_DIR/rootfs.tar.zst
    PAYLOAD_CHECKSUM=$PAYLOAD_DIR/rootfs.tar.zst.sha256
    PACKAGE_MANIFEST=$PAYLOAD_DIR/target-packages.txt
    BUILD_MANIFEST=$PAYLOAD_DIR/build-manifest.txt
    PACKAGE_DIR=$2/packages
    arch-chroot() {
      printf "base 1.0-1\nyay 12.4.2-1\n"
    }
    verify_outputs
  ' _ "$VERIFY_ROOTFS" "$MANIFEST_FIXTURE"
}

teardown() {
  if [[ -n ${MANIFEST_FIXTURE:-} && -e $MANIFEST_FIXTURE ]]; then
    reset_build_directory "$MANIFEST_FIXTURE" >/dev/null
    rmdir "$MANIFEST_FIXTURE"
  fi
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

@test "builder and verifier reject an invalid package after valid entries without partial output" {
  local package_list="$REPO_ROOT/build/task-5-invalid-target-packages.txt"
  mkdir -p "$REPO_ROOT/build"
  printf 'base\ninvalid;package\nlinux\n' >"$package_list"

  run bash -c '
    package_list=$1
    shift
    for script in "$@"; do
      (
        export BLADE_DRY_RUN=1
        source "$script" >/dev/null
        TARGET_PACKAGE_LIST=$package_list
        parsed=(stale)
        set +e
        read_target_packages parsed >/dev/null 2>&1
        parser_status=$?
        main >/dev/null 2>&1
        main_status=$?
        set -e
        [[ $parser_status -ne 0 && ${#parsed[@]} -eq 0 && $main_status -ne 0 ]]
      ) || exit 1
    done
  ' _ "$package_list" "$BUILD_ROOTFS" "$VERIFY_ROOTFS"
  parser_test_status=$status
  rm -f "$package_list"

  [ "$parser_test_status" -eq 0 ]
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

@test "network secrets are rejected then sanitized without touching package defaults" {
  run bash -c '
    export BLADE_DRY_RUN=1
    source "$1" >/dev/null
    source "$2" >/dev/null
    fixture="$BUILD_DIR/task-5-network-secrets"
    reset_build_directory "$fixture" >/dev/null
    ROOTFS_DIR=$fixture
    mkdir -p \
      "$fixture/etc/NetworkManager/system-connections" \
      "$fixture/var/lib/NetworkManager" \
      "$fixture/var/lib/iwd" \
      "$fixture/etc/iwd" \
      "$fixture/etc/wpa_supplicant" \
      "$fixture/usr/lib/iwd"
    printf "[wifi-security]\npsk=network-secret\n" \
      >"$fixture/etc/NetworkManager/system-connections/home.nmconnection"
    printf "PreSharedKey=network-secret\n" >"$fixture/var/lib/iwd/home.psk"
    printf "Passphrase=network-secret\n" >"$fixture/etc/iwd/home.psk"
    printf "network={ psk=network-secret }\n" \
      >"$fixture/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
    printf "network-manager-secret-key\n" \
      >"$fixture/var/lib/NetworkManager/secret_key_v2"
    printf "package-default\n" >"$fixture/usr/lib/iwd/package-default.conf"
    mode_log="$BUILD_DIR/task-5-network-secret-modes"
    : >"$mode_log"
    install() {
      local argument
      local mode=
      local target=${!#}
      for argument in "$@"; do
        case "$argument" in
          -m*) mode=${argument#-m} ;;
        esac
      done
      mode=${mode#0}
      command mkdir -p "$target"
      printf "%s|%s\n" "$mode" "$target" >>"$mode_log"
    }
    stat() {
      local candidate
      local recorded
      local recorded_path
      if [[ $1 == -c && $2 == %a ]]; then
        recorded=
        while IFS="|" read -r candidate recorded_path; do
          [[ $recorded_path == "$3" ]] && recorded=$candidate
        done <"$mode_log"
        if [[ -n $recorded ]]; then
          printf "%s\n" "$recorded"
          return 0
        fi
      fi
      command stat "$@"
    }

    set +e
    verify_no_network_secrets >/dev/null 2>&1
    before_status=$?
    sanitize_network_secrets >/dev/null 2>&1
    sanitize_status=$?
    verify_no_network_secrets >/dev/null 2>&1
    after_status=$?
    set -e

    directories_clean=0
    for directory in \
      etc/NetworkManager/system-connections var/lib/iwd etc/iwd etc/wpa_supplicant; do
      [[ $(stat -c "%a" "$fixture/$directory") == 700 ]] || directories_clean=1
      [[ -z $(find "$fixture/$directory" -mindepth 1 -print -quit) ]] || directories_clean=1
      grep -Fx "700|$fixture/$directory" "$mode_log" >/dev/null || directories_clean=1
    done
    [[ $(stat -c "%a" "$fixture/var/lib/NetworkManager") == 700 ]] || directories_clean=1
    grep -Fx "700|$fixture/var/lib/NetworkManager" "$mode_log" >/dev/null || directories_clean=1
    package_default_preserved=1
    [[ -f "$fixture/usr/lib/iwd/package-default.conf" ]] || package_default_preserved=0

    reset_build_directory "$fixture" >/dev/null
    rmdir "$fixture"
    rm -f "$mode_log"
    [[ $before_status -ne 0 && $sanitize_status -eq 0 && $after_status -eq 0 &&
      $directories_clean -eq 0 && $package_default_preserved -eq 1 ]]
  ' _ "$BUILD_ROOTFS" "$VERIFY_ROOTFS"

  [ "$status" -eq 0 ]
}

@test "valid package and artifact manifests verify against fresh evidence" {
  prepare_manifest_fixture

  verify_manifest_fixture

  [ "$status" -eq 0 ]
}

@test "package manifest must byte-match a fresh sorted pacman query" {
  prepare_manifest_fixture
  printf 'base 9.9-1\nyay 12.4.2-1\n' \
    >"$MANIFEST_FIXTURE/payload/target-packages.txt"

  verify_manifest_fixture

  [ "$status" -ne 0 ]
}

@test "build manifest rootfs digest must independently match the payload" {
  prepare_manifest_fixture
  sed -i \
    's/^rootfs_sha256=.*/rootfs_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$MANIFEST_FIXTURE/payload/build-manifest.txt"

  verify_manifest_fixture

  [ "$status" -ne 0 ]
}

@test "build manifest yay digest must match the retained local package" {
  prepare_manifest_fixture
  sed -i \
    's/^yay_package_sha256=.*/yay_package_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$MANIFEST_FIXTURE/payload/build-manifest.txt"

  verify_manifest_fixture

  [ "$status" -ne 0 ]
}

@test "build manifest rejects duplicate missing and malformed keys" {
  local duplicate_status
  local malformed_status
  local missing_status

  prepare_manifest_fixture
  printf 'project_slug=blade15-arch-gnome\n' \
    >>"$MANIFEST_FIXTURE/payload/build-manifest.txt"
  verify_manifest_fixture
  duplicate_status=$status

  prepare_manifest_fixture
  sed -i '/^rootfs_sha256=/d' "$MANIFEST_FIXTURE/payload/build-manifest.txt"
  verify_manifest_fixture
  missing_status=$status

  prepare_manifest_fixture
  printf 'not a manifest assignment\n' \
    >>"$MANIFEST_FIXTURE/payload/build-manifest.txt"
  verify_manifest_fixture
  malformed_status=$status

  [ "$duplicate_status" -ne 0 ]
  [ "$missing_status" -ne 0 ]
  [ "$malformed_status" -ne 0 ]
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
