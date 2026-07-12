#!/usr/bin/env bash

_installer_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_installer_lib_dir/common.sh"
_build_env_file=${BUILD_ENV_FILE:-"$_installer_lib_dir/../../../config/build.env"}
if [[ -r "$_build_env_file" ]]; then
  # shellcheck source=/dev/null
  source "$_build_env_file"
fi
unset _installer_lib_dir _build_env_file

: "${TARGET_DMI_VENDOR:?TARGET_DMI_VENDOR is required}"
: "${TARGET_DMI_FAMILY:?TARGET_DMI_FAMILY is required}"

_dmi_value() {
  local injected_name=$1
  local production_path=$2
  local value=''

  if [[ -n "${!injected_name+x}" ]]; then
    printf '%s\n' "${!injected_name}"
    return 0
  fi

  [[ -r "$production_path" ]] || return 1
  IFS= read -r value <"$production_path" || [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

_is_qemu_or_kvm() {
  local vendor=${1,,}
  local product=${2,,}
  local identity="$vendor $product"

  [[ "$identity" =~ (^|[^a-z0-9])(qemu|kvm)([^a-z0-9]|$) ]]
}

_secure_boot_enabled() {
  local value
  local status_output

  if [[ -n "${SECURE_BOOT_VALUE+x}" ]]; then
    value=${SECURE_BOOT_VALUE,,}
  else
    if ! status_output=$("${BOOTCTL_BIN:-bootctl}" status 2>&1); then
      die "Unable to determine Secure Boot status"
    fi
    status_output=${status_output,,}
    case "$status_output" in
      *secure\ boot:*enabled*) value=1 ;;
      *secure\ boot:*disabled* | *secure\ boot:*unsupported*) value=0 ;;
      *) die "Unable to determine Secure Boot status" ;;
    esac
  fi

  case "$value" in
    1 | yes | true | enabled) return 0 ;;
    0 | no | false | disabled) return 1 ;;
    *) die "Unable to determine Secure Boot status" ;;
  esac
}

require_supported_platform() {
  local uefi_path=${UEFI_PATH:-/sys/firmware/efi}
  local vendor_path=${DMI_VENDOR_PATH:-/sys/class/dmi/id/sys_vendor}
  local product_path=${DMI_PRODUCT_PATH:-/sys/class/dmi/id/product_name}
  local vendor
  local product

  if ! vendor=$(_dmi_value DMI_VENDOR "$vendor_path"); then
    die "Unable to read DMI system vendor"
  fi
  if ! product=$(_dmi_value DMI_PRODUCT "$product_path"); then
    die "Unable to read DMI product name"
  fi

  if _is_qemu_or_kvm "$vendor" "$product" && cmdline_has 'blade.test=1'; then
    return 0
  fi

  [[ -d "$uefi_path" ]] || die "UEFI boot is required"
  if _secure_boot_enabled; then
    die "Secure Boot must be disabled"
  fi

  if [[ "$vendor" != "$TARGET_DMI_VENDOR" ]] ||
    [[ " $product " != *" $TARGET_DMI_FAMILY "* ]]; then
    die "unsupported physical platform: expected $TARGET_DMI_VENDOR family $TARGET_DMI_FAMILY"
  fi
}
