#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-gpu-bats.$$.$BATS_TEST_NUMBER}"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GPU_LIB="$REPO_ROOT/src/target-rootfs/usr/local/lib/blade-firstboot/gpu.sh"
  GPU_EXEC="$REPO_ROOT/src/target-rootfs/usr/local/sbin/blade-firstboot-gpu"
  FIXTURES="$REPO_ROOT/tests/fixtures/gpu"
  mkdir -p "$BATS_TEST_TMPDIR"

  if [[ -f "$GPU_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$GPU_LIB"
  fi
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

materialize_gpu_fixture() {
  local name=$1
  local intel_device="$BATS_TEST_TMPDIR/sys/devices/pci0000:00/0000:00:02.0"
  local nvidia_device="$BATS_TEST_TMPDIR/sys/devices/pci0000:00/0000:01:00.0"
  local panel_card panel_device module

  # shellcheck source=/dev/null
  source "$FIXTURES/$name.fixture"
  SYS_CLASS_DRM="$BATS_TEST_TMPDIR/sys/class/drm"
  SYS_MODULE="$BATS_TEST_TMPDIR/sys/module"
  mkdir -p "$SYS_CLASS_DRM" "$SYS_MODULE" "$intel_device" "$nvidia_device"

  printf '0x8086\n' >"$intel_device/vendor"
  printf '0x10de\n' >"$nvidia_device/vendor"
  mkdir -p "$intel_device/drm/$INTEL_CARD" "$nvidia_device/drm/$NVIDIA_CARD"
  ln -s "$intel_device/drm/$INTEL_CARD" "$SYS_CLASS_DRM/$INTEL_CARD"
  ln -s "$nvidia_device/drm/$NVIDIA_CARD" "$SYS_CLASS_DRM/$NVIDIA_CARD"

  if [[ "$PANEL_OWNER" == intel ]]; then
    panel_card=$INTEL_CARD
    panel_device=$intel_device
  else
    panel_card=$NVIDIA_CARD
    panel_device=$nvidia_device
  fi
  mkdir -p "$panel_device/drm/$panel_card/$panel_card-eDP-1"
  printf 'connected\n' >"$panel_device/drm/$panel_card/$panel_card-eDP-1/status"
  ln -s "$panel_device/drm/$panel_card/$panel_card-eDP-1" \
    "$SYS_CLASS_DRM/$panel_card-eDP-1"

  for module in i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
    [[ "$module" == "$OMIT_MODULE" ]] || mkdir -p "$SYS_MODULE/$module"
  done
  if [[ -d "$SYS_MODULE/nvidia_drm" ]]; then
    mkdir -p "$SYS_MODULE/nvidia_drm/parameters"
    printf 'Y\n' >"$SYS_MODULE/nvidia_drm/parameters/modeset"
  fi

  LSPCI_OUTPUT="$(<"$FIXTURES/lspci-hybrid.txt")"
  export SYS_CLASS_DRM SYS_MODULE LSPCI_OUTPUT NVIDIA_SMI_STATUS
}

make_fake_commands() {
  local tool

  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/tool" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >>"$COMMAND_LOG"
case "$tool" in
  timeout)
    command_name=${2##*/}
    case "$command_name" in
      nvidia-smi) exit "${NVIDIA_SMI_STATUS:-0}" ;;
      switcherooctl) exit "${SWITCHEROOCTL_STATUS:-0}" ;;
    esac
    ;;
esac
SCRIPT
  chmod +x "$FAKE_BIN/tool"
  for tool in modprobe timeout systemctl reboot; do
    ln -s tool "$FAKE_BIN/$tool"
  done

  MODPROBE_BIN="$FAKE_BIN/modprobe"
  TIMEOUT_BIN="$FAKE_BIN/timeout"
  NVIDIA_SMI_BIN=nvidia-smi
  SWITCHEROOCTL_BIN=switcherooctl
  SYSTEMCTL_BIN="$FAKE_BIN/systemctl"
  REBOOT_BIN="$FAKE_BIN/reboot"
  export COMMAND_LOG MODPROBE_BIN TIMEOUT_BIN NVIDIA_SMI_BIN
  export SWITCHEROOCTL_BIN SYSTEMCTL_BIN REBOOT_BIN
}

assert_gate_commands() {
  local expected="$BATS_TEST_TMPDIR/expected-commands"

  printf '%s\n' \
    'modprobe i915' \
    'modprobe nvidia' \
    'modprobe nvidia_modeset' \
    'modprobe nvidia_uvm' \
    'modprobe nvidia_drm' \
    'timeout 15 nvidia-smi -L' \
    'timeout 15 switcherooctl list' >"$expected"
  cmp "$expected" "$COMMAND_LOG"
}

@test "Intel-owned connected internal panel passes the hybrid GPU gate" {
  materialize_gpu_fixture intel-panel
  make_fake_commands

  run connected_internal_gpu
  [ "$status" -eq 0 ]
  [ "$output" = intel ]

  run gpu_gate
  [ "$status" -eq 0 ]
  assert_gate_commands
}

@test "NVIDIA-owned connected internal panel passes the hybrid GPU gate" {
  materialize_gpu_fixture nvidia-panel
  make_fake_commands

  run connected_internal_gpu
  [ "$status" -eq 0 ]
  [ "$output" = nvidia ]

  run gpu_gate
  [ "$status" -eq 0 ]
  assert_gate_commands
}

@test "missing nvidia_drm fails with a precise reason" {
  materialize_gpu_fixture missing-nvidia-drm
  make_fake_commands

  run gpu_gate
  [ "$status" -ne 0 ]
  [ "$output" = 'GPU gate failed: required module not loaded: nvidia_drm' ]
}

@test "timed-out nvidia-smi fails with a precise reason" {
  materialize_gpu_fixture nvidia-smi-timeout
  make_fake_commands

  run gpu_gate
  [ "$status" -ne 0 ]
  [ "$output" = 'GPU gate failed: nvidia-smi timed out or failed' ]
  grep -Fx 'timeout 15 nvidia-smi -L' "$COMMAND_LOG"
  ! grep -Fq switcherooctl "$COMMAND_LOG"
}

@test "failed one-shot writes diagnostics without enabling GDM or rebooting" {
  local marker="$BATS_TEST_TMPDIR/state/gpu-gate-passed"
  local log="$BATS_TEST_TMPDIR/blade-gpu-firstboot.log"
  local tty="$BATS_TEST_TMPDIR/tty1"

  materialize_gpu_fixture missing-nvidia-drm
  make_fake_commands
  run env GPU_LIB="$GPU_LIB" GPU_GATE_MARKER="$marker" \
    GPU_GATE_LOG="$log" TTY_PATH="$tty" "$GPU_EXEC"

  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
  grep -Fx 'systemctl disable blade-firstboot-gpu.service' "$COMMAND_LOG"
  ! grep -Eq '^systemctl (enable gdm|set-default)|^reboot ' "$COMMAND_LOG"
  grep -Fx 'GPU gate failed: required module not loaded: nvidia_drm' "$log"
  grep -Fq 'Diagnostics:' "$tty"
  grep -Fq 'Intel-only recovery' "$tty"
}

@test "successful one-shot enables GDM and requests exactly one reboot" {
  local marker="$BATS_TEST_TMPDIR/state/gpu-gate-passed"
  local log="$BATS_TEST_TMPDIR/blade-gpu-firstboot.log"
  local tty="$BATS_TEST_TMPDIR/tty1"

  materialize_gpu_fixture intel-panel
  make_fake_commands
  run env GPU_LIB="$GPU_LIB" GPU_GATE_MARKER="$marker" \
    GPU_GATE_LOG="$log" TTY_PATH="$tty" "$GPU_EXEC"

  [ "$status" -eq 0 ]
  [ -f "$marker" ]
  grep -Fx 'systemctl enable gdm.service' "$COMMAND_LOG"
  grep -Fx 'systemctl set-default graphical.target' "$COMMAND_LOG"
  grep -Fx 'systemctl disable blade-firstboot-gpu.service' "$COMMAND_LOG"
  [ "$(grep -c '^reboot $' "$COMMAND_LOG")" -eq 1 ]
}

@test "unwritable success marker fails before enabling GDM or rebooting" {
  local marker_parent="$BATS_TEST_TMPDIR/not-a-directory"
  local marker="$marker_parent/gpu-gate-passed"
  local log="$BATS_TEST_TMPDIR/blade-gpu-firstboot.log"
  local tty="$BATS_TEST_TMPDIR/tty1"

  materialize_gpu_fixture intel-panel
  make_fake_commands
  printf 'blocked\n' >"$marker_parent"
  run env GPU_LIB="$GPU_LIB" GPU_GATE_MARKER="$marker" \
    GPU_GATE_LOG="$log" TTY_PATH="$tty" "$GPU_EXEC"

  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
  ! grep -Eq '^systemctl (enable gdm|set-default graphical)|^reboot ' "$COMMAND_LOG"
  grep -Fx 'GPU gate failed: unable to prepare success marker' "$log"
}

@test "service starts from multi-user without a dependency cycle or retry loop" {
  local service="$REPO_ROOT/src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service"

  grep -Fx 'Type=oneshot' "$service"
  grep -Fx 'ExecStart=/usr/local/sbin/blade-firstboot-gpu' "$service"
  grep -Fx 'WantedBy=multi-user.target' "$service"
  ! grep -Eq '^After=.*multi-user\.target' "$service"
  ! grep -Eq '^Restart=' "$service"
}

@test "shared installed-system configuration remains exact" {
  local target="$REPO_ROOT/src/target-rootfs/etc"

  [ "$(<"$target/zram-generator.conf")" = $'[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = lz4\nswap-priority = 100' ]
  [ "$(<"$target/modprobe.d/nvidia.conf")" = 'options nvidia_drm modeset=1 fbdev=1' ]
  [ "$(<"$target/mkinitcpio.conf.d/graphics.conf")" = 'MODULES=(i915)' ]
  [ "$(<"$target/sudoers.d/10-wheel")" = '%wheel ALL=(ALL:ALL) ALL' ]
}
