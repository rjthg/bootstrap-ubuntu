# Review of the ChatGPT "Ubuntu Btrfs Limine Setup" Discussion

**Source:** https://chatgpt.com/share/6997895c-adfc-800b-ad36-29588fc074b8
**Reviewed:** 2026-02-19

I've identified **several critical errors, multiple moderate issues, and some minor gaps** in the conversation. Organized from most severe to least.

---

## CRITICAL ISSUES (will break your system)

### 1. Limine CANNOT read from encrypted Btrfs — the entire kernel loading strategy is wrong

This is the single biggest problem. **Limine only supports FAT12/16/32 and ISO9660 filesystems.** It cannot read Btrfs. It cannot decrypt LUKS. Since Limine 9.0, even ext4 support was dropped.

The original guide puts the kernel on the EFI partition via symlinks:

```bash
ln -s /boot/vmlinuz-* /boot/efi/vmlinuz
ln -s /boot/initrd.img-* /boot/efi/initrd.img
```

The "corrected" version then claims this is fragile and says "Limine can load the kernel directly from /boot on your root FS" with:

```ini
KERNEL_PATH=boot:///boot/vmlinuz
```

**Both are wrong, but for different reasons:**

- The "correction" is **completely wrong**. The `boot():` URI scheme references the boot volume (the FAT32 EFI partition). `boot:///boot/vmlinuz` looks for `/boot/vmlinuz` *on the EFI partition*, not on your encrypted Btrfs root. Limine has no ability to decrypt LUKS or read Btrfs, period.
- The original symlink approach is wrong because **FAT32 does not support symbolic links**. The `ln -s` command will either fail or create a garbage file.

**What you actually need to do:**

- **Copy** (not symlink) the kernel and initramfs to the EFI partition
- Create a kernel post-install hook at `/etc/kernel/postinst.d/zz-update-limine` to automatically copy new kernels after updates
- Use `KERNEL_PATH=boot():/vmlinuz` and `INITRD_PATH=boot():/initrd.img` (or whatever paths you copy to on the ESP)

The correct approach is documented in the [Arch Wiki Limine article](https://wiki.archlinux.org/title/Limine) and in [this BTRFS+LUKS2+Limine gist](https://gist.github.com/yovko/512326b904d120f3280c163abfbcb787): the ESP is mounted at `/boot` (not `/boot/efi`), and the kernel/initramfs live directly on the FAT32 ESP.

### 2. `ubiquity --no-bootloader` does not exist on Ubuntu 24.04+

Ubuntu 24.04 LTS replaced the Ubiquity installer with the new Subiquity-based installer. The `ubiquity` command may not even exist on the live USB. The `--no-bootloader` flag has been removed with no equivalent in the new installer.

If you're installing Ubuntu 24.04 or later (which you should be for a new install), you need an alternative approach:

- Use `debootstrap` to manually bootstrap Ubuntu into your prepared partitions
- Or install Ubuntu normally with GRUB, then replace GRUB with Limine post-install
- Or use an older Ubuntu ISO (22.04) that still has Ubiquity

### 3. The `limine-uefi.zip` download URL is fabricated

The URL `https://github.com/limine-bootloader/limine/releases/latest/download/limine-uefi.zip` does not exist. There is no `limine-uefi.zip` release artifact. The Limine releases page ships source tarballs, not pre-built UEFI binaries in ZIP format.

**The correct way to get Limine binaries:**

```bash
git clone https://codeberg.org/Limine/Limine.git --branch=v10.x-binary --depth=1
```

Then copy `BOOTX64.EFI` from the cloned repo to your ESP. Note that the primary repo has moved to Codeberg, with GitHub as a mirror.

### 4. Missing kernel update hook — system will break on first `apt upgrade`

Since Limine doesn't auto-manage kernels like GRUB does, after the first kernel update via `apt upgrade`, the old kernel on the ESP will be stale and may not match the initramfs. The guide never mentions creating a post-install hook. Without this, the system will eventually fail to boot after an update.

You need something like `/etc/kernel/postinst.d/zz-update-limine`:

```bash
#!/bin/sh
cp /boot/vmlinuz-"$1" /boot/efi/vmlinuz
cp /boot/initrd.img-"$1" /boot/efi/initrd.img
```

---

## SIGNIFICANT ISSUES (will cause problems)

### 5. Two LUKS passwords at every boot — no keyfile setup

With two encrypted disks, the user will be prompted for **two separate passwords** at every boot. The guide never mentions this or how to avoid it. The standard solution is to store a keyfile for the second disk inside the initramfs:

```bash
dd if=/dev/urandom of=/etc/luks-keyfile bs=4096 count=1
chmod 600 /etc/luks-keyfile
cryptsetup luksAddKey /dev/nvme1n1p1 /etc/luks-keyfile
```

Then in `/etc/crypttab`:

```
cryptincus UUID=<UUID> /etc/luks-keyfile luks,discard
```

And add the keyfile to the initramfs via `/etc/initramfs-tools/initramfs.conf` or a hook.

### 6. Disk assignment is backwards for performance

From the `lsblk` output:

- `nvme0n1` = Crucial P510 — **PCIe Gen 5**, up to 10,000 MB/s read, **TLC NAND**
- `nvme1n1` = Crucial P310 — **PCIe Gen 4**, up to 7,100 MB/s read, **QLC NAND**

The guide puts the OS on the faster P510 and Incus on the slower P310. For LLM/container workloads, this is the wrong way around. The Incus disk will see far more I/O (container images, VM disks, model loading, snapshots) and would benefit more from the faster drive. The OS disk is mostly idle after boot.

**Recommendation:** Swap them. P510 for Incus, P310 for OS.

### 7. Incus storage pool configuration is suboptimal

The guide pre-formats the second disk with Btrfs, creates a subvolume, mounts it at `/var/lib/incus`, and then tells Incus to use that path. This works but is not the recommended approach.

According to the official Incus documentation, the best practice is to give Incus the **raw block device** and let it manage the filesystem itself:

```bash
incus storage create incus-pool btrfs source=/dev/mapper/cryptincus
```

This gives Incus full control over the Btrfs filesystem and avoids potential conflicts between host-level and Incus-level Btrfs management.

### 8. Chroot setup is incomplete

The chroot instructions mount `/dev`, `/proc`, `/sys` but are missing:

- `/run` — needed for `systemd-resolved`, D-Bus, and other runtime services
- `efivarfs` — may be needed for `efibootmgr` to work correctly inside the chroot

A more complete chroot:

```bash
mount --bind /dev  /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /run  /mnt/run
chroot /mnt
```

### 9. The `crypttab` command substitution syntax won't work

The initial version shows:

```
cryptroot UUID=$(blkid -s UUID -o value /dev/nvme0n1p2) none luks,discard
```

The `$(...)` shell substitution is **not interpreted** when written to a file via a text editor like `nano`. The user would write the literal string `$(blkid ...)` into crypttab, which would fail at boot. The later revision correctly uses `<UUID-placeholder>` notation, but the initial version could trip up a less experienced user following along sequentially.

---

## MODERATE ISSUES (misleading or exaggerated)

### 10. "LLM model files are big and compressible" — mostly wrong

The guide claims "LLM model files are big and compressible -> Btrfs zstd compression saves serious space."

This is **exaggerated**. Quantized GGUF files (Q4, Q5, Q8) are already precision-reduced and have very high entropy — they are essentially incompressible by lossless algorithms like zstd. FP16/BF16 safetensors weights are marginally compressible (maybe 5-15%). Btrfs with default `compress=zstd` will likely detect these files as incompressible and skip them automatically.

Btrfs is still the right choice for other reasons (snapshots, clones, subvolumes), but don't expect meaningful space savings from transparent compression on model files.

### 11. `autodefrag` recommendation is questionable for Incus

The guide recommends `autodefrag` for the root filesystem. For an Incus disk with VM images and heavy random writes, `autodefrag` can cause **extra write amplification** on SSDs, where fragmentation is not a meaningful performance issue anyway. On NVMe drives with no seek penalty, `autodefrag` provides negligible read benefit while increasing writes.

### 12. `space_cache=v2` and `ssd` mount options are unnecessary

Both `space_cache=v2` and `ssd` are **auto-detected defaults** on modern kernels (5.15+). Specifying them explicitly is harmless but misleading — it suggests they're special tuning when they're just the defaults already.

### 13. ROCm container config is oversimplified

The ROCm passthrough shown:

```bash
incus config device add llm dri unix-char path=/dev/dri
```

In practice, you typically need to pass specific render nodes (e.g., `/dev/dri/renderD128`) and may need to configure the `render` group GID mapping. Also, `security.privileged=true` is a significant security posture decision that deserves more nuance — modern Incus supports unprivileged GPU passthrough with `gpu` device type, which is preferred over blanket privileged mode.

### 14. Btrfs VM storage caveat not mentioned

The Incus docs note that "Btrfs doesn't natively support storing block devices" and creates large files for VM disks, which can cause snapshot issues. If the user plans to run Incus VMs (not just containers) for ROCm, ZFS might actually be a better storage backend choice. The guide doesn't discuss this tradeoff.

---

## MINOR GAPS

### 15. No mention of swap

LLM workloads can be memory-hungry. Having no swap at all means an OOM kill with no fallback. A small Btrfs swapfile requires special handling (`chattr +C`, no compression, specific subvolume). This is worth mentioning.

### 16. No mention of Secure Boot

The guide says "Secure Boot must be off" for Limine but doesn't explain how to disable it in UEFI firmware, or that this has security implications. Limine does not support Secure Boot signing out of the box.

### 17. Missing `/var/log` and `/var/cache/apt` in fstab

The initial fstab example only shows `/`, `/home`, and EFI, omitting the `@log` and `@pkg` subvolume mounts that were created. The later complete version fixes this, but an incremental reader could miss it.

### 18. Limine config syntax has changed between versions

The guide uses `PROTOCOL=linux`, `KERNEL_PATH`, `CMDLINE` etc. The exact config syntax differs between Limine v3.x, v7.x, v9.x, and v10.x. The guide doesn't specify which Limine version to install, so the config may not work with the version the user actually gets.

---

## Summary

| Severity | Count | Key Issues |
|----------|-------|------------|
| **Critical** | 4 | Limine can't read encrypted Btrfs; `ubiquity` gone in 24.04; download URL fabricated; no kernel update hook |
| **Significant** | 5 | Dual LUKS password burden; disk assignment backwards; suboptimal Incus pool; incomplete chroot; broken crypttab syntax |
| **Moderate** | 5 | Compression claims exaggerated; questionable mount options; oversimplified ROCm; missing VM caveat |
| **Minor** | 4 | No swap; no Secure Boot guidance; incomplete fstab; version-dependent config syntax |

**The overall architecture (two disks, encrypted Btrfs, Limine, Incus for containers) is sound in concept**, but the execution details contain enough critical errors that following the guide as-written would result in an unbootable system. The most dangerous part is the false confidence expressed in the "triple-checked" revision, which actually introduced a new error (the kernel path "correction") while missing the fundamental filesystem support limitation.

---

## Sources

- [Limine supported filesystems - GitHub Issue #202](https://github.com/limine-bootloader/limine/issues/202)
- [Limine ArchWiki](https://wiki.archlinux.org/title/Limine)
- [Limine 9.0 drops ext4 - Phoronix](https://www.phoronix.com/news/Limine-9.0-Released)
- [Limine Config v10.x](https://github.com/limine-bootloader/limine/blob/v10.x/CONFIG.md)
- [BTRFS+LUKS2+Limine installation guide](https://gist.github.com/yovko/512326b904d120f3280c163abfbcb787)
- [Ubuntu Subiquity replaces Ubiquity](https://answers.launchpad.net/ubuntu/+source/subiquity/+question/817666)
- [Limine releases - GitHub](https://github.com/limine-bootloader/limine/releases)
- [Crucial P510 specs](https://www.crucial.com/ssd/p510/ct2000p510ssd8)
- [Crucial P310 specs](https://www.crucial.com/ssd/p310/ct2000p310ssd8)
- [Incus Btrfs storage documentation](https://linuxcontainers.org/incus/docs/main/reference/storage_btrfs/)
- [Incus storage pool best practices](https://linuxcontainers.org/incus/docs/main/explanation/storage/)
- [Btrfs compression documentation](https://btrfs.readthedocs.io/en/latest/Compression.html)
- [Ubuntu 22.04 debootstrap install guide](https://gist.github.com/subrezon/9c04d10635ebbfb737816c5196c8ca24)
- [Debian FDE + Btrfs + debootstrap guide](https://github.com/NetBeholder/Debian-installation-guide)
- [Kernel hook scripts documentation](https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html)
- [Initramfs hook to copy kernel to ESP](https://gist.github.com/benjaminblack/0cca5bb1c5138f138de6fda95d45efd6)
- [Limine v10.x Configuration Reference](https://deepwiki.com/limine-bootloader/limine/4.1-configuration-file)
- [Incus Zabbly packages for Ubuntu](https://github.com/zabbly/incus)

---
---

# CORRECTED GUIDE: Ubuntu 24.04 + Encrypted Btrfs + Limine + Incus (2 Disks)

This section provides the **correct, detailed steps** to achieve what the ChatGPT conversation was aiming for, with all the issues identified above fixed. It is written for someone who may not have done a manual Linux installation before.

Accompanying scripts are in the `~/limine-ubuntu-scripts/` directory.

---

## Overview: What We Are Building

```
Disk 1: nvme1n1 (Crucial P310, PCIe Gen4, 2TB) — OS DISK
├── p1: EFI System Partition (1 GiB, FAT32, unencrypted)
│   ├── EFI/limine/BOOTX64.EFI    ← Limine bootloader
│   ├── EFI/BOOT/BOOTX64.EFI      ← fallback boot
│   ├── vmlinuz                    ← kernel (COPIED here, not symlinked)
│   ├── initrd.img                 ← initramfs (COPIED here)
│   └── limine.conf                ← Limine configuration
└── p2: LUKS2-encrypted partition (rest of disk)
    └── Btrfs filesystem
        ├── @        → /
        ├── @home    → /home
        ├── @log     → /var/log
        ├── @pkg     → /var/cache/apt
        └── @swap    → /swap (swapfile lives here)

Disk 2: nvme0n1 (Crucial P510, PCIe Gen5, 2TB) — INCUS DISK
└── p1: LUKS2-encrypted partition (entire disk)
    └── Btrfs filesystem (managed by Incus directly)
        └── Incus storage pool "incus-pool"
            ├── containers/
            ├── images/
            └── snapshots/
```

### Key Differences from the ChatGPT Guide

| What | ChatGPT Said | Correct Approach |
|------|-------------|-----------------|
| **Disk assignment** | P510 for OS, P310 for Incus | **P310 for OS, P510 for Incus** — Incus benefits more from faster I/O |
| **Kernel location** | Symlinked or read from encrypted Btrfs | **Copied to FAT32 ESP** — Limine can only read FAT32 |
| **Kernel updates** | Not mentioned | **Post-install hooks** automatically copy new kernels to ESP |
| **Ubuntu installer** | `ubiquity --no-bootloader` | **debootstrap** — ubiquity doesn't exist in Ubuntu 24.04+ |
| **Limine download** | `limine-uefi.zip` (doesn't exist) | **`git clone --branch=v10.x-binary`** from Codeberg |
| **Limine config** | Old v3-v7 syntax | **v10.x syntax** (`/Entry`, `protocol=linux`, `path=`) |
| **Second disk unlock** | Two password prompts | **LUKS keyfile** in initramfs for automatic unlock |
| **Incus storage** | Pre-format + mount at /var/lib/incus | **Give Incus the raw block device** to manage directly |
| **Chroot setup** | Missing /run, /dev/pts | **Complete bind mount set** including /run and /dev/pts |
| **Swap** | Not mentioned | **Btrfs swapfile** with proper nocow attribute |

---

## Prerequisites

- **Ubuntu 24.04 Desktop or Server live USB** (download from [ubuntu.com](https://ubuntu.com/download))
- **Two NVMe SSDs** (the guide uses nvme0n1 and nvme1n1 — verify yours with `lsblk`)
- **Internet connection** during installation (for debootstrap)
- **Secure Boot disabled** in your UEFI firmware settings (Limine doesn't support it)
- **A way to read this guide** while installing (phone, second computer, or print it)

---

## Phase 1: Preparation (Before You Start)

### 1.1 Boot the Ubuntu Live USB

1. Download Ubuntu 24.04 LTS ISO from [ubuntu.com](https://ubuntu.com/download)
2. Flash it to a USB drive using [Balena Etcher](https://etcher.balena.io/) or `dd`
3. Boot your computer from the USB
4. Choose **"Try Ubuntu"** (do NOT click "Install Ubuntu")
5. Open a terminal (Ctrl+Alt+T)

### 1.2 Verify Your Disks

This is the most important step. Getting the wrong disk will destroy data.

```bash
lsblk -o NAME,SIZE,MODEL,TYPE
```

You should see something like:
```
nvme0n1    1.8T CT2000P510SSD8   disk    ← This is the FASTER disk (Gen5)
nvme1n1    1.8T CT2000P310SSD8   disk    ← This is the SLOWER disk (Gen4)
```

**Write down which is which.** In our scripts:
- **P310 (slower) = OS disk** — the OS doesn't need blazing I/O
- **P510 (faster) = Incus disk** — containers, VMs, and LLM models benefit from speed

### 1.3 Disable Secure Boot

1. Reboot and enter UEFI firmware settings (usually Del, F2, or F12 at startup)
2. Find the Secure Boot option (usually under "Security" or "Boot")
3. Set it to **Disabled**
4. Save and exit
5. Boot back into the Ubuntu live USB

### 1.4 Get the Install Scripts

Copy the `limine-ubuntu-scripts/` directory to the live USB environment. You can use a second USB drive, or download them. Once you have them available, open a terminal and navigate to the script directory.

### 1.5 Edit the Configuration

Open `00-config.sh` and verify/edit the disk assignments:

```bash
nano 00-config.sh
```

The critical variables are:
```bash
OS_DISK="/dev/nvme1n1"        # P310 — confirm with lsblk
INCUS_DISK="/dev/nvme0n1"     # P510 — confirm with lsblk
```

Also set your timezone (default is UTC) and hostname if desired.

---

## Phase 2: Partition, Encrypt, and Format (Script 01)

```bash
sudo bash 01-partition-and-encrypt.sh
```

### What This Script Does

1. **Wipes both disks** (after confirmation prompt)
2. **Partitions the OS disk:**
   - Partition 1: 1 GiB EFI System Partition (FAT32)
   - Partition 2: Rest of disk for LUKS encryption
3. **Partitions the Incus disk:**
   - Partition 1: Entire disk for LUKS encryption
4. **Encrypts both partitions** with LUKS2 (you choose passphrases)
5. **Creates Btrfs** filesystems on both encrypted volumes
6. **Creates subvolumes** on the OS disk: `@`, `@home`, `@log`, `@pkg`, `@swap`
7. **Mounts everything** at `/mnt` ready for installation

### Why 1 GiB for EFI?

The ChatGPT guide also used 1 GiB which is correct. Since the kernel (~12 MB) and initramfs (~80 MB) must live on the ESP, 1 GiB gives room for multiple kernel versions and Limine files.

### What About the Incus Disk Subvolumes?

We intentionally do NOT create subvolumes on the Incus disk. Incus will manage its own Btrfs subvolumes when we give it the block device later. Pre-creating subvolumes would conflict with Incus's internal management.

---

## Phase 3: Install Ubuntu Base System (Script 02)

```bash
sudo bash 02-install-ubuntu.sh
```

### What This Script Does

1. **Installs debootstrap** if not already available on the live USB
2. **Bootstraps Ubuntu 24.04 ("noble")** into `/mnt` using debootstrap
3. **Generates `/etc/fstab`** with correct UUIDs and Btrfs mount options
4. **Generates `/etc/crypttab`** with correct UUIDs (no shell substitution bugs)
5. **Sets up APT sources** for noble
6. **Sets up the chroot** environment (complete bind mounts including `/run` and `/dev/pts`)
7. **Installs essential packages** inside the chroot:
   - `linux-image-generic` — the kernel
   - `linux-headers-generic` — needed for DKMS/ROCm drivers
   - `linux-firmware` — hardware firmware
   - `initramfs-tools` — builds the initramfs
   - `cryptsetup` + `cryptsetup-initramfs` — LUKS support in initramfs (**critical!**)
   - `btrfs-progs` — Btrfs tools
   - `efibootmgr` — UEFI boot entry manager
   - `network-manager` — networking
   - And other essentials
8. **Configures locale, timezone, hostname**
9. **Creates a user account** (prompts for username and password)

### Why debootstrap Instead of the Ubuntu Installer?

The ChatGPT guide used `ubiquity --no-bootloader`, but:
- Ubuntu 24.04 replaced Ubiquity with the Subiquity installer
- Subiquity has no `--no-bootloader` equivalent
- Subiquity doesn't support pre-prepared encrypted Btrfs layouts

`debootstrap` gives us full control. It downloads and unpacks the base Ubuntu packages directly into our prepared filesystem. It's the same tool Ubuntu's own installers use internally.

### Why is `cryptsetup-initramfs` So Important?

Without this package, the initramfs (the mini-system that runs before your real OS) will NOT contain the tools needed to ask for your LUKS password and unlock the disk. Your system would fail to boot with a confusing "unable to find root filesystem" error.

---

## Phase 4: Configure System (Script 03)

```bash
sudo bash 03-configure-system.sh
```

### What This Script Does

1. **Creates a LUKS keyfile** for the Incus disk:
   - Generates a random 4096-byte keyfile
   - Stores it at `/etc/luks-incus-keyfile` (on the encrypted root)
   - Adds it to the Incus disk's LUKS header
   - Updates `/etc/crypttab` to use the keyfile

   This means at boot, you type ONE password (for the OS disk), and the Incus disk unlocks automatically via the keyfile stored in the initramfs.

2. **Creates an initramfs hook** that includes the keyfile in the initramfs

3. **Sets up a Btrfs swapfile:**
   - Creates a 4 GiB swapfile in the `@swap` subvolume
   - Properly disables COW on the swapfile (required for Btrfs)
   - Adds it to fstab

4. **Rebuilds the initramfs** with all configuration included

5. **Verifies** that cryptsetup and the keyfile are present in the initramfs

---

## Phase 5: Install Limine Bootloader (Script 04)

```bash
sudo bash 04-install-limine.sh
```

### What This Script Does

1. **Downloads Limine v10.x** pre-built binaries from Codeberg using:
   ```bash
   git clone https://codeberg.org/Limine/Limine.git --branch=v10.x-binary --depth=1
   ```
   (The ChatGPT guide used a non-existent `limine-uefi.zip` URL)

2. **Installs `BOOTX64.EFI`** to two locations on the ESP:
   - `EFI/limine/BOOTX64.EFI` — primary boot path
   - `EFI/BOOT/BOOTX64.EFI` — fallback (in case UEFI entries get wiped)

3. **COPIES kernel and initramfs** to the ESP:
   ```bash
   cp /boot/vmlinuz-$VERSION   /boot/efi/vmlinuz
   cp /boot/initrd.img-$VERSION /boot/efi/initrd.img
   ```
   This is the critical fix. Limine can ONLY read FAT32. It cannot read Btrfs or LUKS. The kernel must be on the ESP.

4. **Creates `limine.conf`** using correct v10.x syntax:
   ```ini
   timeout=5

   /Ubuntu (Encrypted Btrfs)
       protocol=linux
       path=boot():/vmlinuz
       module_path=boot():/initrd.img
       cmdline=root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash
   ```

   Note: `boot():/vmlinuz` means "the file `vmlinuz` on the partition where Limine's config was found" — i.e., the FAT32 ESP. It does NOT mean the root filesystem.

5. **Installs THREE kernel update hooks:**
   - `/etc/kernel/postinst.d/zz-update-limine` — runs after kernel install
   - `/etc/kernel/postrm.d/zz-update-limine` — runs after kernel removal
   - `/etc/initramfs/post-update.d/zz-update-limine` — runs after initramfs rebuild

   These hooks automatically copy the latest kernel to the ESP whenever it changes. Without them, the first `apt upgrade` that installs a new kernel would leave the system unbootable.

6. **Registers Limine** in the UEFI boot manager via `efibootmgr`

---

## Phase 6: Reboot

```bash
# If you're inside the chroot, exit first
exit

# Unmount everything
umount -R /mnt

# Reboot
reboot
```

### What Should Happen at Boot

1. **LUKS password prompt** — Enter the OS disk passphrase
2. **Incus disk unlocks automatically** via the keyfile (no second prompt)
3. **Limine boot menu** appears with "Ubuntu (Encrypted Btrfs)"
4. **Ubuntu boots** into your new system
5. Log in with the username and password you created

### Troubleshooting Boot Problems

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Black screen, no boot menu | Secure Boot is still on | Disable in UEFI firmware |
| "No bootable device" | UEFI entry not set | Boot from USB, chroot in, re-run `efibootmgr` |
| LUKS prompt never appears | `cryptsetup-initramfs` missing | Boot from USB, chroot in, `apt install cryptsetup-initramfs && update-initramfs -u -k all`, copy new initramfs to ESP |
| "unable to find root" | initramfs doesn't have LUKS support | Same fix as above |
| Second LUKS prompt | Keyfile not in initramfs | Check `/etc/initramfs-tools/hooks/luks-keyfile` exists and is executable, rebuild initramfs |
| Kernel panic | Wrong kernel cmdline | Boot from USB, mount ESP, edit `limine.conf`, verify `root=/dev/mapper/cryptroot` |
| Old kernel after update | Update hooks not installed | Check scripts exist in `/etc/kernel/postinst.d/` and are executable |

---

## Phase 7: Post-Boot Setup (Script 05)

After successfully booting into your new system:

```bash
sudo bash 05-post-boot-setup.sh
```

### What This Script Does

1. **Installs Incus** from the official Zabbly repository
2. **Creates the Incus storage pool** using the dedicated encrypted disk:
   ```bash
   incus storage create incus-pool btrfs source=/dev/mapper/cryptincus
   ```
   This gives Incus direct control over the Btrfs filesystem (recommended approach).
3. **Initializes Incus** with a default network bridge
4. **Prints ROCm setup instructions** for GPU passthrough to containers

### ROCm in Incus Containers

The ChatGPT guide suggested:
```bash
incus config set llm security.privileged=true
incus config device add llm kfd unix-char path=/dev/kfd
incus config device add llm dri unix-char path=/dev/dri
```

The **preferred modern approach** uses the `gpu` device type, which avoids running the container in privileged mode:

```bash
# Create a container
incus launch ubuntu:24.04 llm-container

# Pass through all GPUs using the gpu device type
incus config device add llm-container gpu gpu \
    gid=$(getent group render | cut -d: -f3)
```

Only fall back to `security.privileged=true` if the `gpu` device type doesn't work for your specific ROCm version.

### A Note on VMs vs Containers with Btrfs

The Incus documentation warns that **Btrfs doesn't natively support block device storage**, so VM disk images are stored as regular files. This can cause performance issues and snapshot problems for VMs.

If you plan to primarily use **Incus VMs** (not containers) for ROCm, consider using **ZFS** instead of Btrfs for the Incus disk. ZFS handles VM disk images natively.

For **containers** (which is likely your use case for LLM servers), Btrfs works well.

---

## Script Reference

All scripts are in `~/limine-ubuntu-scripts/`:

| Script | Purpose | Run From |
|--------|---------|----------|
| `00-config.sh` | Shared variables — edit before running anything | N/A (sourced) |
| `01-partition-and-encrypt.sh` | Wipe, partition, encrypt, format, mount | Live USB |
| `02-install-ubuntu.sh` | debootstrap + packages + user creation | Live USB |
| `03-configure-system.sh` | Keyfile, swap, initramfs | Live USB |
| `04-install-limine.sh` | Download Limine, configure, install hooks | Live USB |
| `05-post-boot-setup.sh` | Incus, storage pool, ROCm prep | Installed system |

Run them in order. Each script checks prerequisites from the previous step.

---

## Maintenance: After Installation

### Kernel Updates

Kernel updates via `apt upgrade` are handled automatically by the hooks installed in Phase 5. After a kernel update:

1. `apt` installs new kernel to `/boot/vmlinuz-<version>`
2. `update-initramfs` rebuilds the initramfs
3. The hooks automatically copy both to the ESP
4. Next reboot uses the new kernel

You can verify the ESP has the correct kernel:

```bash
ls -la /boot/efi/vmlinuz /boot/efi/initrd.img
file /boot/efi/vmlinuz
```

### Btrfs Snapshots (Rollback Before Risky Changes)

Before installing ROCm or other risky software:

```bash
# Create a read-only snapshot of your root
sudo btrfs subvolume snapshot -r / /home/snapshots/pre-rocm-$(date +%Y%m%d)

# If things break, you can roll back by booting from live USB,
# mounting the Btrfs volume, and replacing @ with the snapshot.
```

Consider installing [Timeshift](https://github.com/linuxmint/timeshift) or [Snapper](https://github.com/openSUSE/snapper) for automated snapshot management.

### Incus Container Management

```bash
# Create a container
incus launch ubuntu:24.04 my-llm

# List containers
incus list

# Snapshot before changes
incus snapshot create my-llm clean-state

# Restore if things break
incus snapshot restore my-llm clean-state

# Delete a snapshot
incus snapshot delete my-llm clean-state
```
