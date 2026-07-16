#!/bin/sh
# Sunshine prep-cmd "undo" for "Calibrate HDR": if the Moonlight client
# disconnects without the user hitting "Exit" inside the tool, force a
# clean return to the normal Steam session. Kill just the calibration
# tool's own process (not gamescope/the whole session) -- that's enough
# for gamescope-session.sh to fall through to the normal Steam launch on
# its own, and there's no in-flight handshake to protect here since the
# client is already disconnecting.
rm -f "$HOME/.config/streaming-rig/next-app"
pkill -f hdr-calibrate.py || true
