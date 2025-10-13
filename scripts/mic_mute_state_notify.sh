#!/usr/bin/env bash


source=$(pactl get-default-source)
pactl set-source-mute $source toggle

MUTE_state=$(pactl get-source-mute $source | awk '{print $2}')

if [[ "$MUTE_state" == "yes" ]]; then
    notify-send "🎤🔇 Mic is muted"
else
    notify-send "🎤🔊 Mic is unmuted"
fi
