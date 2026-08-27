#!/usr/bin/env bash

# hyprlock's stand-in, and the `lock_cmd` / `before_sleep_cmd` of
# configs/hypridleconfig in one script.
#
# The pidof guard is hypridleconfig's ("pidof hyprlock || hyprlock"): xss-lock
# fires on the screensaver *and* before sleep, and a second i3lock would
# otherwise stack a lock screen on top of the first.
#
# -n keeps i3lock in the foreground, which is what lets xss-lock hold the
# systemd sleep inhibitor until the screen is actually locked -- without it the
# machine can suspend before the lock appears, and wake showing the desktop.

set -euo pipefail

pidof i3lock >/dev/null && exit 0

# hypridleconfig's after_sleep_cmd = "hyprctl dispatch dpms on". Runs once
# i3lock returns, i.e. after the unlock, so a monitor that stayed blanked
# through the suspend comes back.
trap 'xset dpms force on' EXIT

i3lock -n -c 000000
