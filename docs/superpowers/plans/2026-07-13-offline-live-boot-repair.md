# Offline Live-Boot Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a replacement Razer Blade Arch installer ISO that boots and installs without Ethernet while retaining safe copy-to-RAM disk exclusion.

**Architecture:** Embed one canonical runtime settings file and load it through a shared helper. Give each boot route explicit systemd ownership arguments, and extend boot-medium discovery with a fail-closed `archisosearchuuid` fallback for Archiso's copy-to-RAM path. Require these behaviors in unit, prepared-profile, extracted-artifact, and positive boot gates before artifact eligibility.

**Tech Stack:** Bash, Bats, Archiso, systemd, `lsblk`, `findmnt`, `blkid`, GRUB, Syslinux, QEMU/OVMF, GitHub Actions.

## Global Constraints

- Physical installation requires no Ethernet, Wi-Fi, mirror, or NTP access.
- Preserve copy-to-RAM for the target laptop when Archiso selects it.
- Refuse ambiguous boot-media identity and fail before listing a target.
- Keep the physical rescue tty available.
- Do not modify a disk before exact `WIPE` confirmation.
- Do not embed passwords, Wi-Fi credentials, or Codex session data.

---

### Task 1: Runtime configuration packaging

**Files:**
- Modify: `src/installer/lib/common.sh`
- Modify: `src/installer/lib/preflight.sh`
- Modify: `src/installer/lib/identity.sh`
- Modify: `src/installer/lib/install.sh`
- Modify: `scripts/prepare-archiso.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `tests/unit/build-scripts.bats`
- Modify: `tests/unit/config.bats`

**Interfaces:**
- Produces: `load_installer_config SOURCE_TREE_PATH` and `/usr/share/blade-installer/build.env`.

- [ ] **Step 1: Write failing tests** that prepare a profile and require the canonical file, source installed-layout libraries with an empty environment, and reject a missing canonical file.
- [ ] **Step 2: Run the focused Bats tests** and confirm failure is caused by the absent loader/artifact.
- [ ] **Step 3: Implement the shared loader and profile staging** with override, canonical, and source-tree precedence; retain required-variable assertions.
- [ ] **Step 4: Extend extracted-artifact verification** to validate the regular file, mode, and required values.
- [ ] **Step 5: Re-run the focused tests** and confirm they pass.

### Task 2: Copy-to-RAM boot-medium discovery

**Files:**
- Modify: `src/installer/lib/disks.sh`
- Modify: `src/installer/blade-install`
- Modify: `tests/unit/disks.bats`
- Add: `tests/fixtures/cmdline-copytoram.txt`

**Interfaces:**
- Produces: `_live_root_source` fallback using `CMDLINE_FILE` and `BLKID_BIN`; `boot_disk` continues returning a whole-disk path.

- [ ] **Step 1: Write failing tests** for missing bootmnt plus one UUID match, duplicate cmdline tokens, malformed UUIDs, zero matches, and multiple matches.
- [ ] **Step 2: Run `tests/unit/disks.bats`** and verify the copy-to-RAM case fails with the current `findmnt`-only implementation.
- [ ] **Step 3: Implement exact token parsing and unique `blkid` resolution**, validate the result against current `lsblk` data, and preserve the existing parent walk.
- [ ] **Step 4: Add `blkid` to installer preflight requirements** and keep `assert_safe_target` rechecking immediately before partitioning.
- [ ] **Step 5: Re-run disk and orchestrator tests** and confirm all cases pass.

### Task 3: Offline and tty route ownership

**Files:**
- Modify: `scripts/prepare-archiso.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `tests/unit/build-scripts.bats`

**Interfaces:**
- Produces: a shared offline time-wait mask on all live routes and a tty1-getty mask only on the normal physical installer route.

- [ ] **Step 1: Add failing prepared-profile tests** requiring the time-wait mask everywhere, the tty1 mask on the default physical route, and no tty1 mask on rescue/QEMU routes.
- [ ] **Step 2: Run the focused test** and confirm the current boot entries fail these requirements.
- [ ] **Step 3: Split shared safe arguments from physical-installer-only arguments** and patch GRUB and Syslinux route generation accordingly.
- [ ] **Step 4: Extend artifact route parsing** so misplaced, missing, duplicate, and near-match mask tokens are rejected.
- [ ] **Step 5: Re-run focused boot-entry tests** and confirm rescue semantics remain intact.

### Task 4: Artifact eligibility and positive startup gate

**Files:**
- Modify: `tests/integration/qemu-boot.sh`
- Modify: `tests/integration/qemu-boot.exp`
- Modify: `scripts/ci-build.sh`
- Modify: `tests/unit/build-scripts.bats`

**Interfaces:**
- Produces: a positive installer-startup/cancel command that completes before `dist/.verified` is created.

- [ ] **Step 1: Add failing workflow/script tests** requiring a positive safe-start gate before the verified marker and rejecting missing runtime variables in serial output.
- [ ] **Step 2: Run focused tests** and confirm marker ordering currently fails.
- [ ] **Step 3: Split or parameterize the QEMU harness** so positive installer startup reaches target selection and cancels at the `WIPE` prompt independently of later negative-route checks.
- [ ] **Step 4: Move `.verified` creation after artifact verification and the deterministic positive gate**, retaining later defense-in-depth checks.
- [ ] **Step 5: Re-run harness unit tests** and confirm marker ordering and failure propagation.

### Task 5: Full verification and replacement artifact

**Files:**
- Modify: `README.md` if operator instructions or recovery commands changed.

**Interfaces:**
- Produces: committed/pushed source plus a locally downloaded ISO, SHA-256 sidecar, and build manifest.

- [ ] **Step 1: Run the complete static/unit suite** and require zero failures.
- [ ] **Step 2: Review the diff for destructive-safety regressions**, secrets, unrelated changes, and exact route semantics.
- [ ] **Step 3: Commit and push the repair**, dispatch the GitHub Actions ISO build, and monitor at milestone intervals.
- [ ] **Step 4: Require rootfs, loop-install, ISO, artifact, and positive-startup gates** before accepting the artifact.
- [ ] **Step 5: Download and extract the artifact locally**, compute SHA-256 afresh, compare it to the sidecar, and report the exact absolute ISO path.
