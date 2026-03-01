#!/usr/bin/env bash
# =============================================================================
# 04-install-limine.sh
# =============================================================================
# This script:
#   1. Downloads Limine v10.x pre-built binaries
#   2. Installs BOOTX64.EFI to the EFI System Partition
#   3. Creates limine.conf with the correct kernel path
#   4. COPIES (not symlinks!) the kernel and initramfs to the ESP
#   5. Installs kernel update hooks so future apt upgrades stay bootable
#   6. Registers Limine in the UEFI boot manager
#
# Prerequisites:
#   - Scripts 01-03 have been run successfully
#   - Chroot bind mounts are still active
#
# Usage:
#   sudo bash 04-install-limine.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

require_root

# ─── Step 1: Download Limine ────────────────────────────────────────────────

step "Downloading Limine v10.x binaries"

echo "Cloning Limine binary release from Codeberg..."
echo ""

# Clone into a temporary directory. Register cleanup on exit so the temp dir
# is always removed even if git clone fails partway through.
LIMINE_TMP=$(mktemp -d)
trap 'rm -rf "$LIMINE_TMP"' EXIT

git clone https://codeberg.org/Limine/Limine.git \
    --branch=v10.x-binary --depth=1 \
    "$LIMINE_TMP" || {
    echo ""
    echo "ERROR: git clone failed. Check your internet connection."
    echo "       Source: https://codeberg.org/Limine/Limine.git (branch v10.x-binary)"
    exit 1
}

echo "Limine downloaded to $LIMINE_TMP"
ls -la "$LIMINE_TMP/"

# ─── Step 2: Install Limine to ESP ──────────────────────────────────────────

step "Installing Limine to EFI System Partition"

# Create the Limine directory on the ESP
mkdir -p "$TARGET/boot/efi/EFI/limine"
mkdir -p "$TARGET/boot/efi/EFI/BOOT"

# Validate the UEFI binary before installing it.
# A missing or truncated file produces a system that silently fails to boot.
BOOTX64="$LIMINE_TMP/BOOTX64.EFI"
if [[ ! -f "$BOOTX64" ]]; then
    echo "ERROR: BOOTX64.EFI not found at $BOOTX64"
    echo "       The v10.x-binary branch stores all files at the repo root (no bin/ subdir)."
    echo "       List of files in the cloned repo:"
    ls -la "$LIMINE_TMP/"
    exit 1
fi
BOOTX64_SIZE=$(stat -c %s "$BOOTX64")
if [[ "$BOOTX64_SIZE" -lt 65536 ]]; then
    echo "ERROR: BOOTX64.EFI is only ${BOOTX64_SIZE} bytes — file appears truncated or corrupted."
    exit 1
fi

# Copy the UEFI binary — BOOTX64.EFI is for x86_64 UEFI systems.
cp "$BOOTX64" "$TARGET/boot/efi/EFI/limine/"

# Also install as the fallback bootloader (EFI/BOOT/BOOTX64.EFI).
# This ensures the system boots even if UEFI entries get wiped.
cp "$BOOTX64" "$TARGET/boot/efi/EFI/BOOT/"

echo "Limine UEFI binary installed."
# Temp dir is cleaned up by the EXIT trap set during clone.

# ─── Step 3: Copy kernel and initramfs to ESP ────────────────────────────────

step "Copying kernel and initramfs to EFI partition"

echo "Limine can only read FAT32 — the kernel and initramfs must be on the ESP."
echo ""

# Find the latest kernel version
KERNEL_VER=$(ls "$TARGET"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed "s|$TARGET/boot/vmlinuz-||")
if [[ -z "$KERNEL_VER" ]]; then
    echo "ERROR: No kernel found in $TARGET/boot. Was linux-image-generic installed in script 02?"
    exit 1
fi

echo "Latest kernel version: $KERNEL_VER"

# COPY the kernel and initramfs to the ESP — current and .old slots.
# Seeding .old with the same kernel means the "previous kernel" Limine entry
# works from first boot. After the first kernel update, .old will diverge.
cp "$TARGET/boot/vmlinuz-$KERNEL_VER"   "$TARGET/boot/efi/vmlinuz"
cp "$TARGET/boot/initrd.img-$KERNEL_VER" "$TARGET/boot/efi/initrd.img"
cp "$TARGET/boot/vmlinuz-$KERNEL_VER"   "$TARGET/boot/efi/vmlinuz.old"
cp "$TARGET/boot/initrd.img-$KERNEL_VER" "$TARGET/boot/efi/initrd.img.old"

echo "Kernel and initramfs copied to ESP (current and .old slots)."

# ─── Step 4: Create limine.conf ─────────────────────────────────────────────

step "Creating Limine configuration"

echo "Creating limine.conf using Limine v10.x syntax..."
echo ""

cat > "$TARGET/boot/efi/limine.conf" << EOF
# Limine bootloader configuration — v10.x syntax (key: value, NOT key=value)
# Docs: https://codeberg.org/Limine/Limine/src/branch/v10.x/CONFIG.md
#
# IMPORTANT NOTES:
# - boot():/ refers to the volume this config was loaded from (the ESP/FAT32),
#   NOT the root filesystem
# - The kernel and initramfs are COPIED here by the update hooks
# - Limine CANNOT read Btrfs or LUKS — everything it needs must be on FAT32
#
# Two entries are kept at all times:
#   vmlinuz / initrd.img      — the current kernel (updated by apt)
#   vmlinuz.old / initrd.img.old — the previous kernel (rollback target)
# If the current kernel does not boot, select "Ubuntu (previous kernel)" here.

timeout: 5

/Ubuntu (Encrypted Btrfs)
    PROTOCOL: linux
    PATH: boot():/vmlinuz
    MODULE_PATH: boot():/initrd.img
    CMDLINE: root=/dev/mapper/$ROOT_MAPPER rootflags=subvol=$SUBVOL_ROOT rw quiet splash

/Ubuntu (previous kernel)
    PROTOCOL: linux
    PATH: boot():/vmlinuz.old
    MODULE_PATH: boot():/initrd.img.old
    CMDLINE: root=/dev/mapper/$ROOT_MAPPER rootflags=subvol=$SUBVOL_ROOT rw quiet splash
EOF

echo "limine.conf created:"
cat "$TARGET/boot/efi/limine.conf"
echo ""

# Also place a copy in EFI/limine/ as a fallback location
cp "$TARGET/boot/efi/limine.conf" "$TARGET/boot/efi/EFI/limine/limine.conf"
cp "$TARGET/boot/efi/limine.conf" "$TARGET/boot/efi/EFI/BOOT/limine.conf"

# ─── Step 5: Install kernel update hooks ────────────────────────────────────

step "Installing kernel update hooks"

echo "These hooks ensure that whenever a kernel is updated via apt,"
echo "the new kernel and initramfs are automatically copied to the ESP."
echo ""

# --- Post-install hook (runs after a new kernel is installed) ---
mkdir -p "$TARGET/etc/kernel/postinst.d"

cat > "$TARGET/etc/kernel/postinst.d/zz-update-limine" << 'EOF'
#!/bin/sh
# Kernel post-install hook for Limine bootloader
#
# This hook intentionally does NOT write to the ESP. The
# /etc/initramfs/post-update.d/zz-update-limine hook runs after both the
# kernel AND initramfs are fully built, and handles the ESP update atomically
# (rotate current → .old, then install new pair). Writing the kernel here
# without the matching initramfs would leave the ESP in a mismatched state.
#
# Nothing to do — post-update.d handles it.
exit 0
EOF

chmod +x "$TARGET/etc/kernel/postinst.d/zz-update-limine"

# --- Post-remove hook (runs after a kernel is removed) ---
# When the current kernel is removed, update ESP with the latest remaining kernel.
mkdir -p "$TARGET/etc/kernel/postrm.d"

cat > "$TARGET/etc/kernel/postrm.d/zz-update-limine" << 'EOF'
#!/bin/sh
# Kernel post-remove hook for Limine bootloader
#
# After a kernel is removed, populate both ESP slots with the remaining
# installed kernels (latest → current, second-latest → .old).
# If only one kernel remains, both slots get the same kernel so the
# "previous kernel" entry still boots.

set -e

ESP="/boot/efi"

if ! mountpoint -q "$ESP"; then
    echo "WARNING: ESP not mounted at $ESP — skipping Limine update after kernel removal."
    echo "         Mount the ESP manually and run: update-initramfs -u -k all"
    exit 0
fi

# List all remaining kernels, newest first
KERNELS=$(ls /boot/vmlinuz-* 2>/dev/null | sort -Vr)

if [ -z "$KERNELS" ]; then
    echo "WARNING: No kernels found in /boot after removal!"
    exit 1
fi

LATEST_VER=$(echo "$KERNELS" | head -1 | sed 's|/boot/vmlinuz-||')
PREV_VER=$(echo "$KERNELS" | sed -n '2p' | sed 's|/boot/vmlinuz-||')
# If only one kernel remains, use it for both slots
if [ -z "$PREV_VER" ]; then
    PREV_VER="$LATEST_VER"
fi

echo "Limine: Updating ESP after kernel removal..."
echo "  current slot → $LATEST_VER"
echo "  .old slot    → $PREV_VER"

cp -f "/boot/vmlinuz-${LATEST_VER}"    "$ESP/vmlinuz"
cp -f "/boot/initrd.img-${LATEST_VER}" "$ESP/initrd.img"
cp -f "/boot/vmlinuz-${PREV_VER}"      "$ESP/vmlinuz.old"
cp -f "/boot/initrd.img-${PREV_VER}"   "$ESP/initrd.img.old"

echo "Limine: ESP updated."
EOF

chmod +x "$TARGET/etc/kernel/postrm.d/zz-update-limine"

# --- Initramfs post-update hook ---
# Also copy when initramfs is rebuilt (e.g., after driver installs)
mkdir -p "$TARGET/etc/initramfs/post-update.d"

cat > "$TARGET/etc/initramfs/post-update.d/zz-update-limine" << 'EOF'
#!/bin/sh
# Initramfs post-update hook for Limine bootloader
#
# Arguments: $1 = kernel version, $2 = initramfs path
#
# This hook runs after BOTH the kernel and initramfs are fully available.
# It rotates the current ESP pair → .old slots, then installs the new pair.
# The .old slots give a bootable fallback if the new kernel does not work.
# Select "Ubuntu (previous kernel)" in the Limine menu to use the rollback.

set -e

KERNEL_VERSION="$1"
ESP="/boot/efi"

if ! mountpoint -q "$ESP"; then
    exit 0
fi

echo "Limine: Updating ESP for kernel ${KERNEL_VERSION}..."

# Step 1: Rotate current pair → .old (safe fallback for bad new kernels).
# Do the copy before overwriting so .old is always a valid, complete pair.
if [ -f "$ESP/vmlinuz" ]; then
    cp -f "$ESP/vmlinuz"   "$ESP/vmlinuz.old"
fi
if [ -f "$ESP/initrd.img" ]; then
    cp -f "$ESP/initrd.img" "$ESP/initrd.img.old"
fi

# Step 2: Install the new pair.
cp -f "/boot/vmlinuz-${KERNEL_VERSION}"    "$ESP/vmlinuz"
cp -f "/boot/initrd.img-${KERNEL_VERSION}" "$ESP/initrd.img"

echo "Limine: ESP updated. Previous kernel saved as vmlinuz.old/initrd.img.old."
EOF

chmod +x "$TARGET/etc/initramfs/post-update.d/zz-update-limine"

echo "All kernel update hooks installed:"
echo "  - /etc/kernel/postinst.d/zz-update-limine"
echo "  - /etc/kernel/postrm.d/zz-update-limine"
echo "  - /etc/initramfs/post-update.d/zz-update-limine"

# ─── Step 6: Register Limine in UEFI boot manager ───────────────────────────

step "Registering Limine with UEFI boot manager (efibootmgr)"

# efibootmgr needs to write to EFI variables, which live on the efivarfs
# filesystem at /sys/firmware/efi/efivars. A plain "mount --bind /sys"
# does NOT include efivarfs — it is a separate submount on the host and
# is invisible inside the chroot without an explicit bind.
if mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
    mountpoint -q "$TARGET/sys/firmware/efi/efivars" 2>/dev/null \
        || mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars"
else
    echo "WARNING: /sys/firmware/efi/efivars is not mounted on the live system."
    echo "         This usually means the live USB booted in legacy BIOS mode."
    echo "         efibootmgr will be skipped — the system will rely on the"
    echo "         fallback EFI/BOOT/BOOTX64.EFI path to boot Limine."
    echo ""
    echo "         To register the boot entry manually after booting:"
    echo "           efibootmgr -c -d $OS_DISK -p 1 -L Limine -l '\\\\EFI\\\\limine\\\\BOOTX64.EFI'"
fi

# Determine the disk number for efibootmgr
# The EFI partition is partition 1 on the OS disk
if mountpoint -q "$TARGET/sys/firmware/efi/efivars" 2>/dev/null; then
    chroot "$TARGET" /bin/bash -e << CHROOT_EOF

# Remove any existing Limine entries before creating a new one.
# Without this, each re-run of the script adds a duplicate UEFI boot entry.
efibootmgr | grep 'Limine' \
    | sed 's/Boot\([0-9A-F]*\).*/\1/' \
    | xargs -r -I{} efibootmgr -B -b {}

efibootmgr -c \
    -d "$OS_DISK" \
    -p 1 \
    -L "Limine" \
    -l '\\EFI\\limine\\BOOTX64.EFI'

echo ""
echo "Current UEFI boot entries:"
efibootmgr -v

CHROOT_EOF
else
    echo "Skipping efibootmgr (efivarfs not available — see warning above)."
fi

echo ""
echo "============================================"
echo "  LIMINE BOOTLOADER INSTALLATION COMPLETE"
echo "============================================"
echo ""
echo "IMPORTANT: Before rebooting, make sure:"
echo "  1. Secure Boot is DISABLED in your UEFI firmware"
echo "     (Limine does not support Secure Boot)"
echo "  2. You remember your LUKS passphrase"
echo ""
echo "To reboot:"
echo "  exit        # if inside chroot"
echo "  umount -R /mnt"
echo "  reboot"
echo ""
echo "After reboot:"
echo "  - You will see a LUKS password prompt → enter your OS disk passphrase"
echo "  - The Incus disk will unlock automatically via keyfile"
echo "  - Limine will show a boot menu → select Ubuntu"
echo "  - You should boot into your new system!"
echo ""
echo "Next step after successful boot: Run 05-post-boot-setup.sh"
echo ""
