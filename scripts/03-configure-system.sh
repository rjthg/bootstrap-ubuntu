#!/usr/bin/env bash
# =============================================================================
# 03-configure-system.sh
# =============================================================================
# This script:
#   1. Sets up a LUKS keyfile for the Incus disk (avoids 2nd password prompt)
#   2. Configures initramfs to include the keyfile and LUKS support
#   3. Sets up a Btrfs swapfile
#   4. Rebuilds initramfs
#
# Prerequisites:
#   - Scripts 01 and 02 have been run successfully
#   - Chroot bind mounts are still active from script 02
#
# Usage:
#   sudo bash 03-configure-system.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

require_root

# ─── Verify chroot is set up ────────────────────────────────────────────────

mountpoint -q "$TARGET/dev"     || mount --bind /dev     "$TARGET/dev"
mountpoint -q "$TARGET/dev/pts" || mount --bind /dev/pts "$TARGET/dev/pts"
mountpoint -q "$TARGET/proc"    || mount --bind /proc    "$TARGET/proc"
mountpoint -q "$TARGET/sys"     || mount --bind /sys     "$TARGET/sys"
mountpoint -q "$TARGET/run"     || mount --bind /run     "$TARGET/run"

# ─── Step 1: Create LUKS keyfile for Incus disk ─────────────────────────────

step "Creating LUKS keyfile for Incus disk"

echo "This keyfile will be stored in the initramfs (which is on the encrypted"
echo "root disk). When the OS disk is unlocked at boot, the initramfs can then"
echo "automatically unlock the Incus disk using this keyfile — no second"
echo "password prompt needed."
echo ""

# Generate a random keyfile with restricted permissions from creation.
# umask 077 ensures the file is created 0600 — there is no window where
# a world-readable file exists (unlike dd then chmod separately).
KEYFILE="$TARGET/etc/luks-incus-keyfile"

# Check whether the keyfile is already generated AND enrolled in the LUKS
# header. --test-passphrase exits 0 only if the key successfully unlocks the
# device, so this is a genuine end-to-end check — not just a file existence
# check (which would miss the case where the file exists but was never added).
if [[ -f "$KEYFILE" ]] && cryptsetup open --test-passphrase \
        --key-file "$KEYFILE" "$INCUS_PART" 2>/dev/null; then
    echo "Keyfile already exists and is enrolled in the Incus disk. Skipping."
else
    # Generate a fresh keyfile. If a stale file exists (created but never
    # enrolled), overwrite it.
    ( umask 077 && dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 status=none )

    # Remove the unenrolled keyfile if luksAddKey fails, so a partial state
    # (keyfile on disk but not in the LUKS header) is never left behind.
    cleanup_keyfile() {
        echo "ERROR: luksAddKey failed. Removing unenrolled keyfile."
        rm -f "$KEYFILE"
        exit 1
    }
    trap cleanup_keyfile ERR

    # Add the keyfile to the Incus partition's LUKS header.
    echo "You will be asked for the Incus disk's passphrase to add the keyfile."
    cryptsetup luksAddKey "$INCUS_PART" "$KEYFILE"

    # Restore default error handling now that the critical section is done.
    trap - ERR

    echo "Keyfile created and added to Incus disk."
fi

# Update crypttab to use the keyfile for the Incus disk
INCUS_PART_UUID=$(blkid -s UUID -o value "$INCUS_PART")
if [[ -z "$INCUS_PART_UUID" ]]; then
    echo "ERROR: Could not read UUID from $INCUS_PART. Was the partition encrypted successfully?"
    exit 1
fi
ROOT_PART_UUID=$(blkid -s UUID -o value "$ROOT_PART")
if [[ -z "$ROOT_PART_UUID" ]]; then
    echo "ERROR: Could not read UUID from $ROOT_PART. Was the partition encrypted successfully?"
    exit 1
fi

cat > "$TARGET/etc/crypttab" << EOF
# /etc/crypttab
# <target>       <source device>                          <key file>                <options>
$ROOT_MAPPER     UUID=$ROOT_PART_UUID                     none                      luks,discard
$INCUS_MAPPER    UUID=$INCUS_PART_UUID                    /etc/luks-incus-keyfile   luks,discard
EOF

echo "Updated /etc/crypttab:"
cat "$TARGET/etc/crypttab"

# ─── Step 2: Configure initramfs to include the keyfile ──────────────────────

step "Configuring initramfs"

# Create a hook to include the keyfile in the initramfs
cat > "$TARGET/etc/initramfs-tools/hooks/luks-keyfile" << 'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Copy the keyfile into the initramfs.
# A missing keyfile means the Incus disk will not unlock automatically at boot.
# Fail loudly here so the problem surfaces during initramfs build, not on reboot.
if [ ! -f /etc/luks-incus-keyfile ]; then
    echo "ERROR: /etc/luks-incus-keyfile not found. Run 03-configure-system.sh first." >&2
    exit 1
fi
cp /etc/luks-incus-keyfile "${DESTDIR}/etc/luks-incus-keyfile"
chmod 600 "${DESTDIR}/etc/luks-incus-keyfile"
EOF

chmod +x "$TARGET/etc/initramfs-tools/hooks/luks-keyfile"

echo "Initramfs hook created to include keyfile."

# ─── Step 3: Set up swap ────────────────────────────────────────────────────

step "Setting up Btrfs swapfile"

# Mount the swap subvolume inside the target
mkdir -p "$TARGET/swap"
ROOT_BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/"$ROOT_MAPPER")

# The swap subvolume should already be in fstab from script 02.
# Mount it now so we can create the swapfile.
if ! mountpoint -q "$TARGET/swap"; then
    mount -o "subvol=$SUBVOL_SWAP,noatime" /dev/mapper/"$ROOT_MAPPER" "$TARGET/swap"
fi

# Create the swapfile.
# Btrfs swapfiles require: no compression, no COW, contiguous allocation.
chroot "$TARGET" /bin/bash -e << 'CHROOT_EOF'

if [ -f /swap/swapfile ]; then
    echo "Swapfile already exists at /swap/swapfile. Skipping."
else
    # Create a 4 GiB swapfile using the modern btrfs-progs command (btrfs-progs
    # 6.1+ / kernel 6.1+, both available on Ubuntu 24.04's kernel 6.8).
    # This command sets NOCOW, preallocates contiguous space, and zeros the file
    # atomically — replacing the old truncate+chattr+dd sequence.
    btrfs filesystem mkswapfile --size 4G /swap/swapfile
    chmod 600 /swap/swapfile
    mkswap /swap/swapfile

    # Add to fstab only if not already present
    if ! grep -q '/swap/swapfile' /etc/fstab; then
        echo "/swap/swapfile    none    swap    defaults    0    0" >> /etc/fstab
    fi

    echo "4 GiB swapfile created at /swap/swapfile"
fi

CHROOT_EOF

# ─── Step 4: Rebuild initramfs ───────────────────────────────────────────────

step "Rebuilding initramfs"

chroot "$TARGET" /bin/bash -e << 'CHROOT_EOF'

update-initramfs -u -k all

echo ""
echo "Initramfs rebuilt. Verifying LUKS support is included..."

# Quick sanity check: the initramfs should contain cryptsetup and the keyfile.
KERNEL_VER=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
if [[ -z "$KERNEL_VER" ]]; then
    echo "FATAL: No kernel found in /boot. Was linux-image-generic installed in script 02?"
    exit 1
fi

if lsinitramfs /boot/initrd.img-"$KERNEL_VER" | grep -q cryptsetup; then
    echo "  ✓ cryptsetup found in initramfs"
else
    echo "  FATAL: cryptsetup NOT found in initramfs!"
    echo "  Ensure cryptsetup-initramfs is installed and run: update-initramfs -u -k all"
    exit 1
fi

if lsinitramfs /boot/initrd.img-"$KERNEL_VER" | grep -q luks-incus-keyfile; then
    echo "  ✓ Incus keyfile found in initramfs"
else
    echo "  FATAL: Incus keyfile NOT found in initramfs!"
    echo "  The Incus disk will require a manual password at every boot."
    exit 1
fi

CHROOT_EOF

echo ""
echo "============================================"
echo "  SYSTEM CONFIGURATION COMPLETE"
echo "============================================"
echo ""
echo "Next step: Run 04-install-limine.sh"
echo ""
