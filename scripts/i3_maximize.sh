#!/usr/bin/env bash

# Stands in for Hyprland's fullscreen mode = "maximized", which fills the
# monitor but leaves the bar visible. i3 has no such state: `fullscreen`
# always covers docks, which is what Meta+Alt+F is for.
#
# So maximizing here means floating the window over the workspace's usable
# area -- the rect i3 reports for a workspace already excludes polybar and any
# other dock, so no bar height has to be guessed at.
#
# The i3 mark carries the state, because i3 has nowhere else to record it and a
# mark travels with the window. It also carries what to restore, since i3 keeps
# no memory of a window's geometry once something else has set it:
#
#   maxi:<id>:tile                 -- was tiled; put it back in the layout
#   maxi:<id>:float:<x>:<y>:<w>:<h> -- was floating; put those numbers back

set -euo pipefail

read -r con_id floating x y w h < <(
    i3-msg -t get_tree | jq -r '
        def leaves: recurse(.nodes[]?, .floating_nodes[]?)
                    | select(.nodes == [] and .floating_nodes == []);
        [ leaves | select(.focused) ] | first
        | "\(.id) \(.floating) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"
    '
)
[[ -n ${con_id:-} && $con_id != null ]] || exit 0

# Already maximized: read the restore target out of the mark and undo it.
existing=$(i3-msg -t get_marks | jq -r --arg id "$con_id" '.[] | select(startswith("maxi:" + $id + ":"))' | head -n1)
if [[ -n $existing ]]; then
    IFS=: read -r _ _ kind ox oy ow oh <<<"$existing"
    if [[ $kind == tile ]]; then
        i3-msg -t command "[con_mark=\"^${existing}$\"] unmark ${existing}, floating disable" >/dev/null
    else
        i3-msg -t command "[con_mark=\"^${existing}$\"] unmark ${existing}, resize set ${ow} px ${oh} px, move position ${ox} px ${oy} px" >/dev/null
    fi
    exit 0
fi

# The workspace's usable area, i.e. what is left after the docks.
read -r wx wy ww wh < <(
    i3-msg -t get_workspaces | jq -r '
        .[] | select(.focused) | .rect | "\(.x) \(.y) \(.width) \(.height)"
    '
)
[[ -n ${ww:-} ]] || exit 0

# "user_on" and "auto_on" both mean floating; anything else means tiled.
if [[ $floating == *on ]]; then
    mark="maxi:${con_id}:float:${x}:${y}:${w}:${h}"
else
    mark="maxi:${con_id}:tile"
fi

i3-msg -t command "mark --add \"${mark}\", floating enable, resize set ${ww} px ${wh} px, move position ${wx} px ${wy} px" >/dev/null
