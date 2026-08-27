#!/usr/bin/env bash

# X11 port of focus_or_launch.sh.
#
# Focuses an already-open window by class, launching the app only if no such
# window exists. Single-instance apps (blueman-manager, pavucontrol) otherwise
# appear "dead" when clicked: the second invocation sees the existing D-Bus
# name, exits immediately, and never raises the window sitting on some other
# workspace.
#
# Usage: focus_or_launch_x11.sh <window-class> <command> [args...]

set -euo pipefail

class="${1:?usage: focus_or_launch_x11.sh <window-class> <command> [args...]}"
shift
cmd=("${@:?usage: focus_or_launch_x11.sh <window-class> <command> [args...]}")

# Deliberately unanchored, matching Hyprland's `class:` selector: the one
# caller passes "blueman-manager" while the window's actual class is
# ".blueman-manager-wrapped" (the NixOS wrapper script's name), so an anchored
# ^...$ would never hit.
#
# i3-msg reports a miss honestly -- the reply's "success" field is false when
# nothing matched -- so unlike the Hyprland version this needs no matching on
# the text of an error message.
if [[ "$(i3-msg -t command "[class=\"${class}\"] focus" | jq -r '.[0].success')" != "true" ]]; then
    exec "${cmd[@]}"
fi
