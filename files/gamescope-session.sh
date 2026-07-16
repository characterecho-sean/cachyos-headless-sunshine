#!/bin/sh
# gamescope session: gamescope itself is the compositor and drives the DRM
# output directly. Sunshine and Steam are launched as gamescope's children
# so they inherit the WAYLAND_DISPLAY socket gamescope creates for them.

sleep 1

sunshine &

SELECTOR="$HOME/.config/streaming-rig/next-app"
if [ -f "$SELECTOR" ] && [ "$(cat "$SELECTOR")" = "calibrate" ]; then
    rm -f "$SELECTOR"   # one-shot: a crash in the tool won't loop forever
    python3 "$HOME/.config/streaming-rig/hdr-calibrate.py"
    # falls through to the normal Steam launch below once the tool exits
fi

# Makes Steam's client believe it's running on genuine SteamOS/Deck hardware,
# which unlocks Deck-specific Big Picture UI features (e.g. the QAM's
# Performance Overlay Level / MangoHud visibility control) that aren't
# otherwise exposed on a vanilla desktop Linux + gamescope setup.
export SteamDeck=1

exec steam -bigpicture -steamos3
