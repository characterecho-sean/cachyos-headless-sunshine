#!/bin/sh
# Thin dispatcher: starts Sunshine, then hands off to the streaming session.
# Calibration no longer needs its own session/mode-flag dance -- it runs as
# a Steam non-Steam-game shortcut (see hdr-calibrate-launch.sh and
# install.sh's shortcuts.vdf setup), launched via Steam's own IPC with
# gamescope while Steam keeps running normally. The only time this whole
# session restarts is to pick up new --hdr-itm-*-nits values (gamescope
# startup-only flags); see streaming-session.sh's resume-calibrate handling
# for what happens next.

sleep 1

sunshine &

exec "$HOME/.config/streaming-rig/streaming-session.sh"
