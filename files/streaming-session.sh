#!/bin/sh
# Normal streaming session: Steam Big Picture, spoofed as genuine
# SteamOS/Deck hardware so the Quick Access Menu unlocks Deck-specific
# features (Performance Overlay Level / MangoHud visibility, etc.) that
# aren't otherwise exposed on a vanilla desktop Linux + gamescope setup.
export SteamDeck=1
exec steam -bigpicture -steamos3
