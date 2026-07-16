#!/bin/sh
# Sunshine prep-cmd "do" for the "Calibrate HDR" app: arm the selector gamescope-session.sh
# checks on its next launch, then restart the session (tty1 autologin respawns it immediately).
mkdir -p "$HOME/.config/streaming-rig"
echo "calibrate" > "$HOME/.config/streaming-rig/next-app"
# No -u/-x: Sunshine's subprocess env may not set $USER, and gamescope's
# running process is actually named "gamescope-wl" (not "gamescope") once
# its Wayland compositor loop is up, so an exact match against "gamescope"
# never hits. Plain substring pkill catches "gamescope-wl" and the
# gamescopereaper helpers too, which we want gone for a clean restart
# anyway. `|| true` since "no matching process" isn't a real failure here.
pkill gamescope || true
