#!/bin/sh
# Sunshine prep-cmd "do" for the "Calibrate HDR" app: arm the selector gamescope-session.sh
# checks on its next launch, then restart the session (tty1 autologin respawns it immediately).
mkdir -p "$HOME/.config/streaming-rig"
echo "calibrate" > "$HOME/.config/streaming-rig/next-app"
pkill -u "$USER" -x gamescope
