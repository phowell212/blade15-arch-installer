#!/usr/bin/env bash
set -Eeuo pipefail

mode=${1:?mode is required}
scenario=${2:?scenario is required}

case "$scenario" in
  timeout)
    sleep 5
    exit 0
    ;;
  early-eof)
    printf 'QEMU serial rescue test\n'
    exit 0
    ;;
  success | nonzero | signal) ;;
  *)
    printf 'unknown fake scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac

printf 'QEMU serial rescue test\n'
IFS= read -r _
if [[ "$mode" == rescue ]]; then
  printf 'root@archiso ~ # '
  IFS= read -r _
  printf 'root@archiso ~ # '
  IFS= read -r _
  printf 'unsupported physical platform\nroot@archiso ~ #\n'
elif [[ "$mode" == installer ]]; then
  printf 'Razer Blade Arch Linux Installer\nSafe installation targets:\nSelect a target number: '
  IFS= read -r _
  printf 'Hostname [archiso]: '
  IFS= read -r _
  printf 'Local username: '
  IFS= read -r _
  printf 'Password: '
  IFS= read -r _
  printf 'Confirm password: '
  IFS= read -r _
  printf 'Type WIPE exactly: '
  IFS= read -r _
  printf 'Installation cancelled: WIPE was not entered exactly\n'
else
  printf 'invalid fake mode: %s\n' "$mode" >&2
  exit 64
fi

stty -icanon -echo min 1 time 0
dd bs=1 count=2 status=none >/dev/null
stty sane
case "$scenario" in
  success) exit 0 ;;
  nonzero) exit 7 ;;
  signal) kill -TERM "$$" ;;
esac
