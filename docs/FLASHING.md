# Flashing and Installation

This image supports only the Razer Blade 15 `RZ09-0421NEC3`. Installation is
UEFI-only and **Secure Boot must be disabled**.

> **WIPE WARNING:** The installer destroys the selected whole disk and all of
> its partitions. The installed root is unencrypted ext4; there is **no LUKS**
> and no rollback. Back up the laptop and verify the displayed disk model,
> serial, and size before entering `WIPE`.

## 1. Obtain and extract the Actions artifact

There is no published image link yet. In the published GitHub repository, use
**Actions -> Build Arch ISO -> Run workflow**. After the run succeeds, open the
run summary, download the `blade15-arch-gnome-<run-number>` artifact ZIP, and
use Windows **Extract All**. The extracted directory must contain exactly one
`.iso`, its matching `.iso.sha256`, and manifest data.

The successful run URL and the absolute path of the independently downloaded
ISO will be recorded in the final handoff under
`outputs/blade15-arch-installer/<run-id>/`; they are intentionally not guessed
here.

## 2. Verify SHA-256 on Windows

Open PowerShell in the extracted directory and run:

```powershell
$iso = Get-ChildItem -File .\*.iso
if (@($iso).Count -ne 1) { throw "Expected exactly one ISO" }
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $iso.FullName).Hash.ToLowerInvariant()
$expected = ((Get-Content -LiteralPath "$($iso.FullName).sha256" -Raw) -split '\s+')[0].ToLowerInvariant()
if ($actual -ne $expected) { throw "SHA-256 mismatch" }
"SHA-256 verified: $actual"
```

Do not flash the image if the command reports a mismatch.

## 3. Flash with Rufus in DD mode

1. Insert a USB drive that can hold the ISO. Everything on the USB will be
   erased.
2. Open Rufus and select that USB under **Device**.
3. Choose the verified `.iso` under **Boot selection**.
4. Select **Start** and, when Rufus asks how to write the hybrid image, choose
   **Write in DD Image mode**.
5. Confirm the USB erase and wait for Rufus to finish before ejecting it.

DD mode is required because ISO mode may rewrite bootloader files.

## 4. Prepare and boot the laptop

1. Back up the laptop, connect AC power, and enter firmware setup.
2. Disable **Secure Boot** and keep UEFI boot enabled.
3. Insert the flashed USB and select it from the firmware's one-time boot menu.
4. Choose the normal/default installer entry. Use
   `Rescue shell (no installer)` only for non-destructive recovery.

The normal live entry is text-only and keeps nouveau/NVIDIA modules
blacklisted. The installer checks UEFI, Secure Boot, and Razer DMI before it
offers any target disk.

## 5. Answer the installer prompts

1. At **Safe installation targets**, compare the path, size, model, serial, and
   transport with the physical internal disk. Enter its number.
2. Enter a hostname, or press Enter for `blade15`.
3. Enter a local username.
4. Enter the password twice. Input is hidden and must be at least eight
   characters.
5. Read the **DESTRUCTIVE INSTALL SUMMARY**. It must show the intended disk,
   a 1 GiB FAT32 `/boot`, remaining ext4 `/`, and `Encryption: NONE`.
6. Only if every value is correct, answer this prompt with exact uppercase
   `WIPE`:

```text
Type WIPE exactly to erase /dev/...: WIPE
```

Any other answer cancels before destructive work. Installation then verifies
the embedded payload checksum, partitions the disk, copies the offline system,
installs systemd-boot, validates the target, and unmounts it.

## 6. Remove the USB and complete first boot

When `Installation complete. Remove the USB before the next boot.` appears,
remove the USB first. Then choose `r` to reboot, `s` to shut down, or press
Enter for a live shell.

At the installed systemd-boot menu choose `Blade Arch Linux`. The first boot is
deliberately text-only. The GPU gate runs automatically:

- Success: GDM is enabled, graphical mode becomes the default, and the laptop
  reboots once into GNOME.
- Failure: the laptop remains at a TTY, does not retry automatically, and saves
  diagnostics in `/var/log/blade-gpu-firstboot.log`.

After GNOME appears, use the verification commands in the
[README](../README.md#verify-the-installed-system). If the gate fails or the
screen is unusable, follow [Recovery](RECOVERY.md).
