# Razer Blade 15 Arch GNOME Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, publish, and verify a flashable offline Arch Linux installer ISO for the Razer Blade 15 RZ09-0421NEC3 with GNOME, hybrid Intel/RTX 3070 Ti graphics, `yay`, and Codex CLI.

**Architecture:** An `archiso` live environment boots only to a defensive text installer. GitHub Actions builds a separate preconfigured root filesystem, embeds it as a compressed payload, tests the installer and first-boot GPU gate, builds the ISO, and publishes the ISO, checksum, and manifest as one artifact.

**Tech Stack:** Arch Linux, archiso, Bash, Bats, systemd, systemd-boot, pacman/pacstrap, zstd, QEMU/OVMF, GitHub Actions, NVIDIA open kernel modules.

## Global Constraints

- Supported physical target: Razer Blade 15 product family `RZ09-0421`; intended variant `RZ09-0421NEC3`.
- UEFI only; refuse installation when Secure Boot is enabled.
- Destructive disk work requires a displayed whole-disk target and exact case-sensitive `WIPE` confirmation.
- Partition layout: 1 GiB FAT32 EFI System Partition at `/boot`; remaining space unencrypted `ext4` at `/`.
- No LUKS, hibernation, disk swap, separate `/home`, or automatic login.
- zram: `lz4`, maximum 8 GiB, high swap priority.
- The live installer must not start GNOME or load nouveau/NVIDIA modules.
- The installed desktop must dynamically support either Intel-routed Optimus or NVIDIA-routed Advanced Optimus without a static `xorg.conf`.
- GDM remains disabled until the text-mode first-boot GPU gate succeeds.
- Codex release `0.144.1` is preinstalled globally, but no Codex credentials are embedded.
- `yay` is built unprivileged from AUR commit `cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0`.
- Locale `en_US.UTF-8`, US keymap, timezone `America/New_York`, default hostname `blade15`.
- Generated images, root filesystems, package caches, secrets, and test disks remain untracked.

## File Map

- `config/build.env`: pinned project, hardware, AUR, and Codex build inputs.
- `config/pacman-target.conf`: official repositories plus multilib for target construction.
- `packages/live.txt`: packages required by the text installer.
- `packages/target.txt`: full installed-system package and group list.
- `src/installer/blade-install`: interactive phase orchestrator.
- `src/installer/lib/common.sh`: logging, error, command-line, and secret-safe helpers.
- `src/installer/lib/preflight.sh`: UEFI, Secure Boot, DMI, and payload checks.
- `src/installer/lib/disks.sh`: boot-media exclusion, candidate discovery, and target safety.
- `src/installer/lib/identity.sh`: hostname, username, and password collection.
- `src/installer/lib/install.sh`: partition, extract, target configure, bootloader, and validation phases.
- `src/live-rootfs/etc/systemd/system/blade-installer.service`: starts installer on tty1.
- `src/target-rootfs/etc/*`: locale, zram, modprobe, sudo, and system configuration.
- `src/target-rootfs/usr/local/sbin/blade-firstboot-gpu`: first-boot gate orchestrator.
- `src/target-rootfs/usr/local/lib/blade-firstboot/gpu.sh`: GPU topology and module checks.
- `src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service`: keeps GDM gated.
- `scripts/build-yay.sh`: pinned unprivileged AUR build.
- `scripts/build-rootfs.sh`: creates configured target root filesystem and payload.
- `scripts/prepare-archiso.sh`: overlays installer and payload onto official releng profile.
- `scripts/build-iso.sh`: builds and names the ISO and checksum.
- `scripts/verify-artifacts.sh`: verifies payload, ISO, manifests, and checksums.
- `tests/unit/*.bats`: pure validation and generated-config tests.
- `tests/integration/*.sh`: loop-disk and QEMU/OVMF tests.
- `.github/workflows/build-iso.yml`: online static, privileged build, test, and artifact workflow.
- `README.md`: build, download, checksum, Rufus, install, first-boot, and recovery instructions.

---

### Task 1: Establish the Testable Project Contract

**Files:**
- Create: `.editorconfig`
- Create: `.gitattributes`
- Modify: `.gitignore`
- Create: `Makefile`
- Create: `config/build.env`
- Create: `config/pacman-target.conf`
- Create: `packages/live.txt`
- Create: `packages/target.txt`
- Create: `tests/unit/config.bats`

**Interfaces:**
- Consumes: design constraints only.
- Produces: shell variables `PROJECT_SLUG`, `TARGET_DMI_FAMILY`, `CODEX_RELEASE`, `YAY_AUR_COMMIT`, `ZRAM_MAX_MIB`, `DEFAULT_HOSTNAME`, and package lists used by every later task.

- [ ] **Step 1: Write the failing configuration test**

```bash
#!/usr/bin/env bats

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "build inputs are pinned and safe" {
  run bash -eu -c '. "$1/config/build.env"; printf "%s\n" "$TARGET_DMI_FAMILY|$CODEX_RELEASE|$YAY_AUR_COMMIT|$ZRAM_MAX_MIB"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'RZ09-0421|0.144.1|cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0|8192' ]
}

@test "target list contains required desktop and GPU packages" {
  for package in gnome gdm networkmanager nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime switcheroo-control bubblewrap; do
    run grep -Fx "$package" "$REPO_ROOT/packages/target.txt"
    [ "$status" -eq 0 ]
  done
}
```

- [ ] **Step 2: Run the test and verify it fails because files do not exist**

Run: `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Users/Phineas/Documents/Codex/2026-07-11/codex-on-linux-setup-chatgpt-conversation && bats tests/unit/config.bats'`

Expected: FAIL referencing `config/build.env` or `packages/target.txt`.

- [ ] **Step 3: Add exact build inputs and package manifests**

`config/build.env`:

```bash
PROJECT_SLUG=blade15-arch-gnome
TARGET_DMI_VENDOR=Razer
TARGET_DMI_FAMILY=RZ09-0421
CODEX_RELEASE=0.144.1
YAY_AUR_COMMIT=cb43f84828ab4f9700f7c6f9c6d7a923d4cfaff0
ZRAM_MAX_MIB=8192
DEFAULT_HOSTNAME=blade15
DEFAULT_TIMEZONE=America/New_York
```

`config/pacman-target.conf` enables `[core]`, `[extra]`, and `[multilib]` with `SigLevel = Required DatabaseOptional` and the standard mirror list. `packages/target.txt` contains these exact entries, one per line:

```text
base
base-devel
linux
linux-firmware
intel-ucode
sudo
efibootmgr
dosfstools
e2fsprogs
gptfdisk
networkmanager
gnome
gdm
pipewire
pipewire-alsa
pipewire-pulse
wireplumber
mesa
vulkan-intel
intel-media-driver
libva-utils
nvidia-open
nvidia-utils
lib32-nvidia-utils
egl-wayland
nvidia-prime
switcheroo-control
xorg-xwayland
zram-generator
lz4
power-profiles-daemon
thermald
git
openssh
ripgrep
fd
curl
wget
firefox
bubblewrap
pciutils
usbutils
dmidecode
jq
nano
vim
man-db
man-pages
bash-completion
```

The rootfs builder installs `yay` separately from the locally built package after the official package transaction. `packages/live.txt` contains `arch-install-scripts`, `bash`, `coreutils`, `dosfstools`, `e2fsprogs`, `gptfdisk`, `util-linux`, `pciutils`, `dmidecode`, `efibootmgr`, `zstd`, `jq`, and `pv`.

- [ ] **Step 4: Add deterministic editor, line-ending, ignore, and test targets**

`Makefile` exposes `unit`, `static`, `integration`, `build`, and `verify`; each target calls one script and fails on the first error. `.gitattributes` forces `*.sh`, `*.bats`, `*.yml`, `*.yaml`, `*.conf`, and `Makefile` to LF. `.gitignore` adds `/build/`, `/dist/`, `*.iso`, `*.img`, `*.qcow2`, and `*.tar.zst`.

- [ ] **Step 5: Run the configuration test**

Run: `bats tests/unit/config.bats`

Expected: `2 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add .editorconfig .gitattributes .gitignore Makefile config packages tests/unit/config.bats
git commit -m "build: define installer inputs and package sets"
```

---

### Task 2: Implement Non-Destructive Safety and Identity Logic

**Files:**
- Create: `src/installer/lib/common.sh`
- Create: `src/installer/lib/preflight.sh`
- Create: `src/installer/lib/disks.sh`
- Create: `src/installer/lib/identity.sh`
- Create: `tests/unit/preflight.bats`
- Create: `tests/unit/disks.bats`
- Create: `tests/unit/identity.bats`
- Create: `tests/fixtures/lsblk-two-disks.json`

**Interfaces:**
- Consumes: `TARGET_DMI_VENDOR`, `TARGET_DMI_FAMILY`, `DEFAULT_HOSTNAME`.
- Produces: `die(message)`, `cmdline_has(flag)`, `require_supported_platform()`, `boot_disk()`, `candidate_disks()`, `assert_safe_target(device)`, `valid_hostname(value)`, `valid_username(value)`, and `require_wipe_confirmation(value)`.

- [ ] **Step 1: Write failing tests for platform gates**

```bash
@test "physical install requires UEFI" {
  UEFI_PATH="$BATS_TEST_TMPDIR/missing" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *UEFI* ]]
}

@test "enabled Secure Boot is rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/efi"
  UEFI_PATH="$BATS_TEST_TMPDIR/efi" SECURE_BOOT_VALUE=1 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *Secure\ Boot* ]]
}

@test "exact Razer family is accepted" {
  mkdir -p "$BATS_TEST_TMPDIR/efi"
  UEFI_PATH="$BATS_TEST_TMPDIR/efi" SECURE_BOOT_VALUE=0 DMI_VENDOR=Razer DMI_PRODUCT='Blade 15 RZ09-0421'
  run require_supported_platform
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Write failing disk and identity tests**

Tests inject `LSBLK_JSON_FILE` and `LIVE_ROOT_SOURCE=/dev/sdb1`; they assert `/dev/sdb` is excluded, `/dev/nvme0n1` is returned, partitions such as `/dev/nvme0n1p1` are rejected, mounted targets are rejected, only exact `WIPE` passes, usernames match `^[a-z_][a-z0-9_-]{0,31}$`, and hostnames match RFC-style labels without leading/trailing hyphens.

- [ ] **Step 3: Run tests and verify missing functions fail**

Run: `bats tests/unit/preflight.bats tests/unit/disks.bats tests/unit/identity.bats`

Expected: FAIL with `command not found` for the new interfaces.

- [ ] **Step 4: Implement secret-safe common helpers and platform checks**

`common.sh` starts with `set -Eeuo pipefail`, forcibly disables xtrace with `set +x`, writes timestamped messages through `log`, and implements `die` as `printf` to stderr followed by `exit 1`. `preflight.sh` uses injectable environment variables in tests and `/sys/firmware/efi`, `bootctl status`, and `/sys/class/dmi/id/*` in production. A test bypass is permitted only when both DMI identifies QEMU/KVM and `/proc/cmdline` contains `blade.test=1`.

- [ ] **Step 5: Implement disk ancestry and candidate filtering**

Use `findmnt -nro SOURCE /run/archiso/bootmnt` and repeated `lsblk -ndo PKNAME` to resolve the whole boot disk. Parse `lsblk --json --bytes --output NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,RM,MOUNTPOINTS`. Accept only `type=disk`, `rm=false`, no mountpoints outside the live ISO, and a path different from the boot disk. `assert_safe_target` re-runs these checks immediately before partitioning to close the selection/use race.

- [ ] **Step 6: Implement strict identity and confirmation functions**

`valid_hostname`, `valid_username`, and `require_wipe_confirmation` return success/failure without printing secrets. Password collection uses `read -r -s`, compares two entries, requires at least eight characters, never exports them, and clears both variables after the chrooted `chpasswd` call.

- [ ] **Step 7: Run unit and static tests**

Run: `bats tests/unit/preflight.bats tests/unit/disks.bats tests/unit/identity.bats && shellcheck src/installer/lib/*.sh`

Expected: all tests pass; ShellCheck exits 0.

- [ ] **Step 8: Commit**

```bash
git add src/installer/lib tests/unit tests/fixtures
git commit -m "feat: add installer safety gates"
```

---

### Task 3: Implement the Confirmed-Wipe Offline Installer

**Files:**
- Create: `src/installer/lib/install.sh`
- Create: `src/installer/blade-install`
- Create: `src/live-rootfs/etc/systemd/system/blade-installer.service`
- Create: `tests/unit/generated-config.bats`
- Create: `tests/integration/loop-install.sh`

**Interfaces:**
- Consumes: Task 2 safety/identity functions and `/usr/share/blade-installer/rootfs.tar.zst`.
- Produces: `partition_target(device)`, `extract_target(device)`, `write_target_config(root, user, hostname)`, `install_systemd_boot(root, root_uuid)`, `verify_target(root)`, and executable `blade-install`.

- [ ] **Step 1: Write failing generated-configuration tests**

Tests call writers against a temporary directory and assert:

```text
/boot  vfat  defaults,noatime  0  2
/      ext4  defaults,noatime  0  1
```

by UUID; loader timeout is 10 seconds; normal options contain `nvidia_drm.modeset=1`; Intel recovery blacklists the four NVIDIA modules; text recovery contains `systemd.unit=multi-user.target`; `/etc/crypttab` is absent; and `/etc/zram-generator.conf` requests `lz4`, `ram / 2`, and `8192` MiB maximum.

- [ ] **Step 2: Run tests and verify missing writers fail**

Run: `bats tests/unit/generated-config.bats`

Expected: FAIL with `write_target_config: command not found`.

- [ ] **Step 3: Implement partition and extraction phases**

`partition_target` performs only these operations after `assert_safe_target` and `WIPE`: `wipefs --all`, `sgdisk --zap-all`, `sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI`, `sgdisk -n 2:0:0 -t 2:8304 -c 2:ARCHROOT`, `partprobe`, `udevadm settle`, `mkfs.fat -F 32`, and `mkfs.ext4 -F -L ARCHROOT`. It mounts root at `/mnt` and EFI at `/mnt/boot`.

`extract_target` verifies a sidecar SHA-256 before `zstd -dc ... | bsdtar --acls --xattrs --numeric-owner -xpf - -C /mnt`. Any failure triggers the common ERR trap, syncs, and leaves the live shell available.

- [ ] **Step 4: Implement generated target configuration**

Write `/etc/fstab`, locale/keymap/timezone symlink, hostname/hosts, sudo wheel rule, zram configuration, NVIDIA modprobe options, NetworkManager state, and three loader entries. Use `arch-chroot /mnt bootctl --esp-path=/boot install`, `arch-chroot /mnt mkinitcpio -P`, `systemctl --root=/mnt enable NetworkManager switcheroo-control power-profiles-daemon fstrim.timer blade-firstboot-gpu.service`, and keep `gdm.service` disabled.

- [ ] **Step 5: Implement the orchestrator and tty service**

`blade-install` runs `preflight -> select -> identity -> summary -> WIPE -> partition -> extract -> configure -> validate -> sync/unmount`. The service uses `StandardInput=tty`, `TTYPath=/dev/tty1`, `TTYReset=yes`, conflicts with `getty@tty1.service`, and restarts only on abnormal failure with a bounded two-attempt limit.

- [ ] **Step 6: Add a disposable loop-device integration test**

`tests/integration/loop-install.sh` requires root, creates a 6 GiB sparse image, attaches it with `losetup --partscan`, creates a minimal root payload, sets `BLADE_TEST_MODE=1`, invokes the same partition/extract/configure functions, and verifies GPT type GUIDs, FAT/ext4 labels, fstab UUIDs, loader entries, and absence of LUKS signatures. A trap always unmounts and detaches the loop device.

- [ ] **Step 7: Run unit, static, and loop integration tests**

Run: `bats tests/unit/generated-config.bats && shellcheck src/installer/blade-install src/installer/lib/*.sh tests/integration/loop-install.sh && sudo tests/integration/loop-install.sh`

Expected: all commands exit 0 and the integration test prints `loop install: PASS`.

- [ ] **Step 8: Commit**

```bash
git add src/installer src/live-rootfs tests
git commit -m "feat: add confirmed-wipe offline installer"
```

---

### Task 4: Implement Installed-System Configuration and GPU Gate

**Files:**
- Create: `src/target-rootfs/etc/zram-generator.conf`
- Create: `src/target-rootfs/etc/modprobe.d/nvidia.conf`
- Create: `src/target-rootfs/etc/mkinitcpio.conf.d/graphics.conf`
- Create: `src/target-rootfs/etc/sudoers.d/10-wheel`
- Create: `src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service`
- Create: `src/target-rootfs/usr/local/lib/blade-firstboot/gpu.sh`
- Create: `src/target-rootfs/usr/local/sbin/blade-firstboot-gpu`
- Create: `tests/unit/gpu-gate.bats`

**Interfaces:**
- Consumes: real or fixture paths through `SYS_CLASS_DRM`, `SYS_MODULE`, `LSPCI_OUTPUT`, and command wrappers.
- Produces: `connected_internal_gpu()`, `check_required_pci()`, `check_modules()`, `check_drm_nodes()`, `check_nvidia_smi()`, `gpu_gate()`, and the one-shot executable.

- [ ] **Step 1: Write failing topology and success/failure tests**

Fixtures model (a) Intel `card1-eDP-1` connected with NVIDIA available for offload, (b) NVIDIA `card0-eDP-1` connected, (c) missing `nvidia_drm`, and (d) timed-out `nvidia-smi`. Tests assert both valid routes pass, failures return non-zero with a precise reason, and a failed gate never enables GDM.

- [ ] **Step 2: Run tests and verify they fail**

Run: `bats tests/unit/gpu-gate.bats`

Expected: FAIL because `gpu.sh` is absent.

- [ ] **Step 3: Implement GPU topology and bounded checks**

Resolve connected `eDP`/`LVDS` connector symlinks to their owning PCI device. Require Intel vendor `8086` and NVIDIA vendor `10de`, then `modprobe i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm`. Require `/sys/module/nvidia_drm/parameters/modeset` to be `Y`; run `timeout 15 nvidia-smi -L` and `timeout 15 switcherooctl list`.

- [ ] **Step 4: Implement the one-shot state transition**

On success, write `/var/lib/blade-installer/gpu-gate-passed`, enable GDM, set `graphical.target` as default, disable the gate service, and request one reboot. On failure, write `/var/log/blade-gpu-firstboot.log`, leave `multi-user.target` and GDM disabled, print recovery instructions to `/dev/tty1`, and exit non-zero without a restart loop.

- [ ] **Step 5: Add exact target configuration**

Configure zram as:

```ini
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = lz4
swap-priority = 100
```

Set `options nvidia_drm modeset=1 fbdev=1`; include `i915` in the initramfs module list while leaving NVIDIA for the gate/udev to load after the recovery choice has taken effect; mode `0440` for the sudoers file; and make first-boot executable files mode `0755`.

- [ ] **Step 6: Run tests and static validation**

Run: `bats tests/unit/gpu-gate.bats && shellcheck src/target-rootfs/usr/local/lib/blade-firstboot/gpu.sh src/target-rootfs/usr/local/sbin/blade-firstboot-gpu && systemd-analyze verify src/target-rootfs/etc/systemd/system/blade-firstboot-gpu.service`

Expected: all commands exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/target-rootfs tests/unit/gpu-gate.bats tests/fixtures
git commit -m "feat: gate GNOME on hybrid GPU validation"
```

---

### Task 5: Build the Offline Root Filesystem, yay, and Codex

**Files:**
- Create: `scripts/lib/build-common.sh`
- Create: `scripts/build-yay.sh`
- Create: `scripts/build-rootfs.sh`
- Create: `scripts/verify-rootfs.sh`
- Create: `tests/unit/build-scripts.bats`

**Interfaces:**
- Consumes: Task 1 configuration/package lists and Task 4 target overlay.
- Produces: `build/rootfs/`, `build/packages/yay-*.pkg.tar.zst`, `build/payload/rootfs.tar.zst`, `rootfs.tar.zst.sha256`, and `target-packages.txt`.

- [ ] **Step 1: Write failing dry-run and manifest tests**

Tests run each script with `BLADE_DRY_RUN=1` and assert the printed plan includes the pinned AUR commit, installs `yay` only after pacstrap, enables multilib, sets `CODEX_HOME=/opt/codex`, sets `CODEX_RELEASE=0.144.1`, installs to `/usr/local/bin`, and archives with ACL/xattr/numeric-owner preservation.

- [ ] **Step 2: Run tests and verify scripts are missing**

Run: `bats tests/unit/build-scripts.bats`

Expected: FAIL with file-not-found errors.

- [ ] **Step 3: Implement the pinned unprivileged yay build**

Clone `https://aur.archlinux.org/yay.git`, verify `git rev-parse HEAD` exactly matches the configured commit, create an unprivileged `builder` account in a clean Arch build environment, run `makepkg --syncdeps --cleanbuild --noconfirm`, and copy only the resulting `yay-*.pkg.tar.zst` into `build/packages`. Never execute `makepkg` as root.

- [ ] **Step 4: Implement target pacstrap and overlay**

Create a fresh root, run `pacstrap -C config/pacman-target.conf -K` with the complete official package list, install the local yay package with `pacman --root`, copy `src/target-rootfs`, generate locale and machine-independent configuration, and enable required services with `systemctl --root`. Clear package caches, logs, `/etc/machine-id`, SSH host keys, and temporary files before archiving.

- [ ] **Step 5: Install Codex globally without credentials**

Inside the target root, execute the official standalone installer with:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh -o "$BUILD_DIR/codex-install.sh"
arch-chroot "$ROOT" /usr/bin/env \
  CODEX_HOME=/opt/codex \
  CODEX_INSTALL_DIR=/usr/local/bin \
  CODEX_NON_INTERACTIVE=1 \
  CODEX_RELEASE=0.144.1 \
  /bin/sh /tmp/codex-install.sh
```

Copy the downloaded script to `$ROOT/tmp/codex-install.sh` before the chroot call, record its SHA-256 in the build manifest, and remove it immediately afterward. Set `/opt/codex` to root ownership and world-readable/executable directories; do not export `CODEX_HOME` in the installed user's environment. Verify `arch-chroot "$ROOT" codex --version` equals `codex-cli 0.144.1` or the official equivalent containing `0.144.1`.

- [ ] **Step 6: Archive and verify the root filesystem**

Use `tar --acls --xattrs --numeric-owner -C "$ROOT" -cpf - . | zstd -T0 -3 -o rootfs.tar.zst`, generate SHA-256, and record `pacman -Q`. `verify-rootfs.sh` checks required packages/files, locked root, disabled GDM, enabled GPU gate and network services, no `/etc/crypttab`, no credentials, and working `yay --version`/`codex --version` in chroot.

- [ ] **Step 7: Run dry-run, static, and privileged rootfs verification**

Run: `bats tests/unit/build-scripts.bats && shellcheck scripts/*.sh scripts/lib/*.sh && sudo scripts/build-rootfs.sh && sudo scripts/verify-rootfs.sh`

Expected: unit/static checks pass and `rootfs verification: PASS`.

- [ ] **Step 8: Commit**

```bash
git add scripts tests/unit/build-scripts.bats
git commit -m "build: create offline GNOME root filesystem"
```

---

### Task 6: Assemble and Boot-Test the Archiso Image

**Files:**
- Create: `src/live-rootfs/etc/motd`
- Create: `scripts/prepare-archiso.sh`
- Create: `scripts/build-iso.sh`
- Create: `scripts/verify-artifacts.sh`
- Create: `tests/integration/qemu-boot.exp`
- Create: `tests/integration/qemu-boot.sh`

**Interfaces:**
- Consumes: installer sources, live overlay, rootfs payload/checksum/manifest, and installed `archiso` releng profile.
- Produces: `dist/blade15-arch-gnome-${BUILD_DATE}-${GIT_REV}.iso`, `.sha256`, and copied manifest.

- [ ] **Step 1: Write failing profile and artifact tests**

Tests run `prepare-archiso.sh --dry-run` and assert the generated plan copies the official releng profile, appends every live package, installs all scripts at mode `0755`, enables `blade-installer.service`, embeds payload plus checksum, and adds default boot arguments `systemd.unit=multi-user.target modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm`.

- [ ] **Step 2: Run tests and verify scripts are absent**

Run: `bats tests/unit/build-scripts.bats`

Expected: FAIL on the archiso cases.

- [ ] **Step 3: Implement profile preparation**

Copy `/usr/share/archiso/configs/releng` to a clean build profile, append/deduplicate live packages, copy `src/live-rootfs`, install `blade-install` and its libraries, embed the payload beneath `/usr/share/blade-installer` through the ISO overlay, enable the installer service, and patch all default UEFI/GRUB/Syslinux Linux entries with the safe text-mode arguments. Keep a `Rescue shell (no installer)` entry using `blade.noinstaller=1`.

- [ ] **Step 4: Implement ISO build, naming, and structural verification**

Run `mkarchiso -v -w build/archiso-work -o dist build/archiso-profile`. Rename the single output using UTC date and `git rev-parse --short HEAD`; generate SHA-256. Verify the ISO is hybrid/UEFI bootable, contains the installer, payload, matching payload checksum, manifest, rescue label, and default safe kernel arguments.

- [ ] **Step 5: Add QEMU/OVMF boot smoke test**

`qemu-boot.sh` creates a disposable NVMe disk and boots the ISO under OVMF with serial output. The Expect script waits for the installer banner, confirms the QEMU-only test bypass is rejected without `blade.test=1`, boots the rescue entry, and verifies a root shell prompt. A second boot with the explicit QEMU test argument reaches the disk-selection screen but sends `CANCEL`, proving no disk modification occurs without `WIPE`.

- [ ] **Step 6: Run ISO verification**

Run: `sudo scripts/build-iso.sh && scripts/verify-artifacts.sh && tests/integration/qemu-boot.sh`

Expected: `artifact verification: PASS` and `qemu boot: PASS`.

- [ ] **Step 7: Commit**

```bash
git add src/live-rootfs scripts tests/integration
git commit -m "build: assemble boot-safe Arch installer ISO"
```

---

### Task 7: Add the Online GitHub Actions Builder

**Files:**
- Create: `.github/workflows/build-iso.yml`
- Create: `scripts/ci-static.sh`
- Create: `scripts/ci-build.sh`
- Create: `tests/unit/workflow.bats`

**Interfaces:**
- Consumes: Tasks 1-6.
- Produces: a manually dispatchable workflow and artifact named from `blade15-arch-gnome-${{ github.run_number }}` retained for 14 days.

- [ ] **Step 1: Write a failing workflow policy test**

The Bats test parses the YAML as text and requires `workflow_dispatch`, `permissions: contents: read`, a privileged Arch container invocation, static tests before build, a six-hour timeout, pinned checkout SHA `34e114876b0b11c390a56381ad16ebd13914f8d5`, pinned upload-artifact SHA `ea165f8d65b6e75b540449e92b4886f43607fa02`, `retention-days: 14`, and upload paths limited to `dist/*.iso`, `dist/*.sha256`, and `dist/*manifest*`.

- [ ] **Step 2: Run the test and verify the workflow is absent**

Run: `bats tests/unit/workflow.bats`

Expected: FAIL because `.github/workflows/build-iso.yml` does not exist.

- [ ] **Step 3: Implement static and privileged build entrypoints**

`ci-static.sh` installs/runs Bats, ShellCheck, shfmt, and actionlint `v1.7.7`, then runs all unit tests. `ci-build.sh` checks it is root inside Arch, fully updates the container, installs `archiso`, `arch-install-scripts`, build/test dependencies, runs rootfs and ISO builds, loop integration, QEMU smoke, and final artifact verification.

- [ ] **Step 4: Implement the pinned workflow**

Use `ubuntu-24.04`; checkout with the pinned SHA; run static checks in an `archlinux:base-devel` container; then run the build container with `sudo docker run --privileged --rm -v "$GITHUB_WORKSPACE:/workspace" -w /workspace archlinux:base-devel ./scripts/ci-build.sh`. Upload only verified artifacts with the pinned upload action and `if-no-files-found: error`.

- [ ] **Step 5: Validate locally**

Run: `bats tests/unit/workflow.bats && shellcheck scripts/ci-*.sh && actionlint .github/workflows/build-iso.yml`

Expected: all commands exit 0.

- [ ] **Step 6: Commit**

```bash
git add .github scripts/ci-static.sh scripts/ci-build.sh tests/unit/workflow.bats
git commit -m "ci: build and publish installer ISO"
```

---

### Task 8: Document, Publish, Run, and Audit the Image

**Files:**
- Create: `README.md`
- Create: `docs/FLASHING.md`
- Create: `docs/RECOVERY.md`
- Modify: `docs/superpowers/plans/2026-07-12-razer-blade-arch-installer.md`

**Interfaces:**
- Consumes: verified workflow and artifact.
- Produces: user-facing download location, checksum/Rufus instructions, install/recovery runbook, online workflow run, and final verification evidence.

- [ ] **Step 1: Write operational documentation**

Document the exact supported laptop, destructive warning, Secure Boot-off prerequisite, GitHub Actions `Actions -> Build Arch ISO -> Run workflow` path, artifact ZIP extraction, Windows `Get-FileHash -Algorithm SHA256` command, Rufus DD mode, expected `WIPE` screen, username/password prompts, USB removal, first text boot/reboot, GNOME validation, `prime-run glxinfo`, `nvidia-smi`, `yay --version`, `codex --version`, `codex login`, and all recovery entries.

- [ ] **Step 2: Run full local verification**

Run: `make unit && make static && sudo make integration && sudo make build && make verify`

Expected: every stage exits 0, and final output includes ISO absolute path, SHA-256, size, Codex version, NVIDIA package version, and `PASS` summaries.

- [ ] **Step 3: Request a focused code review**

Review the diff for disk-target confusion, bypassable DMI/Secure Boot gates, secret leakage, unquoted destructive commands, boot-media ancestry mistakes, unpinned executable downloads, GDM enablement before GPU success, and recovery entries that disable Intel accidentally. Resolve every high/medium issue and rerun affected tests.

- [ ] **Step 4: Commit documentation and review fixes**

```bash
git add README.md docs src scripts tests .github config packages Makefile
git commit -m "docs: add flashing and recovery runbook"
```

- [ ] **Step 5: Publish to a new GitHub repository**

Create `blade15-arch-installer` under the connected user account as a public repository because the project contains no secrets. Push `main`, read back the default branch and workflow file, then manually dispatch `build-iso.yml`. If repository creation is not authorized by the connected GitHub account, stop only this external step while preserving the complete local repository and report the exact missing permission.

- [ ] **Step 6: Monitor the online build through completion**

Inspect every failed job log, apply fixes through the normal test-first loop, push, and rerun until the workflow succeeds. Do not treat unchanged external state as a blocker; continue polling within product limits.

- [ ] **Step 7: Download and independently verify the artifact**

Download the successful workflow artifact, set `RUN_ID` from the workflow response, extract it beneath `outputs/blade15-arch-installer/$RUN_ID/`, verify SHA-256, run `verify-artifacts.sh` against the downloaded copy, and record its absolute ISO path and GitHub run URL in the final handoff.

- [ ] **Step 8: Final repository and evidence check**

Run: `RUN_DIR="$(find outputs/blade15-arch-installer -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"; git status --short && git log --oneline --decorate -10 && sha256sum "$RUN_DIR"/*.iso`

Expected: clean worktree; all implementation commits present; checksum identical to the downloaded `.sha256`; online workflow conclusion `success`.
