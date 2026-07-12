#!/usr/bin/env bats

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "build inputs are pinned and safe" {
  run bash -eu -c '. "$1/config/build.env"; printf "%s\n" "$TARGET_DMI_FAMILY|$CODEX_RELEASE|$YAY_AUR_COMMIT|$ZRAM_MAX_MIB"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'RZ09-0421|0.144.1|cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0|8192' ]
}

@test "target list contains required desktop and GPU packages" {
  for package in gnome gdm networkmanager nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime switcheroo-control bubblewrap; do
    run grep -Fx "$package" "$REPO_ROOT/packages/target.txt"
    [ "$status" -eq 0 ]
  done
}
