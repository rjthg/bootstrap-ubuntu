#!/usr/bin/env bash
# =============================================================================
# 01-partition-and-encrypt.sh
# =============================================================================
# This script:
#   1. Wipes both NVMe drives
#   2. Creates GPT partition tables
#   3. Creates an EFI partition on the OS disk
#   4. Creates LUKS-encrypted partitions on both disks
#   5. Creates Btrfs filesystems and subvolumes
#   6. Mounts everything at /mnt ready for debootstrap
#
# Run this from the Ubuntu live USB environment ("Try Ubuntu").
# You need an internet connection for later steps.
#
# Usage:
#   sudo bash 01-partition-and-encrypt.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

require_root

echo ""
echo "Current disk layout:"
echo ""
lsblk -o NAME,SIZE,MODEL,TYPE
echo ""

# Verify neither disk is currently mounted or has open LUKS mappers.
# Running wipefs on an active disk leaves the system in inconsistent state.
for _disk in "$OS_DISK" "$INCUS_DISK"; do
    if lsblk -no MOUNTPOINT "$_disk" 2>/dev/null | grep -q '[^[:space:]]'; then
        echo "ERROR: $_disk has mounted partitions. Unmount everything and try again."
        lsblk "$_disk"
        exit 1
    fi
done
unset _disk

confirm_destructive \
    "This will ERASE ALL DATA on:
    - $OS_DISK (OS disk)
    - $INCUS_DISK (Incus disk)

Double-check the disk names above with the lsblk output."

# ─── Step 1: Wipe both disks ─────────────────────────────────────────────────

step "Wiping disk signatures"

wipefs -af "$OS_DISK"
wipefs -af "$INCUS_DISK"

echo "Done. Both disks wiped."

# ─── Step 2: Partition the OS disk ───────────────────────────────────────────

step "Partitioning OS disk ($OS_DISK)"

# Create GPT partition table
parted "$OS_DISK" -- mklabel gpt

# Partition 1: EFI System Partition (1 GiB)
# 1 GiB is generous but gives room for multiple kernels + Limine.
parted "$OS_DISK" -- mkpart ESP fat32 1MiB 1025MiB
parted "$OS_DISK" -- set 1 esp on

# Partition 2: LUKS root (rest of the disk)
parted "$OS_DISK" -- mkpart cryptroot 1025MiB 100%

echo "OS disk partitioned:"
lsblk "$OS_DISK"

# ─── Step 3: Partition the Incus disk ────────────────────────────────────────

step "Partitioning Incus disk ($INCUS_DISK)"

# Create GPT partition table
parted "$INCUS_DISK" -- mklabel gpt

# Single partition using the entire disk
parted "$INCUS_DISK" -- mkpart cryptincus 1MiB 100%

echo "Incus disk partitioned:"
lsblk "$INCUS_DISK"

# ─── Step 4: Format EFI partition ────────────────────────────────────────────

step "Formatting EFI partition ($EFI_PART)"

mkfs.fat -F32 -n EFI "$EFI_PART"

echo "EFI partition formatted as FAT32."

# ─── Step 5: Encrypt the root partition ──────────────────────────────────────

step "Encrypting root partition ($ROOT_PART)"

echo "You will be asked to create a passphrase for the OS disk."
echo "Choose a strong passphrase and remember it — you will type it at every boot."
echo ""

cryptsetup luksFormat --type luks2 "$ROOT_PART"
cryptsetup open "$ROOT_PART" "$ROOT_MAPPER"

echo "Root partition encrypted and opened as /dev/mapper/$ROOT_MAPPER"

# ─── Step 6: Encrypt the Incus partition ─────────────────────────────────────

step "Encrypting Incus partition ($INCUS_PART)"

echo "You will be asked to create a passphrase for the Incus disk."
echo ""
echo "TIP: You can use the same passphrase as the OS disk for now."
echo "     Later (in script 03), we will set up a keyfile so only"
echo "     the OS disk password is needed at boot."
echo ""

cryptsetup luksFormat --type luks2 "$INCUS_PART"
cryptsetup open "$INCUS_PART" "$INCUS_MAPPER"

echo "Incus partition encrypted and opened as /dev/mapper/$INCUS_MAPPER"

# ─── Step 7: Create Btrfs on OS disk ────────────────────────────────────────

step "Creating Btrfs filesystem on OS disk"

mkfs.btrfs -f -L ubuntu-root /dev/mapper/"$ROOT_MAPPER"

# Mount the top-level subvolume temporarily to create our subvolumes
mount /dev/mapper/"$ROOT_MAPPER" "$TARGET"

echo "Creating Btrfs subvolumes..."
btrfs subvolume create "$TARGET/$SUBVOL_ROOT"
btrfs subvolume create "$TARGET/$SUBVOL_HOME"
btrfs subvolume create "$TARGET/$SUBVOL_LOG"
btrfs subvolume create "$TARGET/$SUBVOL_PKG"
btrfs subvolume create "$TARGET/$SUBVOL_SWAP"

echo "Subvolumes created:"
btrfs subvolume list "$TARGET"

umount "$TARGET"

# ─── Step 8: Mount everything for installation ──────────────────────────────

step "Mounting filesystem layout at $TARGET"

# Mount root subvolume
mount -o "$BTRFS_OPTS,subvol=$SUBVOL_ROOT" /dev/mapper/"$ROOT_MAPPER" "$TARGET"

# Create mount point directories
mkdir -p "$TARGET"/{home,var/log,var/cache/apt,boot/efi}

# Mount other subvolumes
mount -o "$BTRFS_OPTS,subvol=$SUBVOL_HOME" /dev/mapper/"$ROOT_MAPPER" "$TARGET/home"
mount -o "$BTRFS_OPTS,subvol=$SUBVOL_LOG"  /dev/mapper/"$ROOT_MAPPER" "$TARGET/var/log"
mount -o "$BTRFS_OPTS,subvol=$SUBVOL_PKG"  /dev/mapper/"$ROOT_MAPPER" "$TARGET/var/cache/apt"

# Mount EFI partition
# We mount at /boot/efi (not /boot) because /boot itself will be on the
# encrypted Btrfs root. The kernel lives in /boot on the root FS and gets
# COPIED to the EFI partition by our update hook.
mount "$EFI_PART" "$TARGET/boot/efi"

echo ""
echo "Filesystem layout mounted:"
echo ""
findmnt --target "$TARGET" --real
echo ""
echo "============================================"
echo "  PARTITIONING AND ENCRYPTION COMPLETE"
echo "============================================"
echo ""
echo "Next step: Run 02-install-ubuntu.sh"
echo ""
