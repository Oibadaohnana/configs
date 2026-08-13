#!/usr/bin/env bash

# Adjusts the default sink/source volume/mute state and shows a Plasma-style
# OSD (mako notification with a progress bar) so you can see the level
# without opening pavucontrol.

set -euo pipefail

sink=@DEFAULT_SINK@
source=@DEFAULT_SOURCE@
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

case "${1:-}" in
    up)
        pactl set-sink-mute "$sink" 0
        pactl set-sink-volume "$sink" "+${2:-5}%"
        ;;
    down)
        pactl set-sink-mute "$sink" 0
        pactl set-sink-volume "$sink" "-${2:-5}%"
        ;;
    mute)
        pactl set-sink-mute "$sink" toggle
        ;;
    mic-mute)
        pactl set-source-mute "$source" toggle
        ;;
    *)
        echo "Usage: $0 {up|down|mute|mic-mute} [step%]" >&2
        exit 1
        ;;
esac

notify() {
    local id_file="$RUNTIME_DIR/$1" icon="$2" title="$3" body="$4" hint="$5"
    local prev_id new_id
    prev_id=$(cat "$id_file" 2>/dev/null || echo 0)
    new_id=$(notify-send -p -r "$prev_id" -h "$hint" -a "volume" "$icon $title" "$body")
    echo "$new_id" >"$id_file"
}

if [[ "$1" == "mic-mute" ]]; then
    muted=$(pactl get-source-mute "$source" | awk '{print $2}')
    if [[ "$muted" == "yes" ]]; then
        icon="🔇"
        body="Muted"
    else
        icon="🎙️"
        body="Unmuted"
    fi
    notify "mic-notify.id" "$icon" "Microphone" "$body" "int:value:$([[ $muted == yes ]] && echo 0 || echo 100)"
    exit 0
fi

volume=$(pactl get-sink-volume "$sink" | awk '{print $5}' | tr -d '%' | head -n1)
muted=$(pactl get-sink-mute "$sink" | awk '{print $2}')

if [[ "$muted" == "yes" ]]; then
    icon="🔇"
    body="Muted"
elif (( volume >= 70 )); then
    icon="🔊"
    body="${volume}%"
elif (( volume >= 30 )); then
    icon="🔉"
    body="${volume}%"
else
    icon="🔈"
    body="${volume}%"
fi

notify "volume-notify.id" "$icon" "Volume" "$body" "int:value:$volume"
