#!/bin/sh
# HDR calibration session: runs the calibration tool in the foreground.
# When it exits -- the normal "Exit" button, or killed by
# exit-calibration.sh if the client disconnected first -- reset to normal
# mode and hand off to the streaming session directly. No gamescope
# restart needed just to leave calibration mode.
python3 "$HOME/.config/streaming-rig/hdr-calibrate.py"
echo steam > "$HOME/.config/streaming-rig/mode"
exec "$HOME/.config/streaming-rig/streaming-session.sh"
