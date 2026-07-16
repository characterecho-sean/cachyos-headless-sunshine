#!/bin/sh
# Sunshine prep-cmd "do" for the "Calibrate HDR" app: arm the selector gamescope-session.sh
# checks on its next launch, then restart the session (tty1 autologin respawns it immediately).
mkdir -p "$HOME/.config/streaming-rig"
echo "calibrate" > "$HOME/.config/streaming-rig/next-app"
# No -u/-x: Sunshine's subprocess env may not set $USER, and gamescope's
# running process is actually named "gamescope-wl" (not "gamescope") once
# its Wayland compositor loop is up, so an exact match against "gamescope"
# never hits. Plain substring pkill catches "gamescope-wl" and the
# gamescopereaper helpers too, which we want gone for a clean restart.
#
# Delayed and detached: killing gamescope also kills Sunshine itself (it's
# a descendant of the same session), and if that happens synchronously,
# Moonlight's RTSP handshake fails outright since the old Sunshine is dead
# and the new one isn't up yet. Waiting a few seconds lets the current
# launch/stream handshake complete first, so the restart reads as a normal
# mid-stream interruption instead of a dead connection.
(sleep 5; pkill gamescope) >/dev/null 2>&1 &
disown 2>/dev/null || true
