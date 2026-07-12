# Razer Blade 15 Arch GNOME Installer Design

Date: 2026-07-12

## Objective

Build a downloadable, flashable Arch Linux installer ISO for one target laptop. The ISO installs a complete GNOME system with correct hybrid Intel/NVIDIA graphics, `yay`, and Codex while avoiding the black-screen failure mode encountered during manual installation.

The target is a Razer Blade 15 (2022), product family RZ09-0421 and specific variant RZ09-0421NEC3, with an Intel Core i7-12800H, Intel integrated graphics, an NVIDIA GeForce RTX 3070 Ti Laptop GPU, 16 GiB RAM, and a 1 TB NVMe SSD. The manufacturer's specifications identify this generation as an NVIDIA Optimus dual-GPU laptop.

## Success Criteria

1. A GitHub Actions workflow builds the ISO without requiring an Arch workstation.
2. The resulting ISO and checksum are downloadable as workflow artifacts and can be flashed with Rufus in DD mode.
3. The USB boots into a text installer without loading the NVIDIA graphical stack.
4. The installer only supports UEFI, refuses to continue with Secure Boot enabled, identifies the USB separately from internal disks, displays the selected disk and partitions, and requires the exact confirmation `WIPE` before destructive work.
5. Installation works offline after the ISO has been built; no mirror or Wi-Fi availability is required while installing.
6. The installed system contains GNOME, GDM, NetworkManager, PipeWire, Intel graphics, the current repository-matched NVIDIA open kernel modules, NVIDIA userspace, hybrid-GPU switching, `yay`, and Codex CLI.
7. The first installed boot is text-only. A hardware gate verifies Intel DRM, NVIDIA modules, DRM devices, and `nvidia-smi` before enabling GDM.
8. Failure leaves a usable TTY and persistent diagnostic log instead of automatically entering a black screen.
9. Normal, Intel-only recovery, and text recovery entries remain in the installed boot menu.
10. Automated checks cover non-destructive logic, ISO contents, UEFI boot, installation into a virtual disk, partition layout, installed packages, and enabled services.

## Chosen Approach

Use `archiso` to create a small text-mode live environment plus a compressed, prebuilt target root filesystem. GitHub Actions performs both builds in one package transaction context, records a package manifest, and publishes the ISO and SHA-256 checksum.

The live system contains only what is needed to inspect hardware, partition disks, copy the payload, configure the target, and recover it. It does not start GNOME and blacklists discrete graphics modules in its default installer entry. The target root filesystem contains the full desktop. This separation prevents the graphics stack being installed from becoming a prerequisite for running the installer.

Alternatives rejected:

- A remotely hosted `archinstall` configuration still downloads packages during installation and inherits profile/driver variation over time.
- A live persistent GNOME USB is slower, complicates updates and NVIDIA kernel coupling, and previously produced persistence failures.
- A fully automatic image that erases the first disk at boot is unsafe when multiple computers or storage devices are involved.

## Build Architecture

### Repository

The project will contain:

- An `archiso` profile derived from the official `releng` profile.
- A target package manifest and root-filesystem overlay.
- A root filesystem builder.
- The interactive installer and reusable validation functions.
- First-boot GPU validation and recovery tooling.
- UEFI boot-entry templates.
- Unit/integration tests and a QEMU smoke test.
- A GitHub Actions workflow and operator documentation.

Generated root filesystems, packages, ISOs, keys, and logs are build outputs and will not be committed.

### Online Builder

GitHub Actions runs an Arch Linux build container with the privileges required by `mkarchiso`. It:

1. Synchronizes official Arch repositories once for the build.
2. Resolves and installs the live-environment packages.
3. Builds `yay` as an unprivileged user from a reviewed and pinned AUR snapshot.
4. Creates the target root filesystem with all official packages in one transaction.
5. Runs OpenAI's standalone Codex installer non-interactively into `/usr/local/bin` and includes `bubblewrap` for Linux sandbox support.
6. Applies configuration overlays and creates `rootfs.tar.zst`.
7. Embeds the payload, package manifest, project version, and installer into the ISO.
8. Runs static checks and UEFI/QEMU smoke tests.
9. Emits `blade15-arch-gnome-<date>-<revision>.iso`, its SHA-256 checksum, and the package manifest as one downloadable artifact.

Passwords, Wi-Fi credentials, Codex authentication, laptop serial numbers, and other user secrets never enter the repository or CI environment.

## Installed System

### Base and Storage

- UEFI/GPT only; Secure Boot must be disabled for this first version.
- Partition 1: 1 GiB FAT32 EFI System Partition mounted at `/boot`.
- Partition 2: remaining usable space as unencrypted `ext4` mounted at `/`.
- No LUKS, separate `/home`, disk swap partition, or swap file.
- `zram-generator` creates up to 8 GiB of compressed RAM swap using `lz4` at high priority.
- Hibernation is unsupported; normal suspend remains available.
- Weekly SSD trimming is enabled through `fstrim.timer`.
- `systemd-boot` is installed with normal, Intel-only recovery, and text recovery entries.
- The locale is `en_US.UTF-8`, the console keymap is US, and the timezone is `America/New_York`.

### Desktop and Hardware

The package set includes the `gnome` group, GDM, NetworkManager, PipeWire/WirePlumber, Firefox, Intel microcode and firmware, Intel Mesa/Vulkan/media drivers, and common laptop integration such as power profiles.

The expected and preferred display mode is NVIDIA Optimus, in which the internal panel is Intel-driven and the NVIDIA GPU is used for explicit application offload. The first-boot gate nevertheless inspects which DRM device owns the connected internal panel instead of assuming the firmware's Advanced Optimus state. If the panel is routed directly to NVIDIA, the normal entry can use NVIDIA for the desktop; if it is routed to Intel, GNOME uses Intel and offloads selected applications.

The NVIDIA set includes the repository-matched `nvidia-open`, `nvidia-utils`, `lib32-nvidia-utils`, `egl-wayland`, `nvidia-prime`, and `switcheroo-control`. The multilib repository is explicitly enabled for the 32-bit userspace package. The design deliberately does not create a static `/etc/X11/xorg.conf`.

NVIDIA DRM kernel mode setting is explicit in the normal boot entry. `switcheroo-control` is enabled so GNOME can expose discrete-GPU application launching. The recovery entries can boot to a TTY and can blacklist the NVIDIA modules without disabling Intel graphics.

### User Tools

The target includes `base-devel`, Git, OpenSSH, `ripgrep`, `fd`, `curl`, `wget`, `yay`, and Codex CLI. Codex is installed but unauthenticated. After GNOME is working, the user runs `codex login` and completes the browser flow. Authentication files are not copied from another computer or embedded in the ISO.

### Accounts

During installation, the script prompts for:

- Hostname, defaulting to `blade15`.
- A lowercase local username.
- A password entered twice with terminal echo disabled.

The account is added to `wheel` and configured for `sudo`. Root login is locked. Forgotten login passwords remain resettable from the installer USB because the disk is not encrypted. No automatic login is configured.

## Installer Flow

1. Verify UEFI boot and require Secure Boot to be disabled.
2. Check DMI data for Razer and product family RZ09-0421. Refuse unsupported physical hardware.
3. Resolve the block device backing the live ISO and exclude it from target candidates.
4. List only non-removable internal disks with model, serial suffix, transport, size, and current partitions. If selection is ambiguous, require an explicit numbered choice.
5. Collect and validate hostname, username, and password without logging secrets.
6. Render a final destructive-operation summary.
7. Require the exact case-sensitive text `WIPE`.
8. Unmount stale mounts belonging to the selected target, clear signatures, create the GPT layout, format both filesystems, and mount them below `/mnt`.
9. Extract the prebuilt root filesystem and generate `fstab` from filesystem UUIDs.
10. Apply the runtime hostname, account password, machine ID, locale, timezone, and boot configuration.
11. Install systemd-boot, build initramfs images, enable required services, and validate the installed tree.
12. Write a non-secret installation report to `/var/log/blade-arch-installer.log` in both live and installed systems.
13. Sync, unmount, and offer shutdown or reboot. The USB must be removed before the installed-system reboot.

Any failed command stops the installer. The script reports the failing phase, keeps the live shell available, and never continues to a later destructive phase after an error.

## First-Boot GPU Gate

The installed default target initially remains `multi-user.target`; GDM is disabled until validation passes. A one-shot service performs:

1. Confirm Intel and NVIDIA PCI display devices are present and identify which DRM device owns the connected internal panel.
2. Load `i915`, `nvidia`, `nvidia_modeset`, `nvidia_uvm`, and `nvidia_drm`.
3. Confirm Intel and NVIDIA DRM devices exist.
4. Confirm NVIDIA DRM modesetting is enabled.
5. Run `nvidia-smi -L` and `switcherooctl list` with a bounded timeout.
6. Record kernel, PCI, DRM, module, and journal diagnostics without user secrets.

On success, it enables GDM, changes the default to `graphical.target`, writes a success marker, and reboots once into GNOME. On failure, it leaves the system at the TTY, prints the log path and recovery commands, and does not retry indefinitely.

Module checks cannot prove that every display path will render correctly. Therefore, the normal boot entry has a generous menu timeout and the Intel-only/text recovery entries remain permanent.

## Safety Boundaries

- No disk is modified before exact `WIPE` confirmation.
- The boot USB is excluded using its mounted live-root ancestry, not only the removable flag.
- The installer refuses loop, optical, device-mapper, and already-mounted system devices as targets.
- A target must be a whole physical disk, never a partition.
- DMI checks make the physical installer appliance-specific. Tests use an explicit test mode unavailable from the normal boot menu.
- Password variables are cleared after use; shell tracing is prohibited around credential handling.
- CI dependencies and GitHub actions are pinned. Build output records exact package and source versions.
- AUR content is limited to `yay`, built unprivileged from the reviewed snapshot. No arbitrary AUR packages are installed automatically.
- Codex credentials are established only by the user after installation.

## Verification Strategy

### Static and Unit Tests

- `shellcheck` and formatting checks for shell code.
- `actionlint` for GitHub Actions.
- Tests with fixture `lsblk`, `findmnt`, EFI, Secure Boot, and DMI output for disk exclusion and hardware gates.
- Tests for username/hostname validation, exact wipe confirmation, secret redaction, and retry behavior.
- Tests for generated `fstab`, zram configuration, module options, service links, and boot entries.

### Build and VM Tests

- Build the root filesystem and ISO from scratch.
- Verify checksums and inspect ISO contents.
- Boot the ISO with OVMF in QEMU against a disposable virtual NVMe disk.
- Exercise the installer in explicit test mode.
- Reboot from the virtual disk and verify GPT layout, EFI boot files, initramfs, package manifest, user creation, and enabled services.
- Mock the dual-GPU hardware probe to test both first-boot success and failure branches.

### Laptop Acceptance Test

The first physical run is intentionally supervised. Confirm the selected 1 TB NVMe device and type `WIPE`. After installation, the first boot must either reach GNOME after the successful hardware gate or remain at a working TTY with diagnostics. In GNOME, verify the internal display, 360 Hz modes where exposed, Wi-Fi, audio, suspend/resume, an NVIDIA-offloaded application, `nvidia-smi`, `yay --version`, and `codex --version` before treating the image as accepted.

## Distribution and Use

The GitHub Actions run page provides a ZIP artifact containing the ISO, checksum, and manifest. After extracting it on Windows, verify the checksum and flash the ISO with Rufus in DD mode. This avoids Rufus rewriting the ISO's bootloader files. The project README will document the exact artifact location, flashing steps, BIOS prerequisites, install prompts, first-boot behavior, and recovery entries.

## Sources

- [Archiso](https://wiki.archlinux.org/title/Archiso)
- [Archinstall guided installation](https://archinstall.archlinux.page/installing/guided.html)
- [Arch Linux nvidia-open package](https://archlinux.org/packages/extra/x86_64/nvidia-open/)
- [Arch Linux switcheroo-control package](https://archlinux.org/packages/extra/x86_64/switcheroo-control/)
- [Arch Linux zram-generator package](https://archlinux.org/packages/extra/x86_64/zram-generator/)
- [Razer Blade 15 (2022), RZ09-0421 support and specifications](https://mysupport.razer.com/app/answers/detail/a_id/5900/)
- [Razer Advanced Optimus display modes](https://mysupport.razer.com/app/answers/detail/a_id/4585/)
- [Codex standalone install and authentication manual](https://developers.openai.com/codex/codex-manual.md)
