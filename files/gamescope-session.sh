#!/bin/sh
# gamescope session: gamescope itself is the compositor and drives the DRM
# output directly. Sunshine and Steam are launched as gamescope's children
# so they inherit the WAYLAND_DISPLAY socket gamescope creates for them.

sleep 1

sunshine &

exec steam -bigpicture
