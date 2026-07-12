# Razer Blade 15 Arch Linux Installer

This project builds an offline Arch Linux installer for exactly one physical
laptop: the 2022 Razer Blade 15 `RZ09-0421NEC3`. It installs GNOME, hybrid
Intel/NVIDIA graphics support, `yay`, and Codex CLI.

> **DANGER: THIS INSTALLER ERASES AN ENTIRE SELECTED DISK.** It creates a new
> GPT, a 1 GiB FAT32 EFI partition, and an ext4 root partition. There is no
> dual-boot preservation, LUKS encryption, separate `/home`, or disk-based
> swap. Back up everything first. Do not type `WIPE` unless the displayed disk
> is the one you intend to destroy.

Although the installer checks for Razer DMI family `RZ09-0421`, no other model
or variant is supported. The laptop must boot in UEFI mode with **Secure Boot
disabled**. Keep it connected to AC power throughout installation.

## Build or download the image

No downloadable ISO or successful workflow-run URL is recorded in this
repository yet. To build one in GitHub after the repository is published:

1. Open **Actions -> Build Arch ISO -> Run workflow**.
2. Wait for the run to finish successfully.
3. Open its run summary and download the
   `blade15-arch-gnome-<run-number>` artifact ZIP.
4. Extract the ZIP. It contains the ISO, its `.sha256` file, and build
   manifest data.

The final release handoff will record the successful GitHub run URL and the
absolute path of the independently downloaded ISO under
`outputs/blade15-arch-installer/<run-id>/`. Until those values are present,
do not treat an image as published or verified.

See [Flashing and installation](docs/FLASHING.md) for Windows checksum and
Rufus instructions.

## Installation behavior

Boot the USB's normal/default installer entry. The installer refuses physical
installation unless it sees UEFI, Secure Boot off, and the supported Razer DMI
family. It excludes the live USB from its candidate disks, then asks for:

1. A numbered whole-disk target.
2. A hostname (Enter accepts `blade15`).
3. A local username.
4. A password of at least eight characters, entered twice without echo.
5. The exact, case-sensitive confirmation `WIPE` after showing the target,
   identity, partition layout, and `Encryption: NONE`.

After installation, remove the USB before rebooting. The first installed boot
uses the normal `Blade Arch Linux` entry and intentionally stays in text mode
while a one-shot graphics gate checks Intel and NVIDIA devices, kernel modules,
DRM mode setting, `nvidia-smi`, and `switcherooctl`. On success it enables GDM,
switches the default to graphical mode, and reboots once into GNOME. On failure
it remains at a TTY and writes `/var/log/blade-gpu-firstboot.log`; follow
[Recovery](docs/RECOVERY.md).

## Verify the installed system

In GNOME, check the internal display, Wi-Fi, audio, suspend/resume, and then run
the following as the local user. `glxinfo` is supplied by `mesa-utils`, so
install it once after connecting to a network:

```bash
systemctl is-active gdm
switcherooctl list
sudo pacman -S --needed mesa-utils
prime-run glxinfo -B
nvidia-smi
yay --version
codex --version
codex login
```

`prime-run glxinfo -B` should identify the NVIDIA renderer. Codex is installed
without credentials; `codex login` starts the normal authentication flow for
the local user.

## Boot choices

- USB normal/default entry: starts the destructive installer after safety
  checks.
- `Rescue shell (no installer)`: boots the USB without starting the installer.
- `Blade Arch Linux`: normal installed hybrid-graphics path.
- `Blade Arch Linux (Intel-only recovery)`: blacklists only the four NVIDIA
  modules and keeps Intel `i915` available.
- `Blade Arch Linux (text recovery)`: forces a TTY for that boot without
  disabling either GPU.

Detailed uses and graphics-gate retry commands are in
[Recovery](docs/RECOVERY.md).
