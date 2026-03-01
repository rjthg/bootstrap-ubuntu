# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Research notes and installation scripts for setting up **Ubuntu 24.04 on encrypted Btrfs with the Limine bootloader and Incus containers**, targeting an AI workstation with two NVMe disks. The `limine-btrfs-review.md` documents critical errors found in a reference ChatGPT guide; the `scripts/` directory contains corrected installation scripts.

## Script Pipeline

Scripts in `scripts/` must be run **in order from a Ubuntu live USB** (except 05):

| Script | Run From | Purpose |
|--------|----------|---------|
| `00-config.sh` | (sourced) | All config variables — edit before anything else |
| `01-partition-and-encrypt.sh` | Live USB | Wipe, partition, LUKS2 encrypt, Btrfs format, mount |
| `02-install-ubuntu.sh` | Live USB | debootstrap Ubuntu, fstab/crypttab, packages, user |
| `03-configure-system.sh` | Live USB | LUKS keyfile for Incus disk, swap, rebuild initramfs |
| `04-install-limine.sh` | Live USB | Download Limine, install to ESP, kernel hooks |
| `05-post-boot-setup.sh` | Installed system | Incus installation and storage pool setup |

All scripts source `00-config.sh` for shared variables (`OS_DISK`, `INCUS_DISK`, mount paths, etc.).

## Architecture

```
OS Disk (nvme1n1, P310 Gen4):
  p1 → EFI (FAT32, 1GiB): Limine EFI, vmlinuz, initrd.img (copied, not symlinked)
  p2 → LUKS2 → Btrfs: @, @home, @log, @pkg, @swap subvolumes

Incus Disk (nvme0n1, P510 Gen5):
  p1 → LUKS2 → Btrfs (managed directly by Incus as "incus-pool")
```

Single LUKS password at boot: the OS disk passphrase unlocks first; the Incus disk uses a keyfile stored in the initramfs (generated in script 03).

## Critical Constraints

- **Limine can only read FAT32** (no Btrfs, no LUKS). The kernel and initramfs must be **copied** to the ESP — symlinks and `boot():///boot/...` paths pointing to the encrypted root will not work.
- **Three kernel update hooks** are installed in script 04 to keep the ESP in sync after `apt upgrade`:
  - `/etc/kernel/postinst.d/zz-update-limine`
  - `/etc/kernel/postrm.d/zz-update-limine`
  - `/etc/initramfs/post-update.d/zz-update-limine`
- **`cryptsetup-initramfs`** must be installed inside the chroot (script 02) — without it, the initramfs will not prompt for LUKS passwords and the system will fail to boot.
- **Secure Boot must be disabled** — Limine does not support it.
- Limine is downloaded via `git clone https://codeberg.org/Limine/Limine.git --branch=v10.x-binary` (no ZIP artifact exists on GitHub).

## Issue Tracking

This repository uses `bd` (Beads) for issue tracking:

```bash
bd list                          # view issues
bd show <id>                     # issue details
bd create "description"          # new issue
bd update <id> --status done     # close issue
bd close <id>                    # close issue
bd sync                          # sync issues
bd stats                         # issue statistics
bd ready                         # mark issue ready
```
