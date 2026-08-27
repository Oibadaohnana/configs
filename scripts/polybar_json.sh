#!/usr/bin/env bash

# Adapter between waybar's JSON module protocol and polybar's plain-text one.
#
# scripts/audio_sink.sh is shared with the Wayland session and emits one JSON
# object per line, as waybar wants. polybar script modules read raw text, so
# this runs the producer and prints just the "text" field of each object.
#
# The tooltip and class fields are dropped rather than translated: polybar
# script modules have neither.
#
# Usage: polybar_json.sh <command> [args...]

set -euo pipefail

# --unbuffered so a streaming producer (audio_sink.sh waybar never exits)
# reaches the bar as each line arrives instead of sitting in a 4 KB buffer.
"$@" | jq --unbuffered -r '.text // empty'
