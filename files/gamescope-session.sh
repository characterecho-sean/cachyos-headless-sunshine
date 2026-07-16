#!/bin/sh
# Thin dispatcher: starts Sunshine (shared by both modes), reads a
# persistent mode flag once, and execs into whichever session script
# matches. No watcher, no one-shot consumption -- mode switches happen by
# writing the flag file and restarting gamescope (see
# enter-calibration.sh / exit-calibration.sh / hdr-calibrate.py's "Apply &
# Preview"), and whichever script is current on the next launch just runs
# straight through.

sleep 1

sunshine &

MODE_FILE="$HOME/.config/streaming-rig/mode"
MODE=$(cat "$MODE_FILE" 2>/dev/null || echo steam)

if [ "$MODE" = "calibrate" ]; then
    exec "$HOME/.config/streaming-rig/calibration-session.sh"
else
    exec "$HOME/.config/streaming-rig/streaming-session.sh"
fi
