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

echo "==> Installing gamescope, xorg-cvt, sunshine, steam, mangohud, python-pygame, python-pillow, ttf-dejavu"
pacman -S --needed --noconfirm gamescope xorg-cvt sunshine steam mangohud python-pygame python-pillow ttf-dejavu

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

echo "==> Granting scheduling capability to sunshine (real-time encoder thread priority)"
# The sunshine package already ships cap_sys_admin,cap_sys_nice on its own
# binary, but only in the Permitted set (=p), not Effective (=eip) -- present
# but dormant, since a process doesn't get to use a merely-permitted
# capability without raising it into its effective set itself, which
# sunshine doesn't do. Symptom: "Warning: setpriority failed for nice
# -15/-10: Permission denied" in sunshine.log, and its encoder thread
# running at normal priority -- under momentary CPU contention (Steam's UI,
# a game's background threads) that's enough to miss a real-time frame
# deadline and show up as occasional stream corruption. Re-run explicitly
# with =eip so it's active immediately; also re-applied here in case a
# future sunshine package update resets it back to the package default.
setcap 'cap_sys_admin,cap_sys_nice=eip' /usr/bin/sunshine

echo "==> Adding ${TARGET_USER} to the 'input' group"
# Sunshine's packaged udev rules (60-sunshine.rules) only grant uaccess to
# gamepad-named virtual devices (Xbox/PS5/Nintendo pad) -- its generic
# "Mouse passthrough"/"Touch passthrough"/"Keyboard passthrough" devices
# have no matching rule, so they stay root:input mode 0660 with no ACL.
# Without this, gamescope (running as TARGET_USER) can't open those
# devices at all: gamepad input works, but mouse/touch/keyboard silently
# don't. Group membership is set at login time, so this needs a fresh
# login (a reboot, per the final step below, is the simplest way) to take
# effect -- restarting gamescope/Sunshine alone won't pick it up.
usermod -aG input "$TARGET_USER"

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

cp "$SCRIPT_DIR/files/apps.json" "$TARGET_HOME/.config/sunshine/apps.json"

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

echo "==> Installing the HDR calibration tool (Steam library: HDR Calibrate)"
STREAMING_RIG_DIR="$TARGET_HOME/.config/streaming-rig"
mkdir -p "$STREAMING_RIG_DIR"
cp "$SCRIPT_DIR/apps/hdr-calibrate.py" "$STREAMING_RIG_DIR/hdr-calibrate.py"
cp "$SCRIPT_DIR/files/streaming-session.sh" "$STREAMING_RIG_DIR/streaming-session.sh"
cp "$SCRIPT_DIR/files/hdr-calibrate-launch.sh" "$STREAMING_RIG_DIR/hdr-calibrate-launch.sh"
chmod +x "$STREAMING_RIG_DIR/hdr-calibrate.py" "$STREAMING_RIG_DIR/streaming-session.sh" \
    "$STREAMING_RIG_DIR/hdr-calibrate-launch.sh"

echo "==> Registering the HDR Calibrate Steam shortcut and library artwork"
# Run as TARGET_USER (not root, even though this whole script is) so any
# files written under ~/.local/share/Steam/userdata/ come out owned by the
# same user Steam itself runs as, rather than needing a chown fixup here.
sudo -u "$TARGET_USER" python3 "$SCRIPT_DIR/scripts/setup-hdr-calibrate-shortcut.py" \
    --target-home "$TARGET_HOME" \
    --launch-script "$STREAMING_RIG_DIR/hdr-calibrate-launch.sh" \
    --start-dir "$STREAMING_RIG_DIR" \
    --appid-file "$STREAMING_RIG_DIR/hdr-calibrate-appid" \
    --gameid-file "$STREAMING_RIG_DIR/hdr-calibrate-gameid"

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
    # SDR_NITS/TARGET_NITS default here, but the HDR Calibrate tool (a Steam
    # non-Steam-game shortcut) can override them at runtime via this file
    # without re-running install.sh.
    SDR_NITS=${HDR_SDR_NITS}
    TARGET_NITS=${HDR_TARGET_NITS}
    [ -f "\$HOME/.config/streaming-rig/hdr.conf" ] && . "\$HOME/.config/streaming-rig/hdr.conf"
    exec gamescope --backend drm -O ${HDMI_CONNECTOR} \\
        -W ${TARGET_WIDTH} -H ${TARGET_HEIGHT} -w ${TARGET_WIDTH} -h ${TARGET_HEIGHT} -r ${TARGET_REFRESH} \\
        --generate-drm-mode fixed \\
        ${HDR_FLAGS}${MANGOHUD_FLAGS}--default-touch-mode 1 -e \\
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
echo "A reboot is also required for the 'input' group membership (mouse/touch/keyboard"
echo "passthrough) to take effect -- it's set at login time, so just restarting"
echo "gamescope/Sunshine won't pick it up."
