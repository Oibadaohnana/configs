#!/usr/bin/env bash

grim -g "$(slurp)" - | tee /tmp/screenshot.png | wl-copy
notify-send "📸 Screenshot copied to clipboard you awesome stupid biaatch"