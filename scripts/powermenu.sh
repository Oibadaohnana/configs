#!/usr/bin/env bash

# Stands in for wlogout (Ctrl+Alt+Del) and for waybar's custom/power menu, both
# of which are Wayland-only. Same four actions waybar's menu-actions listed,
# plus the lock and logout entries wlogout showed, in a rofi list.
#
# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.

set -euo pipefail

LOCK=$'\uf023'       # nf-fa-lock
SUSPEND=$'\uf186'    # nf-fa-moon_o
HIBERNATE=$'\uf2dc'  # nf-fa-snowflake_o
REBOOT=$'\uf021'     # nf-fa-refresh
POWEROFF=$'\uf011'   # nf-fa-power_off -- same glyph waybar's custom/power used
LOGOUT=$'\uf08b'     # nf-fa-sign_out

# Fixed order, and a parallel array rather than an associative one: a power
# menu whose entries move between invocations is a way to reboot by muscle
# memory, and bash associative arrays have no order of their own.
labels=(
    "$LOCK  Lock"
    "$SUSPEND  Suspend"
    "$HIBERNATE  Hibernate"
    "$REBOOT  Reboot"
    "$POWEROFF  Shut Down"
    "$LOGOUT  Log Out"
)
commands=(
    "$HOME/nixcfg/scripts/i3lock_wrapper.sh"
    "systemctl suspend"
    "systemctl hibernate"
    "systemctl reboot"
    "systemctl poweroff"
    "i3-msg exit"
)

# -format i returns the row index, so the label never has to be parsed back
# into an action. -no-custom because every entry here is destructive enough
# that a typo should not become a command.
choice=$(printf '%s\n' "${labels[@]}" |
    rofi -dmenu -i -p "Power" -format i -no-custom) || exit 0
[[ -n $choice ]] || exit 0

exec ${commands[choice]}
