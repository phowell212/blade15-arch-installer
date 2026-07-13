#!/usr/bin/env bash

_installer_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_installer_lib_dir/common.sh"
load_installer_config "$_installer_lib_dir/../../../config/build.env"
unset _installer_lib_dir

: "${DEFAULT_HOSTNAME:?DEFAULT_HOSTNAME is required}"

valid_hostname() {
  local value=${1-}

  ((${#value} >= 1 && ${#value} <= 63)) || return 1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

valid_username() {
  local value=${1-}

  [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

require_wipe_confirmation() {
  [[ "${1-}" == WIPE ]]
}

set_user_password() {
  local root=${1-}
  local username=${2-}
  local password=''
  local password_confirm=''
  local command_status=0

  [[ -n "$root" ]] || die "Target root is required for password setup"
  valid_username "$username" || die "A valid username is required for password setup"

  printf 'Password: ' >&2
  if ! IFS= read -r -s password; then
    printf '\n' >&2
    password=''
    password_confirm=''
    unset password password_confirm
    die "Unable to read password"
  fi
  printf '\nConfirm password: ' >&2
  if ! IFS= read -r -s password_confirm; then
    printf '\n' >&2
    password=''
    password_confirm=''
    unset password password_confirm
    die "Unable to read password confirmation"
  fi
  printf '\n' >&2

  if ((${#password} < 8)); then
    password=''
    password_confirm=''
    unset password password_confirm
    die "Password must contain at least eight characters"
  fi
  if [[ "$password" != "$password_confirm" ]]; then
    password=''
    password_confirm=''
    unset password password_confirm
    die "Password entries do not match"
  fi

  if printf '%s:%s\n' "$username" "$password" |
    "${ARCH_CHROOT_BIN:-arch-chroot}" "$root" chpasswd; then
    command_status=0
  else
    command_status=$?
  fi

  password=''
  password_confirm=''
  unset password password_confirm
  ((command_status == 0)) || die "Unable to set the account password"
}
