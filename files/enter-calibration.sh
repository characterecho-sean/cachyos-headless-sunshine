#!/bin/sh
# Sunshine prep-cmd "do" for the "Calibrate HDR" app.
mkdir -p "$HOME/.config/streaming-rig"
echo calibrate > "$HOME/.config/streaming-rig/mode"
# Delayed and detached: killing gamescope also kills Sunshine itself (a
# descendant of the same session), and if that happens synchronously,
# Moonlight's RTSP handshake fails outright since the old Sunshine is dead
# and the new one isn't up yet. Waiting a few seconds lets the current
# launch/stream handshake complete first, so the restart reads as a
# normal mid-stream interruption instead of a dead connection. setsid so
# this survives even if Sunshine cleans up this script's own process
# group once it exits.
setsid sh -c 'sleep 5; pkill gamescope' < /dev/null > /dev/null 2>&1 &
