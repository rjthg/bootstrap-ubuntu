#!/usr/bin/env bash
# =============================================================================
# 05-post-boot-setup.sh
# =============================================================================
# Run this AFTER successfully booting into your new system.
#
# This script:
#   1. Installs Incus
#   2. Configures the Incus Btrfs storage pool on the dedicated disk
#   3. Initializes Incus (network bridge, default profile)
#   4. Adds the invoking user to the incus group
#   5. Prints desktop environment install options (optional)
#   6. Prepares for ROCm installation
#
# Usage:
#   sudo bash 05-post-boot-setup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

require_root

# ─── Verify we are booted into the installed system ──────────────────────────

step "Verifying system state"

if [ ! -f /etc/hostname ] || [ "$(cat /etc/hostname)" != "$HOSTNAME" ]; then
    echo "WARNING: Hostname doesn't match expected value '$HOSTNAME'."
    echo "Are you sure you're running this on the installed system (not the live USB)?"
    read -rp "Continue anyway? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
fi

# Verify the Incus LUKS volume is open
if [ ! -b "/dev/mapper/$INCUS_MAPPER" ]; then
    echo "ERROR: /dev/mapper/$INCUS_MAPPER does not exist."
    echo "The Incus disk may not have been unlocked at boot."
    echo "Check /etc/crypttab and rebuild initramfs."
    exit 1
fi

echo "System looks good."
echo "Incus LUKS volume is open at /dev/mapper/$INCUS_MAPPER"

# ─── Step 1: Install Incus ──────────────────────────────────────────────────

step "Installing Incus"

echo "Adding Incus stable PPA and installing..."

# Add the official Incus PPA
# (Check https://github.com/zabbly/incus for the latest instructions)
if ! command -v incus &>/dev/null; then
    # Install from the Zabbly repository (official Incus packages for Ubuntu)
    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /usr/share/keyrings/zabbly.gpg

    cat > /etc/apt/sources.list.d/zabbly-incus-stable.list << EOF
deb [signed-by=/usr/share/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo "$VERSION_CODENAME") main
EOF

    apt-get update
    apt-get install -y incus
    echo "Incus installed."
else
    echo "Incus is already installed."
fi

# Ensure the daemon is running before we try to use it
systemctl enable --now incus

echo "Waiting for Incus daemon to become ready..."
timeout 30 bash -c 'until incus info &>/dev/null 2>&1; do sleep 1; done' \
    || { echo "ERROR: Incus daemon did not become ready within 30 seconds."; exit 1; }
echo "Incus daemon is ready."

# ─── Step 2: Configure Incus storage pool ────────────────────────────────────

step "Configuring Incus Btrfs storage pool"

# Check if Incus has already been initialized
if incus storage list | grep -q "incus-pool"; then
    echo "Incus storage pool 'incus-pool' already exists."
else
    echo "Creating Incus storage pool 'incus-pool' on /dev/mapper/$INCUS_MAPPER..."
    echo ""

    # Create the storage pool using the block device directly
    # Incus will format and manage this filesystem.
    incus storage create incus-pool btrfs source="/dev/mapper/$INCUS_MAPPER"

    echo ""
    echo "Storage pool created:"
    incus storage list
    echo ""
    incus storage info incus-pool
fi

# ─── Step 3: Initialize Incus (if not already done) ─────────────────────────

step "Initializing Incus"

# Create the network bridge if it doesn't already exist
if ! incus network list | grep -q "incusbr0"; then
    echo "Creating Incus network bridge..."
    incus network create incusbr0
    echo "Network incusbr0 created."
else
    echo "Incus network incusbr0 already exists."
fi

# Always apply profile devices idempotently (remove-then-add is safe to re-run).
# This ensures the profile is correct even if a previous run was interrupted
# after creating the network but before adding the devices.
echo "Configuring default profile devices..."
incus profile device remove default root 2>/dev/null || true
incus profile device add default root disk pool=incus-pool path=/

incus profile device remove default eth0 2>/dev/null || true
incus profile device add default eth0 nic network=incusbr0

echo "Incus initialized with:"
echo "  - Storage pool: incus-pool (Btrfs on dedicated encrypted disk)"
echo "  - Network: incusbr0 (bridge)"

# ─── Step 4: Add user to incus group ─────────────────────────────────────────

step "Adding user to incus group"

# $SUDO_USER is set by sudo to the name of the invoking user.
if [ -z "${SUDO_USER:-}" ]; then
    echo "WARNING: SUDO_USER is not set — cannot determine which user to add to the incus group."
    echo "         Run manually: usermod -aG incus <your-username>"
else
    if id -nG "$SUDO_USER" | grep -qw incus; then
        echo "User '$SUDO_USER' is already in the incus group."
    else
        usermod -aG incus "$SUDO_USER"
        echo "User '$SUDO_USER' added to the 'incus' group."
        echo "NOTE: Log out and back in for the group membership to take effect."
    fi
fi

# ─── Step 5: Desktop environment (optional) ─────────────────────────────────

step "Desktop environment"

echo "Your base system is currently a minimal install with no desktop."
echo ""
echo "If you want a desktop environment, you can install one with:"
echo ""
echo "  For GNOME (Ubuntu default):"
echo "    sudo apt install ubuntu-desktop"
echo ""
echo "  For KDE Plasma:"
echo "    sudo apt install kubuntu-desktop"
echo ""
echo "  For a minimal desktop (no snap, no extras):"
echo ""
echo "    X11 (Xorg):"
echo "      sudo apt install --no-install-recommends xorg gnome-shell gdm3 \\"
echo "          gnome-terminal nautilus"
echo ""
echo "    Wayland (recommended for modern GPUs/HiDPI):"
echo "      sudo apt install --no-install-recommends gnome-shell gnome-session \\"
echo "          gdm3 gnome-terminal nautilus xwayland"
echo "      # xwayland provides compatibility for X11 apps under Wayland"
echo ""
echo "Skipping desktop install — run one of the commands above if you want one."

# ─── Step 6: ROCm preparation notes ─────────────────────────────────────────

step "ROCm preparation"

echo "To use ROCm (AMD GPU compute) inside Incus containers:"
echo ""
echo "1. Install ROCm on the HOST first:"
echo "   Follow https://rocm.docs.amd.com/projects/install-on-linux/"
echo ""
echo "2. For containers, use the 'gpu' device type (preferred over"
echo "   security.privileged=true):"
echo ""
echo "   incus launch ubuntu:24.04 llm-container"
echo "   incus config device add llm-container gpu gpu \\"
echo "       gid=\$(getent group render | cut -d: -f3)"
echo ""
echo "3. If the 'gpu' device type doesn't work for ROCm, fall back to"
echo "   explicit device passthrough:"
echo ""
echo "   incus config device add llm-container kfd unix-char path=/dev/kfd"
echo "   incus config device add llm-container dri disk source=/dev/dri path=/dev/dri"
echo "   incus config set llm-container security.privileged=true"
echo ""
echo "4. For VMs (more reliable with ROCm but slower):"
echo "   NOTE: Btrfs has a known caveat with VM disk images."
echo "   See: https://linuxcontainers.org/incus/docs/main/reference/storage_btrfs/"
echo "   If VMs are your primary use case, consider ZFS instead."
echo ""

echo ""
echo "============================================"
echo "  POST-BOOT SETUP COMPLETE"
echo "============================================"
echo ""
echo "Your system is ready! You now have:"
echo "  ✓ Ubuntu on encrypted Btrfs (P310 disk)"
echo "  ✓ Limine bootloader with auto-update hooks"
echo "  ✓ Incus with dedicated encrypted Btrfs storage pool (P510 disk)"
echo "  ✓ Single LUKS password at boot (keyfile unlocks second disk)"
echo "  ✓ Btrfs snapshots available for rollback"
echo "  ✓ Swap configured as a safety net"
echo ""
echo "Useful commands:"
echo "  incus launch ubuntu:24.04 my-container    # Create a container"
echo "  incus list                                 # List containers"
echo "  incus snapshot create my-container snap1   # Snapshot a container"
echo "  btrfs subvolume snapshot / /snapshots/\$(date +%Y%m%d)  # Snapshot root"
echo ""
