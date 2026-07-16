#!/bin/bash
# Turnkey installer for a headless Sunshine + gamescope streaming rig.
# Edit config.sh first, then: sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root: sudo ./install.sh" >&2
    exit 1
fi

if [ -z "${TARGET_USER:-}" ] || [ "$TARGET_USER" = "root" ]; then
    echo "TARGET_USER resolved to '${TARGET_USER:-empty}' -- run this via sudo as your" >&2
    echo "normal user (sudo ./install.sh), or set TARGET_USER in config.sh." >&2
    exit 1
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ]; then
    echo "Could not resolve a home directory for user '$TARGET_USER'" >&2
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    echo "This installer is pacman-only (CachyOS/Arch). Install gamescope, xorg-cvt," >&2
    echo "sunshine, and steam yourself for your distro, then re-run." >&2
    exit 1
fi

echo "==> Checking for the multilib repo (required for Steam)"
if ! pacman-conf --repo-list | grep -qx multilib; then
    if grep -q '^\s*#\s*\[multilib\]' /etc/pacman.conf; then
        echo "    enabling multilib in /etc/pacman.conf"
        sed -i '/^\s*#\s*\[multilib\]/,/^\s*#\s*Include/ s/^\s*#\s*//' /etc/pacman.conf
        pacman -Sy
    else
        echo "multilib isn't enabled and no commented-out [multilib] block was found" >&2
        echo "in /etc/pacman.conf to uncomment. Enable it yourself, then re-run." >&2
        exit 1
    fi
fi

echo "==> Installing gamescope, xorg-cvt, sunshine, steam, mangohud, and python-pygame"
pacman -S --needed --noconfirm gamescope xorg-cvt sunshine steam mangohud python-pygame

mkdir -p /usr/lib/firmware/edid
if [ "$EDID_MODE" = "synthetic" ]; then
    echo "==> Building a synthetic EDID -> ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}Hz"
    echo "    (no display or dummy plug needed -- this is generated from scratch)"
    python3 "$SCRIPT_DIR/scripts/build-edid.py" \
        --output "/usr/lib/firmware/edid/${EDID_FIRMWARE_NAME}" \
        --width "$TARGET_WIDTH" --height "$TARGET_HEIGHT" --refresh "$TARGET_REFRESH" \
        --mm-width "$PANEL_WIDTH_MM" --mm-height "$PANEL_HEIGHT_MM" \
        --product-name "${EDID_PRODUCT_NAME}"
elif [ "$EDID_MODE" = "real" ]; then
    echo "==> Reading current EDID from ${HDMI_CONNECTOR}"
    CARD_PATH=$(find /sys/class/drm -maxdepth 1 -name "card*-${HDMI_CONNECTOR}" | head -n1)
    if [ -z "$CARD_PATH" ]; then
        echo "Could not find connector ${HDMI_CONNECTOR} under /sys/class/drm." >&2
        echo "Available connectors:" >&2
        ls /sys/class/drm | grep -E '^card[0-9]+-' >&2 || true
        exit 1
    fi
    RAW_EDID="$CARD_PATH/edid"
    if [ ! -s "$RAW_EDID" ]; then
        echo "No EDID present at $RAW_EDID -- is a display/dummy plug connected?" >&2
        exit 1
    fi
    cp "$RAW_EDID" /tmp/streaming-rig-raw.edid

    echo "==> Patching EDID -> ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}Hz"
    python3 "$SCRIPT_DIR/scripts/patch-edid.py" \
        --input /tmp/streaming-rig-raw.edid \
        --output "/usr/lib/firmware/edid/${EDID_FIRMWARE_NAME}" \
        --width "$TARGET_WIDTH" --height "$TARGET_HEIGHT" --refresh "$TARGET_REFRESH" \
        --mm-width "$PANEL_WIDTH_MM" --mm-height "$PANEL_HEIGHT_MM"
    rm -f /tmp/streaming-rig-raw.edid
else
    echo "EDID_MODE must be 'synthetic' or 'real', got '${EDID_MODE}'" >&2
    exit 1
fi

echo "==> Registering EDID with mkinitcpio"
if ! grep -q "edid/${EDID_FIRMWARE_NAME}" /etc/mkinitcpio.conf; then
    sed -i -E "s|^FILES=\((.*)\)|FILES=(\1 \"edid/${EDID_FIRMWARE_NAME}\")|" /etc/mkinitcpio.conf
    mkinitcpio -P
else
    echo "    already registered, skipping"
fi

# drm.edid_firmware overrides the connector's EDID *content*. In synthetic
# mode we also add video=...:e, which forces the kernel to treat the
# connector as connected regardless of hotplug/physical detection -- no
# display or dummy plug ever needs to be attached. Verified working, HDR
# included, on an RTX 4090 with the open-source nvidia-open kernel module.
CMDLINE_ARGS=("drm.edid_firmware=${HDMI_CONNECTOR}:edid/${EDID_FIRMWARE_NAME}")
if [ "$EDID_MODE" = "synthetic" ]; then
    CMDLINE_ARGS+=("video=${HDMI_CONNECTOR}:e")
fi
if [ -f /etc/default/limine ]; then
    echo "==> Adding kernel cmdline (Limine): ${CMDLINE_ARGS[*]}"
    NEW_ARGS=""
    for arg in "${CMDLINE_ARGS[@]}"; do
        grep -q -- "$arg" /etc/default/limine || NEW_ARGS="${NEW_ARGS} ${arg}"
    done
    if [ -n "$NEW_ARGS" ]; then
        sed -i -E "/^KERNEL_CMDLINE\[default\]/ s|\"\$|${NEW_ARGS}\"|" /etc/default/limine
        limine-update
    else
        echo "    already present, skipping"
    fi
else
    echo "==> WARNING: /etc/default/limine not found." >&2
    echo "    This repo only automates the Limine bootloader. Add the following to" >&2
    echo "    your bootloader's kernel command line yourself, then reboot:" >&2
    echo "        ${CMDLINE_ARGS[*]}" >&2
fi

echo "==> Granting scheduling capability to gamescope (frame pacing for composited content)"
setcap 'cap_sys_nice=eip' /usr/bin/gamescope

echo "==> Merging Sunshine config"
mkdir -p "$TARGET_HOME/.config/sunshine"
SUNSHINE_CONF="$TARGET_HOME/.config/sunshine/sunshine.conf"
touch "$SUNSHINE_CONF"

# Update just our keys in place if present, append if not -- preserves
# anything else Sunshine's own web UI has written to this file (encoder
# settings, pairing state, etc.) instead of clobbering the whole thing.
set_conf_value() {
    local key="$1" value="$2"
    local escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\&|]/\\&/g')
    if grep -qE "^${key}[[:space:]]*=" "$SUNSHINE_CONF"; then
        sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${escaped}|" "$SUNSHINE_CONF"
    else
        printf '%s = %s\n' "$key" "$value" >> "$SUNSHINE_CONF"
    fi
}

set_conf_value "csrf_allowed_origins" "$SUNSHINE_CSRF_ORIGINS"
set_conf_value "capture" "kms"
set_conf_value "adapter_name" "$SUNSHINE_RENDER_NODE"

mkdir -p "$TARGET_HOME/.config/sunshine/covers"
cp "$SCRIPT_DIR/files/hdr-calibrate-icon.png" "$TARGET_HOME/.config/sunshine/covers/hdr-calibrate.png"

# Sunshine does not expand shell variables in apps.json (prep-cmd/image-path
# run/resolve directly, not through a shell) -- substitute the real absolute
# path in ourselves rather than leaving a $HOME that will just fail to
# resolve at runtime.
sed "s|__TARGET_HOME__|${TARGET_HOME}|g" "$SCRIPT_DIR/files/apps.json" > "$TARGET_HOME/.config/sunshine/apps.json"

echo "==> Enabling GPU-accelerated Big Picture rendering in Steam"
STEAM_REGISTRY="$TARGET_HOME/.steam/registry.vdf"
if [ -f "$STEAM_REGISTRY" ]; then
    for key in CEFGPUBlocklistDisabled GPUAccelWebViewsV3; do
        if grep -qE "\"${key}\"" "$STEAM_REGISTRY"; then
            sed -i -E "s|(\"${key}\"[[:space:]]*)\"[^\"]*\"|\1\"1\"|" "$STEAM_REGISTRY"
        else
            echo "    '${key}' not found in registry.vdf -- set it by hand via Steam's" >&2
            echo "    Settings -> Interface -> 'Enable GPU accelerated rendering in Big Picture Mode'" >&2
        fi
    done
else
    echo "    Steam hasn't run yet, so ~/.steam/registry.vdf doesn't exist -- this is"
    echo "    expected on a fresh install. Once Steam has launched once (which happens"
    echo "    automatically on first boot), either re-run install.sh to apply this, or"
    echo "    set it by hand via Steam's Settings -> Interface -> 'Enable GPU"
    echo "    accelerated rendering in Big Picture Mode'. Without it, Big Picture's own"
    echo "    UI can judder even though games run smoothly (see README Troubleshooting)."
fi

echo "==> Installing gamescope session script"
cp "$SCRIPT_DIR/files/gamescope-session.sh" "$TARGET_HOME/.config/gamescope-session.sh"
chmod +x "$TARGET_HOME/.config/gamescope-session.sh"

echo "==> Installing the HDR calibration tool (Sunshine app: Calibrate HDR)"
STREAMING_RIG_DIR="$TARGET_HOME/.config/streaming-rig"
mkdir -p "$STREAMING_RIG_DIR"
cp "$SCRIPT_DIR/apps/hdr-calibrate.py" "$STREAMING_RIG_DIR/hdr-calibrate.py"
cp "$SCRIPT_DIR/files/enter-calibration.sh" "$STREAMING_RIG_DIR/enter-calibration.sh"
cp "$SCRIPT_DIR/files/exit-calibration.sh" "$STREAMING_RIG_DIR/exit-calibration.sh"
chmod +x "$STREAMING_RIG_DIR/hdr-calibrate.py" "$STREAMING_RIG_DIR/enter-calibration.sh" "$STREAMING_RIG_DIR/exit-calibration.sh"

HDR_CONF="$STREAMING_RIG_DIR/hdr.conf"
if [ ! -f "$HDR_CONF" ]; then
    cat > "$HDR_CONF" <<EOF
SDR_NITS=${HDR_SDR_NITS}
TARGET_NITS=${HDR_TARGET_NITS}
EOF
else
    echo "    $HDR_CONF already exists (likely tuned via the calibration tool), leaving it alone"
fi

echo "==> Wiring autologin console launch (.zprofile)"
HDR_FLAGS=""
if [ "$HDR_ENABLED" = "true" ]; then
    HDR_FLAGS="--hdr-enabled --hdr-itm-enabled --hdr-itm-sdr-nits \"\$SDR_NITS\" --hdr-itm-target-nits \"\$TARGET_NITS\" "
fi

MANGOHUD_FLAGS=""
if [ "$MANGOHUD_ENABLED" = "true" ]; then
    MANGOHUD_FLAGS="--mangoapp "
fi

ZPROFILE="$TARGET_HOME/.zprofile"
MARKER="# >>> streaming-rig gamescope session >>>"
END_MARKER="# <<< streaming-rig gamescope session <<<"
touch "$ZPROFILE"
if ! grep -qF "$MARKER" "$ZPROFILE"; then
    cat >> "$ZPROFILE" <<EOF

${MARKER}
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    # SDR_NITS/TARGET_NITS default here, but the "Calibrate HDR" Sunshine app
    # can override them at runtime via this file without re-running install.sh.
    SDR_NITS=${HDR_SDR_NITS}
    TARGET_NITS=${HDR_TARGET_NITS}
    [ -f "\$HOME/.config/streaming-rig/hdr.conf" ] && . "\$HOME/.config/streaming-rig/hdr.conf"
    exec gamescope --backend drm -O ${HDMI_CONNECTOR} \\
        -W ${TARGET_WIDTH} -H ${TARGET_HEIGHT} -w ${TARGET_WIDTH} -h ${TARGET_HEIGHT} -r ${TARGET_REFRESH} \\
        --generate-drm-mode fixed \\
        ${HDR_FLAGS}${MANGOHUD_FLAGS}-e \\
        -- "\$HOME/.config/gamescope-session.sh" \\
        > "\$HOME/.local/share/gamescope-session.log" 2>&1
fi
${END_MARKER}
EOF
else
    echo "    marker already present in .zprofile, skipping (edit it by hand if flags changed)"
fi

mkdir -p "$TARGET_HOME/.local/share"
chown -R "$TARGET_USER":"$TARGET_USER" \
    "$TARGET_HOME/.config/sunshine" \
    "$TARGET_HOME/.config/gamescope-session.sh" \
    "$STREAMING_RIG_DIR" \
    "$TARGET_HOME/.local/share" \
    "$ZPROFILE"
# sed -i replaces the file (new inode owned by root); put ownership back if it exists.
[ -f "$STEAM_REGISTRY" ] && chown "$TARGET_USER":"$TARGET_USER" "$STEAM_REGISTRY"

echo "==> Disabling sleep/suspend/hibernate"
# Steam's Big Picture power menu only exposes Suspend when it believes it's
# on genuine Deck hardware (which gamescope-session.sh's SteamDeck=1 spoof
# arranges, for QAM/MangoHud access) -- so a stray button press can now
# actually suspend this box. A dedicated always-on streaming appliance
# should never honor a suspend request from any source, so mask it at the
# systemd level rather than trying to prevent every possible trigger.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

echo
echo "==> Done."
if [ "$EDID_MODE" = "synthetic" ]; then
    echo "No display or dummy plug is needed on ${HDMI_CONNECTOR} at any point -- the"
    echo "connector is forced 'connected' via the kernel cmdline regardless."
else
    echo "Keep the dummy plug connected to ${HDMI_CONNECTOR} -- EDID_MODE=real relies on"
    echo "real hotplug detection, unlike EDID_MODE=synthetic."
fi
echo "Reboot to start streaming automatically on tty1 (autologin required -- see README)."
