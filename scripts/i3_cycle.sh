#!/usr/bin/env bash

# Stands in for Hyprland's cyclenext dispatcher, which i3 has no equivalent of
# -- `focus left/right/up/down` walks the tiling tree geometrically, and there
# is no `focus next`.
#
# Like cyclenext, this cycles the windows of the *active workspace* only, in
# layout order, wrapping at the ends. Floating windows are included, as they
# are in Hyprland.
#
# Usage: i3_cycle.sh [next|prev]

set -euo pipefail

dir="${1:-next}"

# Every leaf of the focused workspace, in tree order, plus which one is
# focused. `recurse` walks both the tiling children and the floating ones,
# because i3 keeps them in separate arrays.
i3-msg -t get_tree | jq -r --arg dir "$dir" '
    def leaves: recurse(.nodes[]?, .floating_nodes[]?) | select(.nodes == [] and .floating_nodes == []);

    # The workspace containing the focused window, not merely a focused
    # workspace: on a multi-monitor setup every output has one of those.
    [ recurse(.nodes[]?, .floating_nodes[]?)
      | select(.type == "workspace")
      | select([leaves | select(.focused)] | length > 0) ]
    | first
    | [ leaves | select(.window != null) ]
    | . as $w
    | ($w | map(.focused) | index(true)) as $i
    | if $i == null or ($w | length) < 2 then empty
      else $w[ if $dir == "prev" then $i - 1 else ($i + 1) % ($w | length) end ].id
      end
' | while read -r id; do
    [[ -n $id ]] && i3-msg -t command "[con_id=$id] focus" >/dev/null
done
