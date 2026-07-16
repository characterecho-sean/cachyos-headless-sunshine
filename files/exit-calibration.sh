#!/bin/sh
# Sunshine prep-cmd "undo" for "Calibrate HDR": if the Moonlight client
# disconnects without the user hitting "Exit" inside the tool, force a
# clean return to the normal Steam session rather than looping back into
# calibration.
rm -f "$HOME/.config/streaming-rig/next-app"
pkill -u "$USER" -x gamescope
