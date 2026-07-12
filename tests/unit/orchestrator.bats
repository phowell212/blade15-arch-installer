#!/usr/bin/env bats

setup() {
  BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}/blade-orchestrator-bats.$$.$BATS_TEST_NUMBER}"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR"
}

teardown() {
  rm -rf -- "$BATS_TEST_TMPDIR"
}

@test "orchestrator executes the approved phases in order" {
  local trace="$BATS_TEST_TMPDIR/phases"

  run env PHASE_TRACE="$trace" bash -c '
    source "$1"
    record() { printf "%s\n" "$1" >>"$PHASE_TRACE"; }
    _phase_preflight() { record preflight; }
    _phase_select() { record select; }
    _phase_identity() { record identity; }
    _phase_summary() { record summary; }
    _phase_wipe() { record wipe; }
    _phase_partition() { record partition; }
    _phase_extract() { record extract; }
    _phase_configure() { record configure; }
    _phase_validate() { record validate; }
    _phase_sync_unmount() { record sync-unmount; }
    _phase_finish() { record finish; }
    main
  ' _ "$REPO_ROOT/src/installer/blade-install"
  [ "$status" -eq 0 ]
  [ "$(<"$trace")" = $'preflight\nselect\nidentity\nsummary\nwipe\npartition\nextract\nconfigure\nvalidate\nsync-unmount\nfinish' ]
}

@test "failure handler syncs reports the phase and exits without a non-tty shell" {
  local fake_sync="$BATS_TEST_TMPDIR/sync"
  local sync_log="$BATS_TEST_TMPDIR/sync.log"
  cat >"$fake_sync" <<'SCRIPT'
#!/usr/bin/env bash
printf 'sync\n' >>"$SYNC_LOG"
SCRIPT
  chmod +x "$fake_sync"

  run env SYNC_BIN="$fake_sync" SYNC_LOG="$sync_log" bash -c '
    source "$1"
    CURRENT_PHASE=extract
    installer_failure 23
  ' _ "$REPO_ROOT/src/installer/blade-install"
  [ "$status" -eq 23 ]
  [[ "$output" == *"Installation failed during extract"* ]]
  [ "$(<"$sync_log")" = sync ]
}

@test "orchestrator installs the common failure handler for ERR and EXIT" {
  grep -Fq 'trap '\''installer_failure "$?"'\'' ERR EXIT' \
    "$REPO_ROOT/src/installer/blade-install"
}

@test "tty service is bounded and never restarts normal prompt exits" {
  local service="$REPO_ROOT/src/live-rootfs/etc/systemd/system/blade-installer.service"

  grep -Fx 'Conflicts=getty@tty1.service' "$service"
  grep -Fx 'ConditionKernelCommandLine=!blade.noinstaller=1' "$service"
  grep -Fx 'StartLimitBurst=2' "$service"
  grep -Fx 'StandardInput=tty' "$service"
  grep -Fx 'TTYPath=/dev/tty1' "$service"
  grep -Fx 'TTYReset=yes' "$service"
  grep -Fx 'Restart=on-abnormal' "$service"
  ! grep -Eq '^Restart=(always|on-failure)$' "$service"
  ! grep -Fq 'network-online.target' "$service"
}
