#!/bin/sh
# Gamescope session: gamescope itself is the compositor and drives the DRM
# output directly (native res, HDR via --hdr-itm-enabled so SDR/Proton games
# get real inverse tone-mapped HDR instead of raw PQ passthrough). Sunshine
# and Steam are launched as gamescope's children so they inherit the
# WAYLAND_DISPLAY socket gamescope creates for them.

sleep 1

sunshine &

SELECTOR="$HOME/.config/streaming-rig/next-app"

# Consume any pending request *before* starting the watcher below --
# otherwise the watcher races the same check and can independently see
# the same stale "calibrate" file, scheduling its own spurious restart a
# few seconds after we've already legitimately entered the tool.
ENTER_CALIBRATE=false
if [ -f "$SELECTOR" ] && [ "$(cat "$SELECTOR")" = "calibrate" ]; then
    rm -f "$SELECTOR"   # one-shot: a crash in the tool won't loop forever
    ENTER_CALIBRATE=true
fi

# Watches for a restart request written by enter-calibration.sh or the
# calibration tool's own "Apply & Preview" button (while it's running,
# below), and performs the actual gamescope kill after a short delay (so
# an in-flight Moonlight launch/RTSP handshake has time to complete
# first, rather than racing a dead connection). Runs as our own child,
# not something Sunshine spawned per-request, so it isn't torn down by
# whatever process-group cleanup Sunshine does once its own prep-cmd
# script exits. Exits on its own once gamescope itself is gone, for any
# reason, so it doesn't linger forever. Started only after the consume
# step above, so it only ever reacts to a genuinely fresh request.
(
    while pgrep -f "^gamescope --backend" >/dev/null 2>&1; do
        if [ -f "$SELECTOR" ]; then
            sleep 5
            pkill gamescope
            break
        fi
        sleep 1
    done
) &

if [ "$ENTER_CALIBRATE" = "true" ]; then
    python3 "$HOME/.config/streaming-rig/hdr-calibrate.py"
    # falls through to the normal Steam launch below once the tool exits
fi

# Makes Steam's client believe it's running on genuine SteamOS/Deck hardware,
# which unlocks Deck-specific Big Picture UI features (e.g. the QAM's
# Performance Overlay Level / MangoHud visibility control) that aren't
# otherwise exposed on a vanilla desktop Linux + gamescope setup.
export SteamDeck=1

exec steam -bigpicture -steamos3
