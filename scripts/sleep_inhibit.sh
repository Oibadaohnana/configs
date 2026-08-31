#!/usr/bin/env bash

# Blocks and unblocks automatic sleep, and feeds waybar a tile showing which
# of the two the system is currently in.
#
# The block is a systemd-inhibit lock held by a transient user unit called
# "nosleep" -- one lock covering suspend, the lid switch and idle, so closing
# the lid, hypridle's timeout and `systemctl suspend` are all held off at once.
# Stopping the unit drops the lock.
#
# The zshrc sleepoff/sleepon aliases call this too, so the tile stays in step
# with whatever was typed in a terminal.
#
# Usage:
#   sleep_inhibit.sh waybar     JSON for the custom/sleep module
#   sleep_inhibit.sh toggle     block <-> allow
#   sleep_inhibit.sh block      block sleep (sleepoff)
#   sleep_inhibit.sh allow      allow sleep again (sleepon)
#   sleep_inhibit.sh status     exit 0 if sleep is currently blocked

set -euo pipefail

UNIT=nosleep
WAYBAR_SIGNAL=9
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
ICON_BLOCKED=$'\uf0f4'   # nf-fa-coffee
ICON_ALLOWED=$'\uf186'   # nf-fa-moon_o

is_blocked() {
    systemctl --user is-active --quiet "$UNIT.service"
}

# waybar only re-runs this script every "interval" seconds; the signal makes a
# change land on the bar at once instead of on the next poll.
refresh_waybar() {
    pkill "-RTMIN+$WAYBAR_SIGNAL" waybar 2>/dev/null || true
}

notify() {
    local title=$1 body=$2 id_file="$RUNTIME_DIR/sleep-inhibit-notify.id" prev_id new_id
    prev_id=$(cat "$id_file" 2>/dev/null || echo 0)
    new_id=$(notify-send -p -r "$prev_id" -a "sleep-inhibit" "$title" "$body" 2>/dev/null || echo 0)
    printf '%s\n' "$new_id" >"$id_file"
}

cmd_block() {
    if ! is_blocked; then
        # A transient unit left behind in "failed" state keeps its name taken,
        # and systemd-run would refuse to reuse it.
        systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
        systemd-run --quiet --user --unit="$UNIT" \
            systemd-inhibit --what=sleep:handle-lid-switch:idle \
            --who=sleepoff --why=sleepoff --mode=block \
            sleep infinity >/dev/null
        notify "$ICON_BLOCKED Sleep blocked" "Lid, idle and suspend are held off."
    fi
    refresh_waybar
}

cmd_allow() {
    if is_blocked; then
        systemctl --user stop "$UNIT.service"
        notify "$ICON_ALLOWED Sleep allowed" "Normal suspend and lid behaviour."
    fi
    refresh_waybar
}

cmd_toggle() {
    if is_blocked; then cmd_allow; else cmd_block; fi
}

cmd_waybar() {
    if is_blocked; then
        printf '{"text":"%s","tooltip":"Sleep blocked -- click to allow it again","class":"blocked"}\n' \
            "$ICON_BLOCKED"
    else
        printf '{"text":"%s","tooltip":"Sleep allowed -- click to block it","class":"allowed"}\n' \
            "$ICON_ALLOWED"
    fi
}

case "${1:-}" in
    waybar) cmd_waybar ;;
    toggle) cmd_toggle ;;
    block)  cmd_block ;;
    allow)  cmd_allow ;;
    status) is_blocked ;;
    *)
        echo "Usage: $0 {waybar|toggle|block|allow|status}" >&2
        exit 1
        ;;
esac
