#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-installer-bats.$$.$BATS_TEST_NUMBER}"
  mkdir -p "$BATS_TEST_TMPDIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  if [[ -f "$REPO_ROOT/src/installer/lib/identity.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/src/installer/lib/identity.sh"
  fi
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

@test "valid usernames match the required lowercase pattern" {
  for value in a _ blade15 blade-user blade_user; do
    run valid_username "$value"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "invalid usernames are rejected" {
  local thirty_three='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  for value in '' 9blade Blade blade.user "$thirty_three"; do
    run valid_username "$value"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "valid hostnames are RFC-style labels" {
  local sixty_three='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  for value in a blade15 blade-15 BLADE15 "$sixty_three"; do
    run valid_hostname "$value"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "hostnames reject empty oversized and malformed labels" {
  local sixty_four='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  for value in '' -blade blade- blade_15 blade.local "$sixty_four"; do
    run valid_hostname "$value"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "wipe confirmation accepts only exact uppercase WIPE" {
  run require_wipe_confirmation WIPE
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  for value in '' wipe ' WIPE' 'WIPE ' 'WIPE\n'; do
    run require_wipe_confirmation "$value"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "password collection rejects short and mismatched entries without leaking them" {
  run bash -c 'source "$1"; printf "%s\n%s\n" short short | set_user_password /target blade' _ "$REPO_ROOT/src/installer/lib/identity.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *short* ]]

  run bash -c 'source "$1"; printf "%s\n%s\n" first-secret second-secret | set_user_password /target blade' _ "$REPO_ROOT/src/installer/lib/identity.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *first-secret* ]]
  [[ "$output" != *second-secret* ]]
}

@test "password is sent only to chrooted chpasswd and is not exported" {
  local fake_chroot="$BATS_TEST_TMPDIR/arch-chroot"
  local capture="$BATS_TEST_TMPDIR/capture"
  cat >"$fake_chroot" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
[[ "$1" == /target && "$2" == chpasswd ]]
if env | grep -Eq '^(password|password_confirm)='; then
  exit 90
fi
IFS= read -r line
printf '%s\n' "$line" >"$PASSWORD_CAPTURE"
SCRIPT
  chmod +x "$fake_chroot"

  run bash -c 'source "$1"; printf "%s\n%s\n" long-secret long-secret | ARCH_CHROOT_BIN="$2" PASSWORD_CAPTURE="$3" set_user_password /target blade' _ "$REPO_ROOT/src/installer/lib/identity.sh" "$fake_chroot" "$capture"
  [ "$status" -eq 0 ]
  [ "$output" = $'Password: \nConfirm password: ' ]
  [ "$(<"$capture")" = 'blade:long-secret' ]
}
