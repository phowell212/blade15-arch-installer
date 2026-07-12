#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD_YAY="$REPO_ROOT/scripts/build-yay.sh"
  BUILD_ROOTFS="$REPO_ROOT/scripts/build-rootfs.sh"
  VERIFY_ROOTFS="$REPO_ROOT/scripts/verify-rootfs.sh"
  PREPARE_ARCHISO="$REPO_ROOT/scripts/prepare-archiso.sh"
  BUILD_ISO="$REPO_ROOT/scripts/build-iso.sh"
  VERIFY_ARTIFACTS="$REPO_ROOT/scripts/verify-artifacts.sh"
  QEMU_EXPECT="$REPO_ROOT/tests/integration/qemu-boot.exp"
  QEMU_FAKE_CHILD="$REPO_ROOT/tests/fixtures/qemu-fake-child.sh"
}

prepare_archiso_fixture() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/build-common.sh"
  ARCHISO_FIXTURE="$BUILD_DIR/task-6-releng-fixture-${BATS_TEST_NUMBER}"
  ARCHISO_PROFILE_OUTPUT="$BUILD_DIR/task-6-profile-fixture-${BATS_TEST_NUMBER}"
  reset_build_directory "$ARCHISO_FIXTURE" >/dev/null
  mkdir -p \
    "$ARCHISO_FIXTURE/releng/airootfs" \
    "$ARCHISO_FIXTURE/releng/efiboot/loader/entries" \
    "$ARCHISO_FIXTURE/releng/grub" \
    "$ARCHISO_FIXTURE/releng/syslinux" \
    "$ARCHISO_FIXTURE/payload"
  cat >"$ARCHISO_FIXTURE/releng/profiledef.sh" <<'EOF'
#!/usr/bin/env bash
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
file_permissions=(["/etc/shadow"]="0:0:400")
EOF
  printf 'base\nbash\n' >"$ARCHISO_FIXTURE/releng/packages.x86_64"
  cat >"$ARCHISO_FIXTURE/releng/efiboot/loader/entries/01-archiso-linux.conf" <<'EOF'
title    Arch Linux install medium
linux    /arch/boot/x86_64/vmlinuz-linux
initrd   /arch/boot/x86_64/initramfs-linux.img
options  archisobasedir=arch archisosearchuuid=ARCH_TEST
EOF
  cat >"$ARCHISO_FIXTURE/releng/efiboot/loader/entries/02-archiso-speech-linux.conf" <<'EOF'
title    Arch Linux install medium with speech
linux    /arch/boot/x86_64/vmlinuz-linux
initrd   /arch/boot/x86_64/initramfs-linux.img
options  archisobasedir=arch archisosearchuuid=ARCH_TEST accessibility=on
EOF
  printf 'timeout 15\ndefault 01-archiso-linux.conf\n' \
    >"$ARCHISO_FIXTURE/releng/efiboot/loader/loader.conf"
  cat >"$ARCHISO_FIXTURE/releng/grub/grub.cfg" <<'EOF'
menuentry 'Arch Linux install medium' {
  linux /arch/boot/x86_64/vmlinuz-linux archisobasedir=arch archisosearchuuid=ARCH_TEST
  initrd /arch/boot/x86_64/initramfs-linux.img
}
EOF
  cp "$ARCHISO_FIXTURE/releng/grub/grub.cfg" \
    "$ARCHISO_FIXTURE/releng/grub/loopback.cfg"
  cat >"$ARCHISO_FIXTURE/releng/syslinux/archiso_sys-linux.cfg" <<'EOF'
LABEL arch
MENU LABEL Arch Linux install medium
LINUX /arch/boot/x86_64/vmlinuz-linux
INITRD /arch/boot/x86_64/initramfs-linux.img
APPEND archisobasedir=arch archisosearchuuid=ARCH_TEST
EOF
  cp "$ARCHISO_FIXTURE/releng/syslinux/archiso_sys-linux.cfg" \
    "$ARCHISO_FIXTURE/releng/syslinux/archiso_pxe-linux.cfg"
  printf 'fixture payload\n' >"$ARCHISO_FIXTURE/payload/rootfs.tar.zst"
  (
    cd "$ARCHISO_FIXTURE/payload"
    sha256sum rootfs.tar.zst >rootfs.tar.zst.sha256
  )
  printf 'base 1.0-1\n' >"$ARCHISO_FIXTURE/payload/target-packages.txt"
  printf 'rootfs_sha256=fixture\n' \
    >"$ARCHISO_FIXTURE/payload/build-manifest.txt"
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
  if [[ -n ${ARCHISO_PROFILE_OUTPUT:-} && -d $ARCHISO_PROFILE_OUTPUT ]]; then
    clear_build_directory "$ARCHISO_PROFILE_OUTPUT" >/dev/null
    rmdir "$ARCHISO_PROFILE_OUTPUT"
  fi
  if [[ -n ${ARCHISO_FIXTURE:-} && -d $ARCHISO_FIXTURE ]]; then
    clear_build_directory "$ARCHISO_FIXTURE" >/dev/null
    rmdir "$ARCHISO_FIXTURE"
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

@test "build manifest verification rejects a missing named yay artifact" {
  prepare_manifest_fixture
  rm -f "$MANIFEST_FIXTURE/packages/yay-12.4.2-1-x86_64.pkg.tar.zst"

  verify_manifest_fixture

  [ "$status" -ne 0 ]
}

@test "build manifest verification rejects a symlinked named yay artifact" {
  prepare_manifest_fixture
  mv "$MANIFEST_FIXTURE/packages/yay-12.4.2-1-x86_64.pkg.tar.zst" \
    "$MANIFEST_FIXTURE/packages/yay-decoy.pkg.tar.zst"
  ln -s yay-decoy.pkg.tar.zst \
    "$MANIFEST_FIXTURE/packages/yay-12.4.2-1-x86_64.pkg.tar.zst"

  verify_manifest_fixture

  [ "$status" -ne 0 ]
}

@test "package manifest producer pins C locale for both pacman query and sort" {
  run bash -c '
    export BLADE_DRY_RUN=1
    source "$1" >/dev/null
    fixture="$BUILD_DIR/task-5-producer-locale"
    reset_build_directory "$fixture" >/dev/null
    ROOTFS_DIR=$fixture/root
    PACKAGE_MANIFEST=$fixture/target-packages.txt
    locale_log=$fixture/locales.log
    arch-chroot() {
      printf "arch-chroot:%s\n" "${LC_ALL-}" >>"$locale_log"
      printf "z-package 1\na-package 1\n"
    }
    sort() {
      printf "sort:%s\n" "${LC_ALL-}" >>"$locale_log"
      command sort "$@"
    }

    set +e
    write_package_manifest
    producer_status=$?
    set -e
    textual_status=0
    grep -F \
      "LC_ALL=C arch-chroot \"\$ROOTFS_DIR\" pacman -Q | LC_ALL=C sort >\"\$PACKAGE_MANIFEST\"" \
      "$1" >/dev/null || textual_status=$?
    behavior_status=0
    grep -Fx "arch-chroot:C" "$locale_log" >/dev/null || behavior_status=1
    grep -Fx "sort:C" "$locale_log" >/dev/null || behavior_status=1
    [[ $(cat "$PACKAGE_MANIFEST") == "$(printf "a-package 1\nz-package 1")" ]] ||
      behavior_status=1

    reset_build_directory "$fixture" >/dev/null
    rmdir "$fixture"
    [[ $producer_status -eq 0 && $textual_status -eq 0 && $behavior_status -eq 0 ]]
  ' _ "$BUILD_ROOTFS"

  [ "$status" -eq 0 ]
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

@test "archiso dry-run plans a complete boot-safe releng profile" {
  run env BLADE_DRY_RUN=1 "$PREPARE_ARCHISO"

  [ "$status" -eq 0 ]
  [[ "$output" == *'copy /usr/share/archiso/configs/releng to build/archiso-profile'* ]]
  while IFS= read -r package; do
    [[ -z "$package" ]] && continue
    [[ "$output" == *"append live package: $package"* ]]
  done <"$REPO_ROOT/packages/live.txt"
  [[ "$output" == *'install /usr/local/bin/blade-install mode 0755'* ]]
  for library in common disks identity install preflight; do
    [[ "$output" == *"install /usr/local/lib/blade-installer/$library.sh mode 0755"* ]]
  done
  [[ "$output" == *'profiledef permission /usr/local/bin/blade-install=0:0:755'* ]]
  [[ "$output" == *'profiledef permission /usr/local/lib/blade-installer/common.sh=0:0:755'* ]]
  [[ "$output" == *'enable blade-installer.service'* ]]
  [[ "$output" == *'embed /usr/share/blade-installer/rootfs.tar.zst'* ]]
  [[ "$output" == *'embed /usr/share/blade-installer/rootfs.tar.zst.sha256'* ]]
  [[ "$output" == *'embed /usr/share/blade-installer/target-packages.txt'* ]]
  [[ "$output" == *'embed /usr/share/blade-installer/build-manifest.txt'* ]]
  [[ "$output" == *'replace releng bootmodes with bios.syslinux and uefi.grub'* ]]
  [[ "$output" == *'patch active UEFI GRUB default entry'* ]]
  [[ "$output" == *'patch Syslinux default entry'* ]]
  [[ "$output" == *'systemd.unit=multi-user.target modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm'* ]]
  [[ "$output" == *'Rescue shell (no installer)'*'blade.noinstaller=1'* ]]
  [[ "$output" == *'QEMU serial installer test'*'blade.test=1'*'console=ttyS0,115200n8'* ]]
  [[ "$output" != *'/run/blade-installer'* ]]
}

@test "ISO dry-run keeps work and outputs in the repository and names release artifacts" {
  run env BLADE_DRY_RUN=1 "$BUILD_ISO"

  [ "$status" -eq 0 ]
  [[ "$output" == *'prepare-archiso.sh'* ]]
  [[ "$output" == *'mkarchiso -v -w'*'/build/archiso-work -o'*'/dist'*'/build/archiso-profile'* ]]
  [[ "$output" == *'blade15-arch-gnome-${BUILD_DATE}-${GIT_REV}.iso'* ]]
  [[ "$output" == *'generate ISO SHA-256 sidecar'* ]]
  [[ "$output" == *'copy target-packages.txt and build-manifest.txt to dist'* ]]
}

@test "artifact verifier dry-run inspects the inner airootfs image" {
  run env BLADE_DRY_RUN=1 "$VERIFY_ARTIFACTS"

  [ "$status" -eq 0 ]
  [[ "$output" == *'verify ISO SHA-256 sidecar'* ]]
  [[ "$output" == *'verify hybrid BIOS and UEFI boot structures'* ]]
  [[ "$output" == *'extract the airootfs image from the ISO'* ]]
  [[ "$output" == *'unsquashfs'* ]]
  [[ "$output" == *'verify inner /usr/local/bin/blade-install mode 0755'* ]]
  [[ "$output" == *'verify inner /usr/share/blade-installer/rootfs.tar.zst'* ]]
  [[ "$output" == *'verify inner payload checksum and manifests'* ]]
  [[ "$output" == *'verify inner blade-installer.service and serial test service'* ]]
  [[ "$output" == *'verify active UEFI GRUB and BIOS Syslinux boot stanzas'* ]]
  [[ "$output" == *'verify rescue and QEMU-only test entries'* ]]
}

@test "profile preparation mutates a releng fixture and keeps test routing isolated" {
  prepare_archiso_fixture

  run bash -c '
    source "$1"
    RELENG_PROFILE=$2/releng
    PAYLOAD_DIR=$2/payload
    PROFILE_DIR=$3
    AIROOTFS_DIR=$PROFILE_DIR/airootfs
    prepare_profile
  ' _ "$PREPARE_ARCHISO" "$ARCHISO_FIXTURE" "$ARCHISO_PROFILE_OUTPUT"

  [ "$status" -eq 0 ]
  [ -x "$ARCHISO_PROFILE_OUTPUT/airootfs/usr/local/bin/blade-install" ]
  [ -x "$ARCHISO_PROFILE_OUTPUT/airootfs/usr/local/bin/blade-qemu-serial-gate" ]
  for library in common disks identity install preflight; do
    [ -x "$ARCHISO_PROFILE_OUTPUT/airootfs/usr/local/lib/blade-installer/$library.sh" ]
    grep -F \
      "[\"/usr/local/lib/blade-installer/$library.sh\"]=\"0:0:755\"" \
      "$ARCHISO_PROFILE_OUTPUT/profiledef.sh"
  done
  grep -F '["/usr/local/bin/blade-qemu-serial-gate"]="0:0:755"' \
    "$ARCHISO_PROFILE_OUTPUT/profiledef.sh"
  run bash -c '
    declare -A file_permissions=()
    source "$1"
    [[ ${#bootmodes[@]} -eq 2 && ${bootmodes[0]} == bios.syslinux &&
      ${bootmodes[1]} == uefi.grub ]]
  ' _ "$ARCHISO_PROFILE_OUTPUT/profiledef.sh"
  [ "$status" -eq 0 ]
  ! grep -F 'uefi.systemd-boot' "$ARCHISO_PROFILE_OUTPUT/profiledef.sh"
  [ -L "$ARCHISO_PROFILE_OUTPUT/airootfs/etc/systemd/system/multi-user.target.wants/blade-installer.service" ]
  [ -L "$ARCHISO_PROFILE_OUTPUT/airootfs/etc/systemd/system/multi-user.target.wants/blade-installer-serial.service" ]
  [ -L "$ARCHISO_PROFILE_OUTPUT/airootfs/etc/systemd/system/multi-user.target.wants/blade-qemu-rescue.service" ]
  [ ! -e "$ARCHISO_PROFILE_OUTPUT/efiboot/loader/entries/90-blade-rescue.conf" ]
  grep -R -F 'blade.noinstaller=1' "$ARCHISO_PROFILE_OUTPUT/grub" \
    "$ARCHISO_PROFILE_OUTPUT/syslinux"
  grep -R -F 'blade.test=1' "$ARCHISO_PROFILE_OUTPUT/grub" \
    "$ARCHISO_PROFILE_OUTPUT/syslinux"
  grep -R -F 'QEMU serial rescue test' "$ARCHISO_PROFILE_OUTPUT/grub" \
    "$ARCHISO_PROFILE_OUTPUT/syslinux"
  ! grep -R -F '/run/blade-installer' "$ARCHISO_PROFILE_OUTPUT/airootfs"
}

@test "profile preparation fails before cleanup when a releng family is absent" {
  prepare_archiso_fixture
  mkdir -p "$ARCHISO_PROFILE_OUTPUT"
  printf 'preserve me\n' >"$ARCHISO_PROFILE_OUTPUT/sentinel"
  rm "$ARCHISO_FIXTURE/releng/grub/loopback.cfg"

  run bash -c '
    source "$1"
    RELENG_PROFILE=$2/releng
    PAYLOAD_DIR=$2/payload
    PROFILE_DIR=$3
    AIROOTFS_DIR=$PROFILE_DIR/airootfs
    prepare_profile
  ' _ "$PREPARE_ARCHISO" "$ARCHISO_FIXTURE" "$ARCHISO_PROFILE_OUTPUT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'grub/loopback.cfg'* ]]
  [ "$(cat "$ARCHISO_PROFILE_OUTPUT/sentinel")" = 'preserve me' ]
}

@test "profile preparation rejects any bootmode baseline other than releng Syslinux plus systemd-boot" {
  prepare_archiso_fixture
  mkdir -p "$ARCHISO_PROFILE_OUTPUT"
  printf 'preserve me\n' >"$ARCHISO_PROFILE_OUTPUT/sentinel"
  sed -i "s/'uefi.systemd-boot'/'uefi.grub'/" \
    "$ARCHISO_FIXTURE/releng/profiledef.sh"

  run bash -c '
    source "$1"
    RELENG_PROFILE=$2/releng
    PAYLOAD_DIR=$2/payload
    PROFILE_DIR=$3
    AIROOTFS_DIR=$PROFILE_DIR/airootfs
    prepare_profile
  ' _ "$PREPARE_ARCHISO" "$ARCHISO_FIXTURE" "$ARCHISO_PROFILE_OUTPUT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'expected bootmodes: bios.syslinux uefi.systemd-boot'* ]]
  [ "$(cat "$ARCHISO_PROFILE_OUTPUT/sentinel")" = 'preserve me' ]
}

@test "QEMU serial services require a real kernel flag and QEMU or KVM DMI" {
  local gate="$REPO_ROOT/src/live-rootfs/usr/local/bin/blade-qemu-serial-gate"
  local physical="$REPO_ROOT/src/live-rootfs/etc/systemd/system/blade-installer.service"
  local serial="$REPO_ROOT/src/live-rootfs/etc/systemd/system/blade-installer-serial.service"
  local rescue="$REPO_ROOT/src/live-rootfs/etc/systemd/system/blade-qemu-rescue.service"
  prepare_archiso_fixture

  run bash -c '
    source "$1"
    fixture=$2
    printf "QEMU\n" >"$fixture/vendor"
    printf "Standard PC (Q35 + ICH9, 2009)\n" >"$fixture/product"
    printf "archisobasedir=arch blade.test=1\n" >"$fixture/cmdline"
    qemu_dmi_matches "$fixture/vendor" "$fixture/product" &&
      kernel_cmdline_has "$fixture/cmdline" blade.test=1 &&
      ! kernel_cmdline_has "$fixture/cmdline" BLADE_TEST=1 &&
      printf "Razer\n" >"$fixture/vendor" &&
      ! qemu_dmi_matches "$fixture/vendor" "$fixture/product"
  ' _ "$gate" "$ARCHISO_FIXTURE"

  [ "$status" -eq 0 ]
  grep -Fx 'TTYPath=/dev/tty1' "$physical"
  grep -Fx 'ConditionKernelCommandLine=!blade.test=1' "$physical"
  grep -Fx 'TTYPath=/dev/ttyS0' "$serial"
  grep -Fx 'ConditionKernelCommandLine=blade.test=1' "$serial"
  grep -Fx 'ConditionKernelCommandLine=!blade.noinstaller=1' "$serial"
  grep -Fx 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' "$serial"
  grep -Fx 'ConditionKernelCommandLine=blade.noinstaller=1' "$rescue"
  grep -Fx 'ExecCondition=/usr/local/bin/blade-qemu-serial-gate' "$rescue"
}

@test "QEMU harness boots OVMF rescue and cancels before WIPE" {
  local harness="$REPO_ROOT/tests/integration/qemu-boot.sh"
  local expect_script="$REPO_ROOT/tests/integration/qemu-boot.exp"

  [ -x "$harness" ]
  [ -x "$expect_script" ]
  grep -F 'qemu-system-x86_64' "$expect_script"
  grep -F 'manufacturer=QEMU' "$expect_script"
  grep -F 'product=Standard PC (Q35 + ICH9, 2009)' "$expect_script"
  grep -F 'QEMU serial rescue test' "$expect_script"
  grep -F 'BLADE_TEST=1' "$expect_script"
  grep -F 'unsupported physical platform' "$expect_script"
  grep -F 'Safe installation targets:' "$expect_script"
  grep -F 'Type WIPE exactly' "$expect_script"
  grep -F 'CANCEL' "$expect_script"
  grep -F 'qemu-img map --output=json' "$harness"
  grep -F 'qemu boot: PASS' "$harness"
}

@test "Expect harness accepts successful rescue and installer fake children" {
  local mode

  for mode in rescue installer; do
    run env QEMU_EXPECT_TIMEOUT=3 expect "$QEMU_EXPECT" \
      --fake "$mode" success "$QEMU_FAKE_CHILD"
    [ "$status" -eq 0 ]
  done
}

@test "Expect harness rejects a fake child transition timeout" {
  run env QEMU_EXPECT_TIMEOUT=1 expect "$QEMU_EXPECT" \
    --fake installer timeout "$QEMU_FAKE_CHILD"

  [ "$status" -ne 0 ]
  [[ "$output" == *'timed out waiting for the archiso boot menu'* ]]
}

@test "Expect harness rejects early fake-child EOF" {
  run env QEMU_EXPECT_TIMEOUT=2 expect "$QEMU_EXPECT" \
    --fake installer early-eof "$QEMU_FAKE_CHILD"

  [ "$status" -ne 0 ]
  [[ "$output" == *'exited before the serial installer banner'* ]]
}

@test "Expect harness rejects a nonzero fake-child exit" {
  run env QEMU_EXPECT_TIMEOUT=3 expect "$QEMU_EXPECT" \
    --fake installer nonzero "$QEMU_FAKE_CHILD"

  [ "$status" -ne 0 ]
  [[ "$output" == *'child exited with status 7'* ]]
}

@test "Expect harness rejects fake-child signal termination" {
  run env QEMU_EXPECT_TIMEOUT=3 expect "$QEMU_EXPECT" \
    --fake installer signal "$QEMU_FAKE_CHILD"

  [ "$status" -ne 0 ]
  [[ "$output" == *'child terminated by signal'* ]]
}

@test "live banner identifies the destructive installer" {
  run grep -F 'Razer Blade Arch Linux Installer' "$REPO_ROOT/src/live-rootfs/etc/motd"

  [ "$status" -eq 0 ]
  grep -F 'requires exact WIPE confirmation' "$REPO_ROOT/src/live-rootfs/etc/motd"
}

@test "ISO checksum sidecar is bound to the selected release filename" {
  prepare_archiso_fixture
  mkdir -p "$ARCHISO_FIXTURE/dist"
  printf 'selected ISO bytes\n' >"$ARCHISO_FIXTURE/dist/selected.iso"
  printf 'decoy ISO bytes\n' >"$ARCHISO_FIXTURE/dist/decoy.iso"

  run bash -c '
    source "$1"
    iso=$2/selected.iso
    (
      cd "$2"
      sha256sum selected.iso >selected.iso.sha256
    )
    verify_iso_sidecar "$iso"
    (
      cd "$2"
      sha256sum decoy.iso >selected.iso.sha256
    )
    set +e
    verify_iso_sidecar "$iso"
    mismatch_status=$?
    set -e
    [[ $mismatch_status -ne 0 ]]
  ' _ "$VERIFY_ARTIFACTS" "$ARCHISO_FIXTURE/dist"

  [ "$status" -eq 0 ]
}

@test "inner build manifest digest is bound to the embedded payload" {
  prepare_archiso_fixture
  mkdir -p "$ARCHISO_FIXTURE/inner/usr/share/blade-installer"

  run bash -c '
    source "$1"
    INNER_ROOT=$2/inner
    payload_dir=$INNER_ROOT/usr/share/blade-installer
    printf "inner payload bytes\n" >"$payload_dir/rootfs.tar.zst"
    (
      cd "$payload_dir"
      sha256sum rootfs.tar.zst >rootfs.tar.zst.sha256
    )
    digest=$(sha256sum "$payload_dir/rootfs.tar.zst")
    digest=${digest%% *}
    printf "rootfs_sha256=%s\n" "$digest" >"$payload_dir/build-manifest.txt"
    verify_payload_sidecar
    printf "rootfs_sha256=%064d\n" 0 >"$payload_dir/build-manifest.txt"
    set +e
    verify_payload_sidecar
    mismatch_status=$?
    set -e
    [[ $mismatch_status -ne 0 ]]
  ' _ "$VERIFY_ARTIFACTS" "$ARCHISO_FIXTURE"

  [ "$status" -eq 0 ]
}
