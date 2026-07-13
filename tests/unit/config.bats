#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$REPO_ROOT/build"
  TEST_TMPDIR=$(mktemp -d "$REPO_ROOT/build/task-1-config.XXXXXX")
  INSTALLED_ROOT="$TEST_TMPDIR/installed-root"
}

teardown() {
  case "$TEST_TMPDIR" in
    "$REPO_ROOT/build/task-1-config."*) rm -rf -- "$TEST_TMPDIR" ;;
    *) return 1 ;;
  esac
}

prepare_installed_libraries() {
  mkdir -p \
    "$INSTALLED_ROOT/usr/local/lib/blade-installer" \
    "$INSTALLED_ROOT/usr/share/blade-installer"
  cp "$REPO_ROOT/src/installer/lib/"*.sh \
    "$INSTALLED_ROOT/usr/local/lib/blade-installer/"
  cp "$REPO_ROOT/config/build.env" \
    "$INSTALLED_ROOT/usr/share/blade-installer/build.env"
}

@test "build inputs are pinned and safe" {
  run bash -eu -c '. "$1/config/build.env"; printf "%s\n" "$TARGET_DMI_FAMILY|$CODEX_RELEASE|$CODEX_INSTALLER_SHA256|$YAY_AUR_COMMIT|$ZRAM_MAX_MIB"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'RZ09-0421|0.144.1|1154e9daf713aacd1534efca8042bfd6665ad24bc1d1dfd86b8f439fe60a7a5d|cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0|8192' ]
}

@test "installer config loader prefers an explicit override to the source tree" {
  local override="$TEST_TMPDIR/override.env"

  printf '%s\n' \
    'TARGET_DMI_VENDOR=Override' \
    'TARGET_DMI_FAMILY=override-family' \
    'DEFAULT_HOSTNAME=override-host' \
    'DEFAULT_TIMEZONE=UTC' >"$override"

  run env -i PATH=/usr/bin:/bin BUILD_ENV_FILE="$override" bash -c '
    source "$1/src/installer/lib/common.sh"
    load_installer_config "$1/config/build.env"
    printf "%s|%s|%s|%s\n" \
      "$TARGET_DMI_VENDOR" "$TARGET_DMI_FAMILY" \
      "$DEFAULT_HOSTNAME" "$DEFAULT_TIMEZONE"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = 'Override|override-family|override-host|UTC' ]
}

@test "installer config loader uses the canonical installed path" {
  run bash -c '
    source "$1/src/installer/lib/common.sh"
    _installer_config_path
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = '/usr/share/blade-installer/build.env' ]
}

@test "installer config loader prefers the canonical file to the source tree" {
  local canonical="$TEST_TMPDIR/canonical.env"
  local source_tree="$TEST_TMPDIR/source-tree.env"

  printf '%s\n' \
    'TARGET_DMI_VENDOR=Canonical' \
    'TARGET_DMI_FAMILY=canonical-family' \
    'DEFAULT_HOSTNAME=canonical-host' \
    'DEFAULT_TIMEZONE=UTC' >"$canonical"
  printf '%s\n' \
    'TARGET_DMI_VENDOR=Source' \
    'TARGET_DMI_FAMILY=source-family' \
    'DEFAULT_HOSTNAME=source-host' \
    'DEFAULT_TIMEZONE=Etc/UTC' >"$source_tree"

  run env -i PATH=/usr/bin:/bin bash -c '
    source "$1/src/installer/lib/common.sh"
    test_canonical_path=$2
    _installer_config_path() { printf "%s\n" "$test_canonical_path"; }
    load_installer_config "$3"
    printf "%s|%s|%s|%s\n" \
      "$TARGET_DMI_VENDOR" "$TARGET_DMI_FAMILY" \
      "$DEFAULT_HOSTNAME" "$DEFAULT_TIMEZONE"
  ' _ "$REPO_ROOT" "$canonical" "$source_tree"

  [ "$status" -eq 0 ]
  [ "$output" = 'Canonical|canonical-family|canonical-host|UTC' ]
}

@test "installer config loader rejects an unsafe canonical file without fallback" {
  local canonical="$TEST_TMPDIR/canonical.env"
  local source_tree="$TEST_TMPDIR/source-tree.env"

  printf 'TARGET_DMI_VENDOR=Unsafe\n' >"$canonical.target"
  ln -s canonical.env.target "$canonical"
  cp "$REPO_ROOT/config/build.env" "$source_tree"

  run env -i PATH=/usr/bin:/bin bash -c '
    source "$1/src/installer/lib/common.sh"
    test_canonical_path=$2
    _installer_config_path() { printf "%s\n" "$test_canonical_path"; }
    load_installer_config "$3"
  ' _ "$REPO_ROOT" "$canonical" "$source_tree"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or unsafe installer configuration: $canonical"* ]]
}

@test "installer config loader falls back to the supplied source-tree file" {
  local missing_canonical="$TEST_TMPDIR/missing-canonical.env"

  run env -i PATH=/usr/bin:/bin bash -c '
    source "$1/src/installer/lib/common.sh"
    test_canonical_path=$2
    _installer_config_path() { printf "%s\n" "$test_canonical_path"; }
    load_installer_config "$1/config/build.env"
    printf "%s|%s|%s|%s\n" \
      "$TARGET_DMI_VENDOR" "$TARGET_DMI_FAMILY" \
      "$DEFAULT_HOSTNAME" "$DEFAULT_TIMEZONE"
  ' _ "$REPO_ROOT" "$missing_canonical"

  [ "$status" -eq 0 ]
  [ "$output" = 'Razer|RZ09-0421|blade15|America/New_York' ]
}

@test "installed-layout libraries load the staged config with an empty environment" {
  local config
  local library

  prepare_installed_libraries
  config="$INSTALLED_ROOT/usr/share/blade-installer/build.env"
  for library in preflight identity install; do
    run env -i PATH=/usr/bin:/bin BUILD_ENV_FILE="$config" bash -c '
      source "$1"
      printf "%s|%s|%s|%s\n" \
        "$TARGET_DMI_VENDOR" "$TARGET_DMI_FAMILY" \
        "$DEFAULT_HOSTNAME" "$DEFAULT_TIMEZONE"
    ' _ "$INSTALLED_ROOT/usr/local/lib/blade-installer/$library.sh"

    [ "$status" -eq 0 ]
    [ "$output" = 'Razer|RZ09-0421|blade15|America/New_York' ]
  done
}

@test "installed-layout libraries reject a missing canonical config" {
  local config

  prepare_installed_libraries
  config="$INSTALLED_ROOT/usr/share/blade-installer/build.env"
  rm "$config"

  run env -i PATH=/usr/bin:/bin BUILD_ENV_FILE="$config" bash -c \
    'source "$1"' _ \
    "$INSTALLED_ROOT/usr/local/lib/blade-installer/preflight.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or unsafe installer configuration: $config"* ]]
  [[ "$output" != *'TARGET_DMI_VENDOR is required'* ]]
}

@test "target list contains required desktop and GPU packages" {
  for package in gnome gdm networkmanager nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime switcheroo-control bubblewrap; do
    run grep -Fx "$package" "$REPO_ROOT/packages/target.txt"
    [ "$status" -eq 0 ]
  done
}
