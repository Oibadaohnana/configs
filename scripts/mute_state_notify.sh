#!/usr/bin/env bash

# Get default output sink (your speakers/headphones)
sink=$(pactl get-default-sink)
pactl set-sink-mute $sink toggle
# Get mute state of that sink
MUTE_state=$(pactl get-sink-mute $sink | awk '{print $2}')

if [[ "$MUTE_state" == "yes" ]]; then
    notify-send "🔇 Audio is muted"
else
    notify-send "🔊 Audio is unmuted"
fi
