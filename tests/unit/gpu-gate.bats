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
  SYSTEMD_ETC="$BATS_TEST_TMPDIR/systemd/etc/systemd/system"
  SYSTEMD_UNIT_DIR="$BATS_TEST_TMPDIR/systemd/usr/lib/systemd/system"
  mkdir -p "$FAKE_BIN" "$SYSTEMD_ETC/multi-user.target.wants" \
    "$SYSTEMD_ETC/graphical.target.wants" "$SYSTEMD_UNIT_DIR"
  touch "$SYSTEMD_UNIT_DIR/multi-user.target" \
    "$SYSTEMD_UNIT_DIR/graphical.target" \
    "$SYSTEMD_UNIT_DIR/gdm.service" \
    "$SYSTEMD_UNIT_DIR/blade-firstboot-gpu.service"
  ln -s "$SYSTEMD_UNIT_DIR/multi-user.target" "$SYSTEMD_ETC/default.target"
  ln -s "$SYSTEMD_UNIT_DIR/blade-firstboot-gpu.service" \
    "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service"
  cat >"$FAKE_BIN/tool" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >>"$COMMAND_LOG"

command_should_fail() {
  local candidate

  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$*" == "$candidate" ]] && return 0
  done <<<"${FAIL_SYSTEMCTL_COMMANDS:-}"
  return 1
}

case "$tool" in
  timeout)
    command_name=${2##*/}
    case "$command_name" in
      nvidia-smi) exit "${NVIDIA_SMI_STATUS:-0}" ;;
      switcherooctl) exit "${SWITCHEROOCTL_STATUS:-0}" ;;
    esac
    ;;
  systemctl)
    command_should_fail "$@" && exit 1
    case "${1-}" in
      enable)
        case "${2-}" in
          gdm.service)
            ln -sfn "$SYSTEMD_UNIT_DIR/gdm.service" \
              "$SYSTEMD_ETC/display-manager.service"
            ;;
          blade-firstboot-gpu.service)
            ln -sfn "$SYSTEMD_UNIT_DIR/blade-firstboot-gpu.service" \
              "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service"
            ;;
        esac
        ;;
      disable)
        case "${2-}" in
          gdm.service)
            rm -f -- "$SYSTEMD_ETC/display-manager.service" \
              "$SYSTEMD_ETC/graphical.target.wants/gdm.service"
            ;;
          blade-firstboot-gpu.service)
            rm -f -- \
              "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service"
            ;;
        esac
        ;;
      set-default)
        ln -sfn "$SYSTEMD_UNIT_DIR/${2-}" "$SYSTEMD_ETC/default.target"
        ;;
      get-default)
        target=$(readlink "$SYSTEMD_ETC/default.target")
        printf '%s\n' "${target##*/}"
        ;;
      is-enabled)
        case "${2-}" in
          gdm.service)
            if [[ -L "$SYSTEMD_ETC/display-manager.service" ||
              -L "$SYSTEMD_ETC/graphical.target.wants/gdm.service" ]]; then
              printf 'enabled\n'
              exit 0
            fi
            ;;
          blade-firstboot-gpu.service)
            if [[ -L "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service" ]]; then
              printf 'enabled\n'
              exit 0
            fi
            ;;
        esac
        printf 'disabled\n'
        exit 1
        ;;
    esac
    ;;
  mv)
    destination=${!#}
    [[ -n "${FAIL_MV_DEST:-}" && "$destination" == "$FAIL_MV_DEST" ]] && exit 1
    /bin/mv "$@"
    ;;
  reboot)
    exit "${REBOOT_STATUS:-0}"
    ;;
esac
SCRIPT
  chmod +x "$FAKE_BIN/tool"
  for tool in modprobe timeout systemctl reboot mv; do
    ln -s tool "$FAKE_BIN/$tool"
  done

  MODPROBE_BIN="$FAKE_BIN/modprobe"
  TIMEOUT_BIN="$FAKE_BIN/timeout"
  NVIDIA_SMI_BIN=nvidia-smi
  SWITCHEROOCTL_BIN=switcherooctl
  SYSTEMCTL_BIN="$FAKE_BIN/systemctl"
  REBOOT_BIN="$FAKE_BIN/reboot"
  MV_BIN="$FAKE_BIN/mv"
  export COMMAND_LOG MODPROBE_BIN TIMEOUT_BIN NVIDIA_SMI_BIN
  export SWITCHEROOCTL_BIN SYSTEMCTL_BIN REBOOT_BIN MV_BIN
  export SYSTEMD_ETC SYSTEMD_UNIT_DIR
}

setup_wrapper_state() {
  SUCCESS_MARKER="$BATS_TEST_TMPDIR/state/gpu-gate-passed"
  FAILURE_MARKER="$BATS_TEST_TMPDIR/state/gpu-gate-failed"
  GPU_LOG="$BATS_TEST_TMPDIR/blade-gpu-firstboot.log"
  GPU_TTY="$BATS_TEST_TMPDIR/tty1"
  GPU_GATE_MARKER=$SUCCESS_MARKER
  GPU_GATE_SUCCESS_MARKER=$SUCCESS_MARKER
  GPU_GATE_FAILURE_MARKER=$FAILURE_MARKER
  GPU_GATE_LOG=$GPU_LOG
  TTY_PATH=$GPU_TTY
  export GPU_GATE_MARKER GPU_GATE_SUCCESS_MARKER GPU_GATE_FAILURE_MARKER
  export GPU_GATE_LOG TTY_PATH
}

run_gpu_exec() {
  env GPU_LIB="$GPU_LIB" \
    FAIL_SYSTEMCTL_COMMANDS="${FAIL_SYSTEMCTL_COMMANDS:-}" \
    FAIL_MV_DEST="${FAIL_MV_DEST:-}" \
    "$GPU_EXEC"
}

assert_failed_terminal_state() {
  local default_target

  [ -f "$FAILURE_MARKER" ]
  [ ! -e "$SUCCESS_MARKER" ]
  default_target=$(readlink "$SYSTEMD_ETC/default.target")
  [ "${default_target##*/}" = multi-user.target ]
  [ ! -L "$SYSTEMD_ETC/display-manager.service" ]
  [ ! -L "$SYSTEMD_ETC/graphical.target.wants/gdm.service" ]
  [ ! -L "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service" ]
  ! grep -Eq '^systemctl enable blade-firstboot-gpu\.service|^reboot ' "$COMMAND_LOG"
}

assert_manual_recovery_instructions() {
  grep -Fq "sudo rm -f -- $FAILURE_MARKER" "$GPU_TTY"
  grep -Fq 'sudo systemctl set-default multi-user.target' "$GPU_TTY"
  grep -Fq 'sudo systemctl disable gdm.service' "$GPU_TTY"
  grep -Fq 'sudo systemctl enable blade-firstboot-gpu.service' "$GPU_TTY"
  grep -Fq 'sudo systemctl start blade-firstboot-gpu.service' "$GPU_TTY"
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
  local containment_line
  local marker_line

  materialize_gpu_fixture missing-nvidia-drm
  make_fake_commands
  setup_wrapper_state
  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fx 'GPU gate failed: required module not loaded: nvidia_drm' "$GPU_LOG"
  assert_manual_recovery_instructions
  marker_line=$(grep -nF " $FAILURE_MARKER" "$COMMAND_LOG" | head -n1 | cut -d: -f1)
  containment_line=$(grep -nF 'systemctl set-default multi-user.target' \
    "$COMMAND_LOG" | head -n1 | cut -d: -f1)
  [ -n "$marker_line" ]
  [ -n "$containment_line" ]
  [ "$marker_line" -lt "$containment_line" ]
}

@test "successful one-shot enables GDM and requests exactly one reboot" {
  local default_target
  local marker_line
  local reboot_line
  local verify_line

  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  run run_gpu_exec

  [ "$status" -eq 0 ]
  [ -f "$SUCCESS_MARKER" ]
  [ ! -e "$FAILURE_MARKER" ]
  default_target=$(readlink "$SYSTEMD_ETC/default.target")
  [ "${default_target##*/}" = graphical.target ]
  [ -L "$SYSTEMD_ETC/display-manager.service" ]
  [ ! -L "$SYSTEMD_ETC/multi-user.target.wants/blade-firstboot-gpu.service" ]
  grep -Fx 'systemctl enable gdm.service' "$COMMAND_LOG"
  grep -Fx 'systemctl set-default graphical.target' "$COMMAND_LOG"
  grep -Fx 'systemctl disable blade-firstboot-gpu.service' "$COMMAND_LOG"
  [ "$(grep -c '^reboot $' "$COMMAND_LOG")" -eq 1 ]
  marker_line=$(grep -nF " $SUCCESS_MARKER" "$COMMAND_LOG" | tail -n1 | cut -d: -f1)
  verify_line=$(grep -nF 'systemctl get-default' "$COMMAND_LOG" | tail -n1 | cut -d: -f1)
  reboot_line=$(grep -nF 'reboot ' "$COMMAND_LOG" | tail -n1 | cut -d: -f1)
  [ -n "$marker_line" ]
  [ -n "$verify_line" ]
  [ -n "$reboot_line" ]
  [ "$marker_line" -lt "$verify_line" ]
  [ "$verify_line" -lt "$reboot_line" ]
}

@test "unwritable success marker fails before enabling GDM or rebooting" {
  local marker_parent="$BATS_TEST_TMPDIR/not-a-directory"
  local marker="$marker_parent/gpu-gate-passed"

  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  SUCCESS_MARKER=$marker
  GPU_GATE_MARKER=$marker
  GPU_GATE_SUCCESS_MARKER=$marker
  export GPU_GATE_MARKER GPU_GATE_SUCCESS_MARKER
  printf 'blocked\n' >"$marker_parent"
  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  ! grep -Eq '^systemctl (enable gdm|set-default graphical)' "$COMMAND_LOG"
  grep -Fx 'GPU gate failed: unable to prepare success marker' "$GPU_LOG"
}

@test "GDM enable failure enters the persistent fail-closed terminal" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS='enable gdm.service'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
}

@test "graphical default failure enters the persistent fail-closed terminal" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS='set-default graphical.target'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
}

@test "gate disable failure uses direct cleanup and cannot retry" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS='disable blade-firstboot-gpu.service'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fq 'Containment command failed: disable blade-firstboot-gpu.service' "$GPU_LOG"
  grep -Fq 'Containment fallback removed gate enablement symlink' "$GPU_LOG"
}

@test "GDM disable failure uses direct cleanup and remains fail-closed" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS=$'set-default graphical.target\ndisable gdm.service'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fq 'Containment command failed: disable gdm.service' "$GPU_LOG"
  grep -Fq 'Containment fallback removed GDM enablement symlink' "$GPU_LOG"
}

@test "success marker publication failure rolls back without reboot" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_MV_DEST=$SUCCESS_MARKER

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fq 'GPU gate failed: unable to publish success marker' "$GPU_LOG"
}

@test "rollback set-default failure uses a direct multi-user fallback" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS=$'disable blade-firstboot-gpu.service\nset-default multi-user.target'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fq 'Containment command failed: set-default multi-user.target' "$GPU_LOG"
  grep -Fq 'Containment fallback set default.target to multi-user.target' "$GPU_LOG"
}

@test "success-state verification failure rolls back without reboot" {
  materialize_gpu_fixture intel-panel
  make_fake_commands
  setup_wrapper_state
  FAIL_SYSTEMCTL_COMMANDS='get-default'

  run run_gpu_exec

  [ "$status" -ne 0 ]
  assert_failed_terminal_state
  grep -Fq 'GPU gate failed: success state verification failed' "$GPU_LOG"
}

@test "service starts from multi-user without a dependency cycle or retry loop" {
  local service="$REPO_ROOT/src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service"

  grep -Fx 'Type=oneshot' "$service"
  grep -Fx 'ExecStart=/usr/local/sbin/blade-firstboot-gpu' "$service"
  grep -Fx 'ConditionPathExists=!/var/lib/blade-installer/gpu-gate-passed' "$service"
  grep -Fx 'ConditionPathExists=!/var/lib/blade-installer/gpu-gate-failed' "$service"
  grep -Fx 'WantedBy=multi-user.target' "$service"
  ! grep -Eq '^After=.*multi-user\.target' "$service"
  ! grep -Eq '^Restart=' "$service"
  ! grep -Fq '|| true' "$GPU_EXEC"
}

@test "shared installed-system configuration remains exact" {
  local target="$REPO_ROOT/src/target-rootfs/etc"

  [ "$(<"$target/zram-generator.conf")" = $'[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = lz4\nswap-priority = 100' ]
  [ "$(<"$target/modprobe.d/nvidia.conf")" = 'options nvidia_drm modeset=1 fbdev=1' ]
  [ "$(<"$target/mkinitcpio.conf.d/graphics.conf")" = 'MODULES=(i915)' ]
  [ "$(<"$target/sudoers.d/10-wheel")" = '%wheel ALL=(ALL:ALL) ALL' ]
}

@test "extensionless first-boot executable retains Unix line endings" {
  grep -Fx \
    'src/target-rootfs/usr/local/sbin/blade-firstboot-gpu text eol=lf' \
    "$REPO_ROOT/.gitattributes"
}
