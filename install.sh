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

echo "==> Checking prerequisites"
missing=()
for bin in sunshine steam; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing: ${missing[*]}" >&2
    echo "Install Sunshine and Steam yourself first (see README), then re-run." >&2
    exit 1
fi

echo "==> Installing gamescope and xorg-cvt"
if command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm gamescope xorg-cvt
else
    echo "Non-pacman system detected -- install 'gamescope' and 'cvt' (xorg-cvt) yourself, then re-run." >&2
    exit 1
fi

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
mkdir -p /usr/lib/firmware/edid
python3 "$SCRIPT_DIR/scripts/patch-edid.py" \
    --input /tmp/streaming-rig-raw.edid \
    --output "/usr/lib/firmware/edid/${EDID_FIRMWARE_NAME}" \
    --width "$TARGET_WIDTH" --height "$TARGET_HEIGHT" --refresh "$TARGET_REFRESH" \
    --mm-width "$PANEL_WIDTH_MM" --mm-height "$PANEL_HEIGHT_MM"
rm -f /tmp/streaming-rig-raw.edid

echo "==> Registering EDID with mkinitcpio"
if ! grep -q "edid/${EDID_FIRMWARE_NAME}" /etc/mkinitcpio.conf; then
    sed -i -E "s|^FILES=\((.*)\)|FILES=(\1 \"edid/${EDID_FIRMWARE_NAME}\")|" /etc/mkinitcpio.conf
    mkinitcpio -P
else
    echo "    already registered, skipping"
fi

CMDLINE_ARG="drm.edid_firmware=${HDMI_CONNECTOR}:edid/${EDID_FIRMWARE_NAME}"
if [ -f /etc/default/limine ]; then
    echo "==> Adding kernel cmdline (Limine): ${CMDLINE_ARG}"
    if ! grep -q -- "$CMDLINE_ARG" /etc/default/limine; then
        sed -i -E "/^KERNEL_CMDLINE\[default\]/ s/\"\$/ ${CMDLINE_ARG}\"/" /etc/default/limine
        limine-update
    else
        echo "    already present, skipping"
    fi
else
    echo "==> WARNING: /etc/default/limine not found." >&2
    echo "    This repo only automates the Limine bootloader. Add the following to" >&2
    echo "    your bootloader's kernel command line yourself, then reboot:" >&2
    echo "        ${CMDLINE_ARG}" >&2
fi

echo "==> Granting scheduling capability to gamescope (frame pacing for composited content)"
setcap 'cap_sys_nice=eip' /usr/bin/gamescope

echo "==> Writing Sunshine config"
mkdir -p "$TARGET_HOME/.config/sunshine"
cat > "$TARGET_HOME/.config/sunshine/sunshine.conf" <<EOF
csrf_allowed_origins = ${SUNSHINE_CSRF_ORIGINS}
capture = kms
adapter_name = ${SUNSHINE_RENDER_NODE}
EOF

cp "$SCRIPT_DIR/files/apps.json" "$TARGET_HOME/.config/sunshine/apps.json"

echo "==> Installing gamescope session script"
cp "$SCRIPT_DIR/files/gamescope-session.sh" "$TARGET_HOME/.config/gamescope-session.sh"
chmod +x "$TARGET_HOME/.config/gamescope-session.sh"

echo "==> Wiring autologin console launch (.zprofile)"
HDR_FLAGS=""
if [ "$HDR_ENABLED" = "true" ]; then
    HDR_FLAGS="--hdr-enabled --hdr-itm-enabled --hdr-itm-sdr-nits ${HDR_SDR_NITS} --hdr-itm-target-nits ${HDR_TARGET_NITS} "
fi

ZPROFILE="$TARGET_HOME/.zprofile"
MARKER="# >>> streaming-rig gamescope session >>>"
END_MARKER="# <<< streaming-rig gamescope session <<<"
touch "$ZPROFILE"
if ! grep -qF "$MARKER" "$ZPROFILE"; then
    cat >> "$ZPROFILE" <<EOF

${MARKER}
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec gamescope --backend drm -O ${HDMI_CONNECTOR} \\
        -W ${TARGET_WIDTH} -H ${TARGET_HEIGHT} -w ${TARGET_WIDTH} -h ${TARGET_HEIGHT} -r ${TARGET_REFRESH} \\
        --generate-drm-mode fixed \\
        ${HDR_FLAGS}-e \\
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
    "$TARGET_HOME/.local/share" \
    "$ZPROFILE"

echo
echo "==> Done."
echo "Reboot to start streaming automatically on tty1 (autologin required -- see README)."
