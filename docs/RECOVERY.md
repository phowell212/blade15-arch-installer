# Recovery

Recovery does not undo an installation. Once exact `WIPE` has been accepted,
the selected disk's old partition table and filesystems are destroyed. The new
root filesystem is unencrypted ext4; there is no LUKS recovery key or automatic
rollback.

## Choose the right boot path

The installed systemd-boot menu remains visible for 10 seconds:

- `Blade Arch Linux` is the normal path. It enables NVIDIA DRM mode setting and
  supports Intel-driven Optimus or NVIDIA-routed display operation.
- `Blade Arch Linux (Intel-only recovery)` blacklists `nvidia`, `nvidia_drm`,
  `nvidia_modeset`, and `nvidia_uvm` for this boot. It does **not** blacklist
  Intel `i915`. Use it when NVIDIA causes a black screen; it may start GNOME if
  GDM was already enabled, otherwise it reaches a TTY.
- `Blade Arch Linux (text recovery)` forces `multi-user.target` for this boot.
  It leaves both Intel and NVIDIA drivers available, making it the preferred
  path for inspecting or repairing the full graphics stack without starting
  GNOME.

The USB has a separate `Rescue shell (no installer)` entry. It boots a root
shell without starting the installer and uses the live image's safe graphics
blacklist. Merely booting this entry is non-destructive; commands run manually
from its root shell can still change disks.

## First-boot GPU gate failure

Log in at the TTY with the username and password created during installation.
Inspect the persistent diagnostics:

```bash
sudo cat /var/log/blade-gpu-firstboot.log
sudo journalctl -b -u blade-firstboot-gpu.service --no-pager
lspci -nn | grep -E 'VGA|3D|Display'
lsmod | grep -E '^(i915|nvidia)'
nvidia-smi
switcherooctl list
```

The gate requires Intel and NVIDIA PCI/DRM devices, `i915`, all four NVIDIA
modules, NVIDIA DRM modeset `Y`, and successful bounded `nvidia-smi -L` and
`switcherooctl list` checks. A failure writes
`/var/lib/blade-installer/gpu-gate-failed`, keeps GDM disabled, keeps
`multi-user.target` as default, and disables the gate so it cannot loop.

After correcting the reported problem, explicitly request one retry:

```bash
sudo rm -f -- /var/lib/blade-installer/gpu-gate-failed
sudo systemctl set-default multi-user.target
sudo systemctl disable gdm.service
sudo systemctl enable blade-firstboot-gpu.service
sudo systemctl start blade-firstboot-gpu.service
```

On success the service enables GDM, changes the default to graphical mode,
disables itself, and reboots. On another failure it returns to the persistent
TTY state and updates the log. Do not bypass the gate by enabling GDM manually.

## Repair from the live rescue shell

Boot the USB and choose `Rescue shell (no installer)`. First identify the
installed partitions; the installer labels them `EFI` and `ARCHROOT`:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

Set these variables only after matching the labels, paths, and sizes shown by
`lsblk`. The following paths are the usual single-NVMe layout but must be
verified before use:

```bash
ROOT_PARTITION=/dev/nvme0n1p2
EFI_PARTITION=/dev/nvme0n1p1
mount -- "$ROOT_PARTITION" /mnt
mount -- "$EFI_PARTITION" /mnt/boot
arch-chroot /mnt
```

From the chroot, inspect packages and configuration or rebuild the initramfs
with `mkinitcpio -P`. Exit the chroot and unmount in reverse order before
rebooting:

```bash
exit
umount /mnt/boot
umount /mnt
reboot
```

Remove the USB during reboot and use the normal, Intel-only, or text entry as
appropriate. For the complete install flow, see
[Flashing and installation](FLASHING.md); for post-recovery checks, see the
[README](../README.md#verify-the-installed-system).
