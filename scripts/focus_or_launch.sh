#!/usr/bin/env bash

# Focuses an already-open window by class, launching the app only if no such
# window exists. Single-instance apps (blueman-manager, pavucontrol) otherwise
# appear "dead" when clicked: the second invocation sees the existing D-Bus
# name, exits immediately, and never raises the window sitting on some other
# workspace.
#
# Usage: focus_or_launch.sh <window-class> <command> [args...]

set -euo pipefail

class="${1:?usage: focus_or_launch.sh <window-class> <command> [args...]}"
shift
cmd=("${@:?usage: focus_or_launch.sh <window-class> <command> [args...]}")

# The lua config parser has no exit code for a missed focus -- it returns 0 and
# prints "hl.focus: window not found" -- so the miss has to be matched on text.
if hyprctl dispatch "hl.dsp.focus({ window = \"class:${class}\" })" 2>&1 |
        grep -q "window not found"; then
    exec "${cmd[@]}"
fi
