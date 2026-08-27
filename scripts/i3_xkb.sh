#!/usr/bin/env bash

# Stands in for `hyprctl switchxkblayout all next|prev`.
#
# The layout list is spelled out here rather than read back from the server,
# because the switch below sets one layout at a time -- after the first call
# `setxkbmap -query` would report only that one, and the list would be gone.
# Keep it in step with the setxkbmap line in configs/i3config.
#
# As written it holds a single layout, which makes both directions a no-op --
# exactly as they are under Hyprland, whose kb_layout is also just "de". The
# bindings exist for the day a second one is added, in both places.
#
# Usage: i3_xkb.sh [next|prev]

set -euo pipefail

LAYOUTS=(de)
OPTIONS="caps:super"

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/i3-xkb-layout"

dir="${1:-next}"
(( ${#LAYOUTS[@]} > 1 )) || exit 0

current=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
[[ $current =~ ^[0-9]+$ ]] || current=0

if [[ $dir == prev ]]; then
    next=$(( (current - 1 + ${#LAYOUTS[@]}) % ${#LAYOUTS[@]} ))
else
    next=$(( (current + 1) % ${#LAYOUTS[@]} ))
fi

setxkbmap -layout "${LAYOUTS[next]}" -option "$OPTIONS"
printf '%s\n' "$next" >"$STATE_FILE"

# -r with a fixed id so holding the key replaces the notification instead of
# stacking a queue of them, the same way volume_notify.sh does.
notify-send -a "keyboard" -r 9001 "Layout" "${LAYOUTS[next]}"
