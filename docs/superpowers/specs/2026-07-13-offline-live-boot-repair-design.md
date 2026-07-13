# Offline Live-Boot Repair Design

Date: 2026-07-13

## Objective

Repair the physical-boot failures in the Razer Blade Arch installer ISO while
preserving the approved appliance design: installation must be fully offline,
the live image should copy itself to RAM when the laptop has enough memory, the
installer must start automatically, and no disk may be modified before the
exact `WIPE` confirmation.

## Observed Failures

The first physical boot established four independent defects before any disk
was modified:

1. The stock releng image enabled `systemd-time-wait-sync.service` with an
   infinite timeout, so boot waited forever without Ethernet or configured
   Wi-Fi.
2. The stock tty1 autologin getty won the boot transaction instead of the
   custom physical installer service, leaving a shell prompt rather than the
   installer.
3. Installed installer libraries looked for `../../../config/build.env` from
   `/usr/local/lib/blade-installer`, which resolves outside the embedded
   configuration. Required DMI, hostname, and timezone values were therefore
   unset.
4. Archiso's automatic copy-to-RAM path deliberately unmounted
   `/run/archiso/bootmnt`. Disk discovery assumed that mount still existed and
   could no longer identify and exclude the USB boot disk.

## Chosen Repair

### Offline boot ownership

Every live boot route receives
`systemd.mask=systemd-time-wait-sync.service`. This affects only the live
environment and avoids any network dependency. The normal physical installer
route additionally receives `systemd.mask=getty@tty1.service`, allowing
`blade-installer.service` to own tty1 deterministically. Rescue and QEMU routes
do not receive the tty1 mask, so the physical rescue shell remains available.

### Runtime configuration

The build stages a non-secret runtime configuration at
`/usr/share/blade-installer/build.env`. A loader in `common.sh` uses an explicit
`BUILD_ENV_FILE` override when supplied, then the canonical installed path,
then the repository-relative path used by development tests. Missing or unsafe
configuration fails before hardware or disk operations with a precise error.
The loader remains usable when `blade-install` is launched manually.

### Copy-to-RAM boot-disk discovery

The fast copy-to-RAM behavior remains enabled. Disk discovery first uses the
mounted live root when present. If Archiso removed that mount, it parses exactly
one `archisosearchuuid=` token from `/proc/cmdline`, rejects empty, malformed,
or duplicate values, and asks `blkid` for exact UUID matches. Exactly one
current block device must resolve; its `lsblk` ancestry identifies the whole
boot disk. Missing media, duplicate UUIDs, invalid ancestry, or enumeration
errors fail closed and expose no destructive target.

### Verification and artifact eligibility

Regression tests reproduce all four physical failures. Prepared-profile and
extracted-artifact checks require the runtime configuration and route-specific
boot arguments. Disk tests exercise both a mounted boot medium and the
copy-to-RAM UUID fallback, including ambiguity and removal. A positive QEMU
startup/cancel smoke must reach safe disk selection without any missing-config
error before the build writes `dist/.verified`; later negative-path harnesses
may still fail the workflow but cannot bless an image that never starts.

## Alternatives Rejected

- Disabling copy-to-RAM would preserve `/run/archiso/bootmnt`, but it makes the
  live system and payload extraction depend on repeated USB reads and gives up
  the faster behavior requested for this 16 GiB laptop.
- Copying configuration to the accidental `/usr/config/build.env` path would
  encode the current install-directory depth and break again after relocation.
- Supplying configuration only through a systemd `EnvironmentFile=` would
  leave manual recovery launches broken.
- Filtering only for internal NVMe disks without identifying the boot medium
  weakens the destructive safety boundary for USB and Thunderbolt storage.
- Requiring Wi-Fi or Ethernet contradicts the approved offline installer.

## Acceptance Criteria

1. Default physical boot reaches the installer without network access or a
   manual GRUB edit.
2. `blade-install` can also be launched manually with no exported variables.
3. Copy-to-RAM boot excludes the flashed USB and lists the internal NVMe by
   model and capacity.
4. Rescue boot still reaches a tty1 shell.
5. No code path writes a disk before the selected target is shown and exact
   `WIPE` is entered.
6. The replacement ISO, sidecar, and manifest are downloaded locally and the
   local SHA-256 matches the sidecar.
