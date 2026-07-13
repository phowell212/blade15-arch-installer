#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  WORKFLOW="$REPO_ROOT/.github/workflows/build-iso.yml"
  CI_BUILD="$REPO_ROOT/scripts/ci-build.sh"
}

@test "ISO workflow is manually dispatched with read-only repository access" {
  [ -f "$WORKFLOW" ]
  grep -Eq '^[[:space:]]*workflow_dispatch:' "$WORKFLOW"
  grep -Eq '^[[:space:]]*permissions:' "$WORKFLOW"
  grep -Eq '^[[:space:]]*contents:[[:space:]]*read$' "$WORKFLOW"
  grep -Eq '^[[:space:]]*runs-on:[[:space:]]*ubuntu-24\.04$' "$WORKFLOW"
  grep -Eq '^[[:space:]]*timeout-minutes:[[:space:]]*360$' "$WORKFLOW"
}

@test "ISO workflow pins actions and runs static checks before privileged build" {
  local build_line
  local free_space_line
  local static_line

  grep -Fq 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$WORKFLOW"
  grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WORKFLOW"
  grep -Fq 'archlinux:base-devel ./scripts/ci-static.sh' "$WORKFLOW"
  grep -Fq 'sudo docker run --privileged --rm -v /dev:/dev -v "$GITHUB_WORKSPACE:/workspace" -w /workspace archlinux:base-devel ./scripts/ci-build.sh' "$WORKFLOW"
  grep -Fq 'sudo rm -rf -- /usr/local/lib/android /usr/share/dotnet /opt/ghc' "$WORKFLOW"

  free_space_line=$(grep -n -m1 'Free runner disk space' "$WORKFLOW" | cut -d: -f1)
  static_line=$(grep -n -m1 './scripts/ci-static\.sh' "$WORKFLOW" | cut -d: -f1)
  build_line=$(grep -n -m1 './scripts/ci-build\.sh' "$WORKFLOW" | cut -d: -f1)
  [ "$free_space_line" -lt "$static_line" ]
  [ "$static_line" -lt "$build_line" ]
}

@test "CI build installs dependencies before its first Git command" {
  local git_line
  local install_line

  install_line=$(grep -n -m1 '^[[:space:]]*install_dependencies$' "$CI_BUILD" | cut -d: -f1)
  git_line=$(grep -n -m1 '^[[:space:]]*git ' "$CI_BUILD" | cut -d: -f1)

  [ -n "$install_line" ]
  [ -n "$git_line" ]
  [ "$install_line" -lt "$git_line" ]
  grep -Eq '^[[:space:]]+grub$' "$CI_BUILD"
  grep -Eq '^[[:space:]]+qemu-img$' "$CI_BUILD"
  grep -Eq '^[[:space:]]+qemu-system-x86$' "$CI_BUILD"
  ! grep -Eq '^[[:space:]]+qemu-full$' "$CI_BUILD"
}

@test "ISO workflow uploads only verified release artifacts for fourteen days" {
  grep -Fq "hashFiles('dist/.verified')" "$WORKFLOW"
  grep -Eq '^[[:space:]]*name:[[:space:]]*blade15-arch-gnome-\$\{\{[[:space:]]*github\.run_number[[:space:]]*\}\}$' "$WORKFLOW"
  grep -Eq '^[[:space:]]*retention-days:[[:space:]]*14$' "$WORKFLOW"
  grep -Eq '^[[:space:]]*if-no-files-found:[[:space:]]*error$' "$WORKFLOW"

  run awk '
    /^[[:space:]]*path:[[:space:]]*\|[[:space:]]*$/ { in_paths=1; next }
    in_paths && /^[[:space:]]+dist\// {
      sub(/^[[:space:]]+/, "")
      print
      next
    }
    in_paths { exit }
  ' "$WORKFLOW"

  [ "$status" -eq 0 ]
  [ "$output" = $'dist/*.iso\ndist/*.sha256\ndist/*manifest*' ]
}

@test "CI build publishes its marker only after artifact verification" {
  local marker_line
  local qemu_line
  local verify_line

  grep -Fq 'rm -f -- "$REPO_ROOT/dist/.verified"' "$CI_BUILD"
  verify_line=$(grep -n -m1 './scripts/verify-artifacts.sh' "$CI_BUILD" | cut -d: -f1)
  marker_line=$(grep -n -m1 ': >"$REPO_ROOT/dist/.verified"' "$CI_BUILD" | cut -d: -f1)
  qemu_line=$(grep -n -m1 './tests/integration/qemu-boot.sh' "$CI_BUILD" | cut -d: -f1)

  [ "$verify_line" -lt "$marker_line" ]
  [ "$marker_line" -lt "$qemu_line" ]
}
