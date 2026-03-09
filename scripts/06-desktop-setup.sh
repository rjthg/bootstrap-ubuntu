#!/usr/bin/env bash
# =============================================================================
# 06-desktop-setup.sh
# =============================================================================
# Optional. Run this AFTER 05-post-boot-setup.sh to install a Wayland desktop.
#
# This script installs and configures:
#   1. Niri (scrollable-tiling Wayland compositor), built from source
#   2. Waybar, foot, mako, fuzzel (bar, terminal, notifications, launcher)
#   3. greetd + tuigreet (display manager), replacing any existing DM
#   4. Per-user default configs for niri and waybar (for $SUDO_USER)
#
# Compile times: niri ~15–30 min, greetd ~5–10 min (Rust builds).
#
# Usage:
#   sudo bash 06-desktop-setup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

require_root

# ─── Step 1: Install apt packages ────────────────────────────────────────────

step "Installing apt packages"

apt-get install -y \
    waybar foot mako-notifier xwayland fuzzel jq git \
    pipewire pipewire-pulse wireplumber \
    build-essential clang pkg-config \
    libwayland-dev libxkbcommon-dev libinput-dev libudev-dev libgbm-dev \
    libdbus-1-dev libseat-dev libpixman-1-dev libpango1.0-dev libglib2.0-dev \
    libliftoff-dev libdisplay-info-dev libpam-dev

# ─── Step 2: Install Rust toolchain ──────────────────────────────────────────

step "Installing Rust toolchain"

if ! command -v /root/.cargo/bin/cargo &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal
fi
export PATH="/root/.cargo/bin:$PATH"

# ─── Step 3: Build and install niri ──────────────────────────────────────────

step "Building niri"

NIRI_VERSION="v25.11"   # verify latest at https://github.com/YaLTeR/niri/releases

if ! command -v niri &>/dev/null; then
    echo "Cloning niri ${NIRI_VERSION}..."
    git clone --branch="$NIRI_VERSION" --depth=1 https://github.com/YaLTeR/niri /tmp/niri-src
    echo "Building niri (this may take 15–30 minutes)..."
    cargo install --locked --path /tmp/niri-src
    echo "niri build complete."
    install -m755 /root/.cargo/bin/niri /usr/local/bin/niri
    install -m755 /tmp/niri-src/resources/niri-session /usr/local/bin/niri-session
    rm -rf /tmp/niri-src
else
    echo "niri is already installed."
fi

# .desktop entry (always write — idempotent heredoc overwrite)
mkdir -p /usr/local/share/wayland-sessions
cat > /usr/local/share/wayland-sessions/niri.desktop << 'EOF'
[Desktop Entry]
Name=Niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
EOF

# ─── Step 4: Build and install greetd ────────────────────────────────────────

step "Building greetd"

GREETD_VERSION="0.10.3"  # verify latest at https://git.sr.ht/~kennylevinsen/greetd

if ! command -v greetd &>/dev/null; then
    GREETD_TMP=$(mktemp -d)
    trap 'rm -rf "$GREETD_TMP"' EXIT
    echo "Cloning greetd ${GREETD_VERSION}..."
    git clone --branch="$GREETD_VERSION" --depth=1 \
        https://git.sr.ht/~kennylevinsen/greetd "$GREETD_TMP"
    echo "Building greetd (this may take 5–10 minutes)..."
    cargo install --locked --path "$GREETD_TMP"
    echo "greetd build complete."
    install -m755 /root/.cargo/bin/greetd /usr/local/bin/greetd
    rm -rf "$GREETD_TMP"
    trap - EXIT
else
    echo "greetd is already installed."
fi

# ─── Step 5: Download tuigreet binary ────────────────────────────────────────

step "Installing tuigreet"

if ! command -v tuigreet &>/dev/null; then
    TUIGREET_URL=$(curl -fsSL https://api.github.com/repos/apognu/tuigreet/releases/latest \
        | jq -r '.assets[] | select(.name | test("x86_64-linux")) | .browser_download_url')
    if [ -z "$TUIGREET_URL" ]; then
        echo "WARNING: Could not resolve tuigreet download URL. Install manually."
    else
        echo "Downloading tuigreet..."
        curl -fsSL -o /usr/local/bin/tuigreet "$TUIGREET_URL"
        chmod 755 /usr/local/bin/tuigreet
        echo "tuigreet installed."
    fi
else
    echo "tuigreet is already installed."
fi

# ─── Step 6: Configure greetd ────────────────────────────────────────────────

step "Configuring greetd"

# Create greeter system user (idempotent)
if ! id -u greeter &>/dev/null; then
    useradd -r -M -s /usr/sbin/nologin greeter
fi
mkdir -p /var/lib/greetd
chown greeter:greeter /var/lib/greetd

mkdir -p /etc/greetd

# Unquoted heredoc: $HOSTNAME expands (sourced from 00-config.sh)
cat > /etc/greetd/config.toml << EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --greeting 'Welcome to $HOSTNAME' --sessions /usr/local/share/wayland-sessions --cmd niri-session"
user = "greeter"
EOF

# PAM config — required or greetd rejects all logins silently
cat > /etc/pam.d/greetd << 'EOF'
auth     include login
account  include login
session  include login
EOF

# Disable any existing DM
for dm in gdm gdm3 lightdm sddm; do
    systemctl disable "$dm" &>/dev/null || true
done

cat > /etc/systemd/system/greetd.service << 'EOF'
[Unit]
Description=greetd display manager
After=systemd-user-sessions.service plymouth-quit-wait.service

[Service]
ExecStart=/usr/local/bin/greetd
Restart=always
StandardInput=tty
StandardOutput=tty

[Install]
Alias=display-manager.service
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable greetd

# ─── Step 7: Per-user default configs ────────────────────────────────────────

step "Writing per-user configs"

if [ -n "${SUDO_USER:-}" ]; then
    # Resolve home dir via getent — '~' expands to /root in a sudo context
    HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)

    # niri config (unquoted heredoc so $XKBLAYOUT expands)
    if [ ! -f "$HOME_DIR/.config/niri/config.kdl" ]; then
        mkdir -p "$HOME_DIR/.config/niri"
        cat > "$HOME_DIR/.config/niri/config.kdl" << EOF
input {
    keyboard {
        xkb {
            layout "$XKBLAYOUT"
        }
    }
}

spawn-at-startup "waybar"
spawn-at-startup "mako"

binds {
    Mod+Return { spawn "foot"; }
    Mod+D { spawn "fuzzel"; }
    Mod+Q { close-window; }
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+J { focus-window-down; }
    Mod+K { focus-window-up; }
    Mod+Shift+H { move-column-left; }
    Mod+Shift+L { move-column-right; }
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+Shift+1 { move-window-to-workspace 1; }
    Mod+Shift+2 { move-window-to-workspace 2; }
    Mod+Shift+3 { move-window-to-workspace 3; }
    Mod+Shift+4 { move-window-to-workspace 4; }
    Print { screenshot; }
}
EOF
        chown "$SUDO_USER:$SUDO_USER" "$HOME_DIR/.config/niri/config.kdl"
    fi

    # waybar config (single-quoted heredoc — no shell expansion needed)
    if [ ! -f "$HOME_DIR/.config/waybar/config.jsonc" ]; then
        mkdir -p "$HOME_DIR/.config/waybar"
        cat > "$HOME_DIR/.config/waybar/config.jsonc" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "modules-left": ["niri/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["cpu", "memory", "network", "pulseaudio"],
    "clock": {
        "format": "{:%H:%M  %Y-%m-%d}"
    },
    "cpu": {
        "format": "CPU {usage}%"
    },
    "memory": {
        "format": "MEM {used:0.1f}G"
    },
    "network": {
        "format-ethernet": "ETH",
        "format-disconnected": "NO NET"
    },
    "pulseaudio": {
        "format": "VOL {volume}%",
        "format-muted": "MUTE"
    }
}
EOF
        chown "$SUDO_USER:$SUDO_USER" "$HOME_DIR/.config/waybar/config.jsonc"
    fi
else
    echo "WARNING: SUDO_USER is not set — skipping per-user config files."
fi

echo ""
echo "============================================"
echo "  DESKTOP SETUP COMPLETE"
echo "============================================"
echo ""
echo "Installed:"
echo "  ✓ Niri compositor + niri-session"
echo "  ✓ Waybar, foot, mako, fuzzel"
echo "  ✓ greetd + tuigreet (display manager, enabled)"
echo "  ✓ pipewire / wireplumber (audio)"
echo ""
echo "Reboot to reach the greetd/tuigreet login screen."
echo "Log in as '${SUDO_USER:-<your-user>}' — niri will start with waybar and mako."
echo ""
echo "Verify after reboot:"
echo "  command -v niri niri-session greetd tuigreet"
echo "  systemctl is-enabled greetd"
echo "  cat /etc/greetd/config.toml"
echo ""
