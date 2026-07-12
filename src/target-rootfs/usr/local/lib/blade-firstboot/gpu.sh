#!/usr/bin/env bash

_gpu_fail() {
  printf 'GPU gate failed: %s\n' "$1" >&2
  return 1
}

_gpu_vendor_for_path() {
  local path=${1-}
  local parent
  local vendor

  [[ -n "$path" ]] || return 1
  if ! path=$("${REALPATH_BIN:-realpath}" -e -- "$path"); then
    return 1
  fi

  while [[ "$path" != / ]]; do
    if [[ -r "$path/vendor" ]]; then
      vendor=$(<"$path/vendor")
      vendor=${vendor,,}
      vendor=${vendor#0x}
      case "$vendor" in
        8086 | 10de)
          printf '%s\n' "$vendor"
          return 0
          ;;
      esac
    fi
    parent=${path%/*}
    [[ -n "$parent" && "$parent" != "$path" ]] || parent=/
    path=$parent
  done
  return 1
}

connected_internal_gpu() {
  local connector
  local vendor
  local had_nullglob=0
  local -a connectors

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  connectors=(
    "${SYS_CLASS_DRM:-/sys/class/drm}"/card*-eDP-*
    "${SYS_CLASS_DRM:-/sys/class/drm}"/card*-LVDS-*
  )
  ((had_nullglob == 1)) || shopt -u nullglob

  for connector in "${connectors[@]}"; do
    [[ -r "$connector/status" ]] || continue
    [[ "$(<"$connector/status")" == connected ]] || continue
    if ! vendor=$(_gpu_vendor_for_path "$connector"); then
      continue
    fi
    case "$vendor" in
      8086)
        printf 'intel\n'
        return 0
        ;;
      10de)
        printf 'nvidia\n'
        return 0
        ;;
    esac
  done

  _gpu_fail 'no connected internal eDP/LVDS connector owned by Intel or NVIDIA'
}

check_required_pci() {
  local line
  local normalized
  local pci_output
  local found_intel=0
  local found_nvidia=0

  if [[ ${LSPCI_OUTPUT+x} ]]; then
    pci_output=$LSPCI_OUTPUT
  elif ! pci_output=$("${LSPCI_BIN:-lspci}" -nn); then
    _gpu_fail 'unable to enumerate PCI devices'
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      *'VGA compatible controller'* | *'3D controller'* | *'Display controller'*) ;;
      *) continue ;;
    esac
    normalized=${line,,}
    [[ "$normalized" == *'[8086:'* ]] && found_intel=1
    [[ "$normalized" == *'[10de:'* ]] && found_nvidia=1
  done <<<"$pci_output"

  ((found_intel == 1)) || {
    _gpu_fail 'required Intel PCI display device (8086) not found'
    return 1
  }
  ((found_nvidia == 1)) || {
    _gpu_fail 'required NVIDIA PCI display device (10de) not found'
    return 1
  }
}

check_modules() {
  local module

  for module in i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
    if ! "${MODPROBE_BIN:-modprobe}" "$module"; then
      _gpu_fail "failed to load module: $module"
      return 1
    fi
    if [[ ! -d "${SYS_MODULE:-/sys/module}/$module" ]]; then
      _gpu_fail "required module not loaded: $module"
      return 1
    fi
  done

  if [[ ! -r "${SYS_MODULE:-/sys/module}/nvidia_drm/parameters/modeset" ]] ||
    [[ "$(<"${SYS_MODULE:-/sys/module}/nvidia_drm/parameters/modeset")" != Y ]]; then
    _gpu_fail 'NVIDIA DRM modeset is not Y'
    return 1
  fi
}

check_drm_nodes() {
  local card
  local card_name
  local vendor
  local found_intel=0
  local found_nvidia=0

  for card in "${SYS_CLASS_DRM:-/sys/class/drm}"/card*; do
    [[ -e "$card" ]] || continue
    card_name=${card##*/}
    [[ "$card_name" =~ ^card[0-9]+$ ]] || continue
    if ! vendor=$(_gpu_vendor_for_path "$card"); then
      continue
    fi
    [[ "$vendor" == 8086 ]] && found_intel=1
    [[ "$vendor" == 10de ]] && found_nvidia=1
  done

  ((found_intel == 1)) || {
    _gpu_fail 'Intel DRM device not found'
    return 1
  }
  ((found_nvidia == 1)) || {
    _gpu_fail 'NVIDIA DRM device not found'
    return 1
  }
}

check_nvidia_smi() {
  if ! "${TIMEOUT_BIN:-timeout}" 15 "${NVIDIA_SMI_BIN:-nvidia-smi}" -L; then
    _gpu_fail 'nvidia-smi timed out or failed'
    return 1
  fi
  if ! "${TIMEOUT_BIN:-timeout}" 15 "${SWITCHEROOCTL_BIN:-switcherooctl}" list; then
    _gpu_fail 'switcherooctl timed out or failed'
    return 1
  fi
}

gpu_gate() {
  connected_internal_gpu >/dev/null || return 1
  check_required_pci || return 1
  check_modules || return 1
  check_drm_nodes || return 1
  check_nvidia_smi || return 1
}
