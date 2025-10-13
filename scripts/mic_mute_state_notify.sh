#!/usr/bin/env bash


source=$(pactl get-default-source)
pactl set-source-mute $source toggle

MUTE_state=$(pactl get-source-mute $source | awk '{print $2}')

mic_name=$(pactl list sources | awk -v src="$source" '
    $0 ~ "Name: "src {found=1}
    found && /Description:/ {print substr($0, index($0,$2)); exit}
')

if [[ "$MUTE_state" == "yes" ]]; then
    notify-send "🎤🔇 Mic is muted" "$mic_name"
else
    notify-send "🎤🔊 Mic is unmuted" "$mic_name"
fi
