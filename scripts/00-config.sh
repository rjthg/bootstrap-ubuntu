#!/usr/bin/env bash
# =============================================================================
# 00-config.sh — Shared configuration for all install scripts
# =============================================================================
# This file is sourced by the other scripts. Edit the variables below to match
# your hardware. DO NOT run this file directly.
#
# Disks are auto-detected by model name. If detection fails, the scripts will
# print the available devices and exit before touching anything.
# =============================================================================

# --- Disk Assignment (auto-detected by model name) ---
# P310 (PCIe Gen4) → OS disk   P510 (PCIe Gen5) → Incus disk
# If your hardware differs, replace the two lines below with explicit paths,
# e.g.:  OS_DISK="/dev/nvme1n1"   INCUS_DISK="/dev/nvme0n1"

OS_DISK=$(lsblk -d -o NAME,MODEL --noheadings 2>/dev/null \
    | awk '/P310/{print "/dev/"$1; exit}')
INCUS_DISK=$(lsblk -d -o NAME,MODEL --noheadings 2>/dev/null \
    | awk '/P510/{print "/dev/"$1; exit}')

if [[ -z "$OS_DISK" || -z "$INCUS_DISK" ]]; then
    echo ""
    echo "ERROR: Could not auto-detect one or both disks."
    echo "       Detected block devices:"
    lsblk -d -o NAME,SIZE,MODEL
    echo ""
    echo "  Expected a disk with 'P310' in the model name → OS_DISK"
    echo "  Expected a disk with 'P510' in the model name → INCUS_DISK"
    echo "  Set these manually at the top of 00-config.sh."
    exit 1
fi

if [[ "$OS_DISK" == "$INCUS_DISK" ]]; then
    echo "ERROR: OS_DISK and INCUS_DISK resolved to the same device ($OS_DISK)."
    echo "       Check the model name patterns in 00-config.sh."
    exit 1
fi

echo "Disk auto-detection:"
echo "  OS disk (P310):    $OS_DISK"
echo "  Incus disk (P510): $INCUS_DISK"

# --- Partition Names (derived from above, edit if your layout differs) ---
# OS disk partitions
EFI_PART="${OS_DISK}p1"       # EFI System Partition (1 GiB, FAT32)
ROOT_PART="${OS_DISK}p2"      # LUKS-encrypted root (rest of disk)

# Incus disk partition (single partition, entire disk)
INCUS_PART="${INCUS_DISK}p1"

# --- LUKS mapper names ---
ROOT_MAPPER="cryptroot"
INCUS_MAPPER="cryptincus"

# --- Mount point used during installation ---
TARGET="/mnt"

# --- Ubuntu release ---
UBUNTU_RELEASE="questing"      # Ubuntu 25.10
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"

# --- Btrfs subvolume names ---
# These are the subvolumes that will be created on the OS disk.
# Standard layout compatible with Timeshift and Snapper.
SUBVOL_ROOT="@"
SUBVOL_HOME="@home"
SUBVOL_LOG="@log"
SUBVOL_PKG="@pkg"
SUBVOL_SWAP="@swap"

# --- Btrfs mount options ---
# Do NOT add space_cache=v2 or ssd — they are auto-detected on modern kernels.
BTRFS_OPTS="compress=zstd:3,noatime"

# --- Hostname ---
HOSTNAME="osaka"

# --- Timezone ---
# Find your timezone name with: timedatectl list-timezones | grep <City>
TIMEZONE="Europe/London"

# --- Keyboard layout ---
# XKBMODEL: keyboard hardware model. Use "macintosh" for Apple Mac keyboards,
#           "pc105" for a standard PC keyboard.
# XKBLAYOUT: layout code. "gb" = British English, "us" = US English, etc.
# XKBVARIANT: layout variant. Leave empty for the default variant.
# Run "localectl list-x11-keymap-models" / "list-x11-keymap-layouts" for options.
XKBMODEL="macintosh"
XKBLAYOUT="gb"
XKBVARIANT=""
XKBOPTIONS=""

# --- Helper function: confirm before destructive operations ---
confirm_destructive() {
    local msg="$1"
    # Require an interactive terminal — piping "YES" in bypasses the safety review.
    if [[ ! -t 0 ]]; then
        echo "ERROR: This script requires an interactive terminal for destructive confirmations."
        echo "       Do not pipe or redirect stdin to this script."
        exit 1
    fi
    echo ""
    echo "============================================"
    echo "  WARNING: DESTRUCTIVE OPERATION"
    echo "============================================"
    echo ""
    echo "$msg"
    echo ""
    read -rp "Type YES (all caps) to continue: " answer
    if [[ "$answer" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi
}

# --- Helper function: print a step header ---
step() {
    echo ""
    echo "========================================"
    echo "  STEP: $1"
    echo "========================================"
    echo ""
}

# --- Helper function: check if running as root ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (use sudo)."
        exit 1
    fi
}
