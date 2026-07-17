#!/bin/sh
# Normal streaming session: Steam Big Picture, spoofed as genuine
# SteamOS/Deck hardware so the Quick Access Menu unlocks Deck-specific
# features (Performance Overlay Level / MangoHud visibility, etc.) that
# aren't otherwise exposed on a vanilla desktop Linux + gamescope setup.
export SteamDeck=1

# If we're restarting because "Apply & Preview" needed a gamescope restart
# to pick up new --hdr-itm-*-nits values, re-launch the calibration tool
# (as its Steam non-Steam-game shortcut) once Steam itself is back up, so
# the user lands right back in the calibration screen. Backgrounded and
# delayed since Steam needs real time after a cold start before it's ready
# to handle steam:// URLs -- much longer than when it's already running.
RESUME_FLAG="$HOME/.config/streaming-rig/resume-calibrate"
if [ -f "$RESUME_FLAG" ]; then
    rm -f "$RESUME_FLAG"
    GAMEID_FILE="$HOME/.config/streaming-rig/hdr-calibrate-gameid"
    GAMEID=$(cat "$GAMEID_FILE" 2>/dev/null)
    if [ -n "$GAMEID" ]; then
        (sleep 15; steam "steam://rungameid/$GAMEID") >/dev/null 2>&1 &
    fi
fi

exec steam -bigpicture -steamos3
