#!/bin/sh
# Sunshine prep-cmd "undo" for "Calibrate HDR": if the Moonlight client
# disconnects without the user hitting "Exit" inside the tool, kill just
# the calibration tool's own process. calibration-session.sh notices it
# exited and hands off to the normal streaming session on its own -- no
# gamescope restart needed, and there's no in-flight handshake to protect
# here since the client is already disconnecting.
pkill -f hdr-calibrate.py || true
