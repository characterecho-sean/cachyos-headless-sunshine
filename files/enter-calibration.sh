#!/bin/sh
# Sunshine prep-cmd "do" for the "Calibrate HDR" app: just flag the
# request. A persistent watcher started by gamescope-session.sh itself
# (not spawned per-request by Sunshine, so nothing tears it down when this
# script exits) notices the flag and handles the actual delayed restart.
mkdir -p "$HOME/.config/streaming-rig"
echo "calibrate" > "$HOME/.config/streaming-rig/next-app"
