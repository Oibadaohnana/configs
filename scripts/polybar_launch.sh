#!/usr/bin/env bash

# waybar draws a bar on every output by itself. polybar does not -- one process
# draws one bar on one monitor -- so this starts a process per connected
# output, which is what makes `monitor = ${env:MONITOR:}` in
# configs/polybarconfig/config.ini resolve to something.
#
# Called from configs/i3config at login, and again by hand (or by another
# i3 reload) after plugging a display in.

set -euo pipefail

CONFIG=~/nixcfg/configs/polybarconfig/config.ini

# Old bars first: i3's `exec` runs again on nothing but a restart, yet
# monitors_x11.sh's hotplug handling may call this at any time, and a second
# bar on the same output would just sit on top of the first.
pkill -u "$UID" -x polybar || true

# polybar refuses to start while the previous one still holds its IPC socket.
while pgrep -u "$UID" -x polybar >/dev/null; do sleep 0.2; done

# --listmonitors rather than --query: it lists only the outputs that are
# actually on, so a display switched off by monitors_x11.sh gets no bar.
while read -r output; do
    MONITOR="$output" polybar --config="$CONFIG" --reload main >/dev/null 2>&1 &
done < <(xrandr --listmonitors | awk 'NR > 1 { print $NF }')
