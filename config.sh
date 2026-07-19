#!/bin/bash
# Edit these before running install.sh. Everything downstream is derived
# from these values -- nothing else in the repo should need hand-editing.

# ---- Display ----
# The HDMI output to use. Find the connector name with:
# ls /sys/class/drm/ | grep -i hdmi
HDMI_CONNECTOR="HDMI-A-1"

# "synthetic" (recommended, default): builds an EDID from scratch, no
# display or dummy plug needed at any point, ever -- the connector is
# forced "connected" via a kernel parameter. Verified end-to-end (HDR
# included) on an RTX 4090 with the open-source nvidia-open kernel module
# and gamescope. Untested on AMD/Intel or other compositors (KDE/GNOME
# Wayland) -- if it doesn't work for you there, switch to "real" below.
#
# "real": patches a genuinely connected HDMI dummy plug's own EDID instead
# (preserving its real HDMI/HDR capability blocks rather than synthesizing
# them), the more conservative option if you have suitable hardware handy.
# Needs a real HDMI 2.1/HDR-capable dummy plug connected to HDMI_CONNECTOR
# when you run install.sh -- see README for why a basic/non-HDR plug won't
# do.
EDID_MODE="synthetic"

# Native resolution and refresh rate of your streaming client (phone,
# tablet, TV, monitor -- whatever Moonlight is running on).
TARGET_WIDTH=2960
TARGET_HEIGHT=1848
TARGET_REFRESH=60

# Physical panel size in millimeters. This isn't cosmetic: some clients
# (compositors, browsers, Steam's own UI) derive a DPI/scale factor from
# this, so get it close to your real device's panel size or you'll see
# unwanted auto-scaling. A quick web search for your device's screen size
# in inches, converted to mm, is good enough.
PANEL_WIDTH_MM=316
PANEL_HEIGHT_MM=197

# Filename the generated/patched EDID will be installed as, under
# /usr/lib/firmware/edid/. Only matters if you're running this on more
# than one machine and want to tell the files apart.
EDID_FIRMWARE_NAME="custom-panel.bin"

# Cosmetic only (EDID_MODE=synthetic) -- shows up as the "monitor name" in
# OS display settings.
EDID_PRODUCT_NAME="Virtual HDMI"

# ---- HDR (gamescope inverse tone-mapping) ----
# gamescope will tone-map SDR game content up to HDR for the physical
# output. Only relevant if your display supports HDR -- leave
# HDR_ENABLED=false otherwise.
#
# HDR_SDR_NITS/HDR_TARGET_NITS are only the *initial* values, written to
# ~/.config/streaming-rig/hdr.conf on first install. After that, launch
# "HDR Calibrate" from your Steam library to tune them interactively
# against your actual display -- it edits that file directly, and
# re-running install.sh won't overwrite your tuned values.
HDR_ENABLED=true
HDR_SDR_NITS=100
HDR_TARGET_NITS=1000

# ---- Performance overlay ----
# gamescope's own --mangoapp flag launches the MangoHud overlay for you
# (use this instead of enabling MangoHud on the game or via gamescope
# separately). Toggle in-session via gamescope's Quick Access Menu.
MANGOHUD_ENABLED=true

# ---- Sunshine ----
# The render node Sunshine should use for KMS capture. Usually correct as
# the first render node; confirm with: ls /dev/dri/
SUNSHINE_RENDER_NODE="/dev/dri/renderD128"

# Comma-separated origins Sunshine's web UI should accept CSRF requests
# from -- typically the host's LAN IP and/or mDNS hostname, each with
# ':47990'. Only needed if you manage Sunshine's config from a browser on
# another machine.
SUNSHINE_CSRF_ORIGINS="https://YOUR_HOST_IP:47990,https://YOUR_HOSTNAME.local:47990"

# ---- Steam shader pre-caching ----
# Undocumented (Valve doesn't publish it) Steam dev-config knob that
# dedicates background CPU threads to precompiling a game's shader cache
# after install/update, so the first few minutes of play aren't stuttery --
# see steam_dev.cfg below. Since this is a live streaming rig with
# real-time encoding, this defaults to half your CPU threads rather than
# the "leave 4-6 free" usually recommended for a plain desktop, so a
# concurrent download/shader-precache doesn't compete with an active
# stream. Lower it if you notice contention; 0 disables the line entirely.
STEAM_SHADER_BG_THREADS=$(( $(nproc) / 2 ))

# ---- Session ----
# The user the streaming session runs as. Defaults to whoever invoked sudo.
TARGET_USER="${SUDO_USER:-$USER}"
