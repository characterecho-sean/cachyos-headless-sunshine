#!/bin/sh
# Non-Steam game entry point: Steam launches this directly (not the .py
# file itself), so Steam's own process/window tracking sees a normal shell
# -> python3 exec chain, same shape as how it launches real games.
exec python3 "$HOME/.config/streaming-rig/hdr-calibrate.py"
