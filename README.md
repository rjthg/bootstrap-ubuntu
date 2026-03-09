# Ubuntu 24.04 on Encrypted Btrfs with Limine

Automated install scripts for setting up **Ubuntu 24.04 (Noble)** on a dual-NVMe AI workstation with:

- Full-disk LUKS2 encryption on both drives
- Btrfs with subvolumes (`@`, `@home`, `@log`, `@pkg`, `@swap`)
- [Limine](https://codeberg.org/Limine/Limine) bootloader (v10.x)
- [Incus](https://linuxcontainers.org/incus/) container/VM runtime on a dedicated encrypted disk
- Single passphrase at boot (keyfile auto-unlocks the second disk)
- Realtek RTL8127 10GbE out-of-tree driver

`limine-btrfs-review.md` documents errors found in a reference ChatGPT guide that these scripts correct.

---

## Hardware

| Disk | Device | Role |
|------|--------|------|
| Crucial P310 (PCIe Gen4) | `nvme1n1` | OS disk |
| Crucial P510 (PCIe Gen5) | `nvme0n1` | Incus storage |

> **Before running anything**, verify your disk assignments with `lsblk -o NAME,SIZE,MODEL`. The variables in `scripts/00-config.sh` must match your actual hardware. Getting this wrong will erase the wrong disk.

---

## Disk Layout

```
OS Disk (nvme1n1):
  p1 → EFI System Partition (FAT32, 1 GiB)
         BOOTX64.EFI, limine.conf, vmlinuz, initrd.img (copied — not symlinked)
  p2 → LUKS2 → Btrfs
         @         → /
         @home     → /home
         @log      → /var/log
         @pkg      → /var/cache/apt
         @swap     → /swap (4 GiB swapfile)

Incus Disk (nvme0n1):
  p1 → LUKS2 → Btrfs (managed by Incus as "incus-pool")
```

---

## Script Pipeline

All scripts must be run **in order from a Ubuntu live USB** (boot with "Try Ubuntu"), except script 05 which runs from the installed system.

| Script | Run from | What it does |
|--------|----------|-------------|
| `00-config.sh` | (sourced) | All shared variables — **edit this first** |
| `01-partition-and-encrypt.sh` | Live USB | Wipe, partition, LUKS2 encrypt, Btrfs format + subvolumes, mount |
| `02-install-ubuntu.sh` | Live USB | `debootstrap`, fstab/crypttab, packages, user, RTL8127 driver |
| `03-configure-system.sh` | Live USB | LUKS keyfile for Incus disk, swap, rebuild initramfs |
| `04-install-limine.sh` | Live USB | Download Limine, install to ESP, kernel update hooks, efibootmgr |
| `05-post-boot-setup.sh` | Installed system | Incus install, storage pool, network bridge, user group |

### Quick start

```bash
# Boot Ubuntu live USB → open a terminal
git clone <this-repo>
cd research/scripts

# 1. Edit config to match your hardware
nano 00-config.sh

# 2. Run scripts in order
sudo bash 01-partition-and-encrypt.sh
sudo bash 02-install-ubuntu.sh
sudo bash 03-configure-system.sh
sudo bash 04-install-limine.sh

# 3. Reboot into the new system, then:
sudo bash 05-post-boot-setup.sh
```

---

## Single-Password Boot: How the Second Disk Auto-Unlocks

At boot you are prompted for **one passphrase** — the OS disk (nvme1n1). The Incus disk (nvme0n1) unlocks automatically without a second prompt. Here is how that works:

**Script 03 sets this up:**

1. A random 4 KiB keyfile is generated and stored at `/etc/luks-incus-keyfile` (permissions `0600`).
2. The keyfile is enrolled in the Incus disk's LUKS header via `cryptsetup luksAddKey`.
3. `/etc/crypttab` is written with the keyfile path for the Incus mapper:
   ```
   cryptroot   UUID=<os-uuid>    none                    luks,discard
   cryptincus  UUID=<incus-uuid> /etc/luks-incus-keyfile luks,discard
   ```
4. An initramfs hook copies the keyfile into the initramfs image, so it is available before the root filesystem is mounted.
5. `update-initramfs` rebuilds the initramfs with the hook and keyfile included.

At boot: the initramfs unlocks the OS disk (prompting for the passphrase), then uses the embedded keyfile to unlock the Incus disk automatically — `crypttab` handles the rest.

**The Incus disk is not mounted via fstab.** Once `crypttab` opens it as `/dev/mapper/cryptincus`, the Incus daemon manages it directly as a Btrfs storage pool. Script 05 registers it with:

```bash
incus storage create incus-pool btrfs source=/dev/mapper/cryptincus
```

Incus mounts and unmounts the volume as needed — the OS never mounts it independently.

---

## Limine Bootloader

Limine **can only read FAT32**. It cannot read Btrfs or LUKS. This has two consequences:

- The kernel (`vmlinuz`) and initramfs (`initrd.img`) must be **physically copied** to the EFI partition — symlinks and paths into the encrypted root will not work.
- `limine.conf` uses `boot():/` to reference the ESP (the volume Limine loaded from), not the root filesystem.

Script 04 installs three hooks to keep the ESP in sync after `apt upgrade`:

| Hook | Trigger |
|------|---------|
| `/etc/kernel/postinst.d/zz-update-limine` | New kernel installed |
| `/etc/kernel/postrm.d/zz-update-limine` | Kernel removed |
| `/etc/initramfs/post-update.d/zz-update-limine` | Initramfs rebuilt |

The ESP always holds two kernel slots: `vmlinuz` / `initrd.img` (current) and `vmlinuz.old` / `initrd.img.old` (previous). Select "Ubuntu (previous kernel)" in the Limine menu to roll back if a new kernel fails to boot.

> **Secure Boot must be disabled** — Limine does not support it.

---

## Snapshots and Rollback

Btrfs has native copy-on-write snapshots. This section covers how to create a checkpoint before making big changes and how to roll back if something goes wrong.

### What can (and cannot) be snapshotted

| Component | Snapshotable? | Notes |
|---|---|---|
| `@` (root `/`) | Yes | Most important to snapshot before changes |
| `@home` | Yes | User data |
| `@log` | Yes | Rarely worth it |
| `@pkg` | Yes | Apt cache — rebuildable, optional |
| `@swap` | **No** | Swap files require NoCoW; snapshotting breaks this |
| EFI partition (`nvme1n1p1`) | **No** (FAT32) | Manually `rsync` it instead |
| Incus containers/VMs | Separately | Use `incus snapshot <instance>` |

Snapshots are **not recursive**. Because all subvolumes (`@`, `@home`, etc.) are siblings at the Btrfs top level (flat layout), this is not an issue here — each subvolume is snapshotted individually.

### Where snapshots are stored

Snapshots live on the **same disk, same LUKS container, same Btrfs filesystem** as the data. They are instant and consume near-zero space at creation (copy-on-write), then grow as the live system diverges. Recommended layout:

```
/dev/mapper/cryptroot  (Btrfs top level, subvolid=5)
  ├── @
  ├── @home
  ├── @log
  ├── @pkg
  ├── @swap
  └── @snapshots/                    ← create this once
        ├── @-before-bigchange
        └── @home-before-bigchange
```

> **Snapshots are not a backup.** A disk failure destroys both the live data and all snapshots simultaneously. For off-disk backup, use `btrfs send` / `btrfs receive` to an external drive.

### Taking a snapshot (from the running system)

```bash
# Mount the raw Btrfs top level (not a subvolume)
sudo mkdir -p /mnt/btrfs-root
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt/btrfs-root

# Create the snapshots directory (only needed once)
sudo mkdir -p /mnt/btrfs-root/@snapshots

# Snapshot the subvolumes you care about
sudo btrfs subvolume snapshot /mnt/btrfs-root/@ /mnt/btrfs-root/@snapshots/@-before-bigchange
sudo btrfs subvolume snapshot /mnt/btrfs-root/@home /mnt/btrfs-root/@snapshots/@home-before-bigchange

# Optionally back up the EFI partition (it is small)
sudo rsync -av /boot/efi/ /mnt/btrfs-root/@snapshots/efi-before-bigchange/

sudo umount /mnt/btrfs-root
```

### Rolling back (from the Ubuntu live USB)

You cannot unmount `/` or `/home` while booted from them. Rollback must be done from the live USB.

```bash
# 1. Unlock LUKS
cryptsetup open /dev/nvme1n1p2 cryptroot
# (enter your passphrase)

# 2. Mount the raw Btrfs top level
mount -o subvolid=5 /dev/mapper/cryptroot /mnt

# 3. Rename the broken subvolumes (keep them as a safety net, delete later)
mv /mnt/@ /mnt/@-broken
mv /mnt/@home /mnt/@home-broken

# 4. Restore from snapshots
btrfs subvolume snapshot /mnt/@snapshots/@-before-bigchange /mnt/@
btrfs subvolume snapshot /mnt/@snapshots/@home-before-bigchange /mnt/@home

# 5. Unmount and reboot normally
umount /mnt
```

The `fstab` uses subvolume names (`subvol=@`, `subvol=@home`) not IDs, so the restored subvolumes are picked up automatically — no fstab edits needed.

### Cleaning up after a successful change

Once you are confident the change worked:

```bash
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt/btrfs-root
sudo btrfs subvolume delete /mnt/btrfs-root/@snapshots/@-before-bigchange
sudo btrfs subvolume delete /mnt/btrfs-root/@snapshots/@home-before-bigchange
sudo umount /mnt/btrfs-root
```

### Space management

- Snapshots start near-zero in size but grow as files change after the snapshot is taken
- Deleted files from the live system still exist in snapshots and continue consuming space
- Keep at least 5–10% of the disk free — Btrfs needs headroom for CoW operations; if the disk fills completely, even deletion can fail

---

## Network Driver (RTL8127)

The onboard Realtek RTL8127 10GbE controller is not supported by the in-kernel `r8169` driver. The out-of-tree driver is built automatically by script 02 inside the chroot.

- The driver tarball `r8127-11.016.00.tar.bz2` is committed to the repo root.
- `build-essential` and `dkms` are installed as prerequisites in script 02.
- Download updates from Realtek's Linux driver page (search for RTL8125/RTL8127).

---

## Prerequisites

- UEFI firmware with **Secure Boot disabled**
- Ubuntu 24.04 live USB (or any live environment with `debootstrap`, `cryptsetup`, `parted`)
- Internet connection (for `debootstrap`, Limine clone, and Incus PPA)
- Both NVMe disks with no data you want to keep

---

## Key Files

| File | Purpose |
|------|---------|
| `scripts/00-config.sh` | All configurable variables (disks, hostname, timezone, keyboard) |
| `r8127-11.016.00.tar.bz2` | RTL8127 driver source tarball |
| `limine-btrfs-review.md` | Analysis of errors in the original ChatGPT guide |
| `rcu-stall-warnings-vm.md` | Notes on RCU stall warnings in VMs |
