#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ACTIONLINT_VERSION=1.7.7

install_tools() {
  if ((EUID != 0)); then
    printf 'ci static: root is required to install tools\n' >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ ${ID:-} != arch ]]; then
    printf 'ci static: Arch Linux is required to install tools\n' >&2
    return 1
  fi

  pacman -Syu --needed --noconfirm bats git go shellcheck shfmt
  GOBIN=/usr/local/bin go install \
    "github.com/rhysd/actionlint/cmd/actionlint@v$ACTIONLINT_VERSION"
}

main() {
  local actual_actionlint_version
  local -a shell_files=()

  cd -- "$REPO_ROOT"
  if [[ ${CI_INSTALL_TOOLS:-1} == 1 ]]; then
    install_tools
  fi
  git config --global --add safe.directory "$REPO_ROOT"

  for command_name in bats shellcheck shfmt actionlint; do
    command -v "$command_name" >/dev/null || {
      printf 'ci static: %s is required\n' "$command_name" >&2
      return 1
    }
  done
  actual_actionlint_version=$(actionlint -version)
  [[ "$actual_actionlint_version" == *"$ACTIONLINT_VERSION"* ]] || {
    printf 'ci static: expected actionlint %s, got %s\n' \
      "$ACTIONLINT_VERSION" "$actual_actionlint_version" >&2
    return 1
  }

  mapfile -d '' -t shell_files < <(
    git ls-files -z -- '*.sh' \
      src/installer/blade-install \
      src/live-rootfs/usr/local/bin/blade-qemu-serial-gate \
      src/target-rootfs/usr/local/sbin/blade-firstboot-gpu
  )
  ((${#shell_files[@]} > 0)) || {
    printf 'ci static: no tracked shell files found\n' >&2
    return 1
  }

  bats tests/unit
  shellcheck "${shell_files[@]}"
  shfmt -d -i 2 -ci "${shell_files[@]}"
  actionlint .github/workflows/build-iso.yml
}

main "$@"
