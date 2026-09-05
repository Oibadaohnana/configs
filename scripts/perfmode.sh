#!/usr/bin/env bash

# Switches the machine between three performance modes, and feeds waybar a tile
# showing which one is on.
#
# Hyprland has no performance mode of its own, so a mode here is two unrelated
# knobs turned together:
#
#   power-profiles-daemon   what the CPU is allowed to do -- the amd-pstate EPP
#                           hint plus the ACPI platform profile, i.e. power
#                           limits and fan curve.
#   Hyprland eye candy      blur, animations, inactive-window transparency and
#                           tearing, all of which cost GPU time every frame.
#
# performance is the default: it is what a machine with no saved mode gets, and
# what the static values in configs/hyprland.lua are written for.
#
# The pick is stored in $XDG_STATE_HOME/hypr/perfmode. Two things read it back,
# because neither can do the other's half:
#   - hyprland.lua, at startup and on every `hyprctl reload`, for the eye candy.
#     Reading it there rather than shelling out means no flash of the wrong
#     settings, and Super+Shift+C does not throw the mode away.
#   - this script's `apply`, run from exec-once, for the daemon -- whose profile
#     is not remembered across a reboot.
# The hyprctl calls below only serve the session already running.
#
# Usage:
#   perfmode.sh waybar      JSON for the custom/perfmode module
#   perfmode.sh next        cycle to the next mode (wraps)
#   perfmode.sh prev        cycle to the previous mode (wraps)
#   perfmode.sh menu        pick a mode from a rofi list
#   perfmode.sh set <mode>  switch to one mode by name
#   perfmode.sh apply       re-apply the saved mode, no notification
#   perfmode.sh get         print the saved mode name

set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/perfmode"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
WAYBAR_SIGNAL=10

# Order matters: `next` walks this list top to bottom, and MODES[0] is the
# default. The names are power-profiles-daemon's own, so they go to
# powerprofilesctl unchanged.
MODES=(performance balanced power-saver)

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
declare -A ICONS=(
    [performance]=$'\uf0e7'   # nf-fa-bolt
    [balanced]=$'\uf24e'      # nf-fa-balance_scale
    [power-saver]=$'\uf06c'   # nf-fa-leaf
)

declare -A LABELS=(
    [performance]="Performance"
    [balanced]="Balanced"
    [power-saver]="Power saver"
)

declare -A BLURBS=(
    [performance]="Full clocks, no blur or animations"
    [balanced]="Blur and animations back on"
    [power-saver]="Clocks capped, tearing off"
)

# Hyprland half of each mode, as a Lua snippet for `hyprctl eval`. Keep in step
# with the perfmodes table in configs/hyprland.lua -- that one sets the same
# values at startup, this one only reaches the running session.
#
# eval rather than the more obvious `hyprctl keyword`: keyword speaks the
# legacy hyprland.conf syntax and refuses outright ("keyword can't work with
# non-legacy parsers") now that the config is Lua. It still exits 0 while doing
# nothing, so a silent no-op is the failure mode to watch for here.
declare -A HYPR=(
    [performance]='hl.config({ general = { allow_tearing = true }, decoration = { inactive_opacity = 1.0, blur = { enabled = false } }, animations = { enabled = false } })'
    [balanced]='hl.config({ general = { allow_tearing = true }, decoration = { inactive_opacity = 0.9, blur = { enabled = true, size = 5, passes = 2 } }, animations = { enabled = true } })'
    [power-saver]='hl.config({ general = { allow_tearing = false }, decoration = { inactive_opacity = 1.0, blur = { enabled = false } }, animations = { enabled = false } })'
)

is_mode() {
    local m
    for m in "${MODES[@]}"; do [[ $1 == "$m" ]] && return 0; done
    return 1
}

# An unreadable, empty or garbage state file all mean the same thing: nobody
# has picked yet, so the default stands.
current() {
    local mode=""
    [[ -r $STATE_FILE ]] && read -r mode <"$STATE_FILE" || true
    is_mode "$mode" || mode="${MODES[0]}"
    printf '%s\n' "$mode"
}

# What the daemon says is actually running, which is not always what was asked
# for: PPD downgrades "performance" on battery or when the machine is hot, and
# forgets the profile entirely across a reboot.
live_profile() {
    command -v powerprofilesctl >/dev/null 2>&1 || return 0
    powerprofilesctl get 2>/dev/null || true
}

# waybar only re-runs this script every "interval" seconds; the signal makes a
# change land on the bar at once instead of on the next poll.
refresh_waybar() {
    pkill "-RTMIN+$WAYBAR_SIGNAL" waybar 2>/dev/null || true
}

notify() {
    local title=$1 body=$2 id_file="$RUNTIME_DIR/perfmode-notify.id" prev_id new_id
    prev_id=$(cat "$id_file" 2>/dev/null || echo 0)
    new_id=$(notify-send -p -r "$prev_id" -a "perfmode" "$title" "$body" 2>/dev/null || echo 0)
    printf '%s\n' "$new_id" >"$id_file"
}

# Neither half is fatal to the other: the desktop may not run PPD, and this is
# also called from a shell with no Hyprland instance to talk to.
apply_mode() {
    local mode=$1
    if command -v powerprofilesctl >/dev/null 2>&1; then
        powerprofilesctl set "$mode" 2>/dev/null || true
    fi
    if command -v hyprctl >/dev/null 2>&1; then
        hyprctl eval "${HYPR[$mode]}" >/dev/null 2>&1 || true
    fi
}

cmd_set() {
    local mode=${1:-}
    if ! is_mode "$mode"; then
        echo "Unknown mode: $mode (want one of: ${MODES[*]})" >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$mode" >"$STATE_FILE"
    apply_mode "$mode"
    notify "${ICONS[$mode]} ${LABELS[$mode]}" "${BLURBS[$mode]}"
    refresh_waybar
}

cmd_apply() {
    apply_mode "$(current)"
    refresh_waybar
}

# step is +1 or -1; the modulo wraps either way round the list.
cmd_cycle() {
    local step=$1 cur i n=${#MODES[@]}
    cur=$(current)
    for i in "${!MODES[@]}"; do
        if [[ ${MODES[i]} == "$cur" ]]; then
            cmd_set "${MODES[(i + step + n) % n]}"
            return
        fi
    done
    cmd_set "${MODES[0]}"
}

# One row per mode, highest first, marker on the current one. Closes on the
# pick; rofi exits non-zero on Esc, hence the `|| return 0`.
cmd_menu() {
    local cur mode rows="" marker choice
    cur=$(current)
    for mode in "${MODES[@]}"; do
        [[ $mode == "$cur" ]] && marker="●" || marker="○"
        rows+="$marker ${ICONS[$mode]}  ${LABELS[$mode]}  --  ${BLURBS[$mode]}"$'\n'
    done
    # -format i returns the row index, which maps straight onto MODES.
    choice=$(printf '%s' "$rows" | rofi -dmenu -i -p "Performance" -format i \
        -mesg "Fastest at the top") || return 0
    [[ -n $choice ]] || return 0
    cmd_set "${MODES[choice]}"
}

cmd_waybar() {
    local mode live tooltip
    mode=$(current)
    tooltip="${LABELS[$mode]} -- ${BLURBS[$mode]}"
    live=$(live_profile)
    # Only worth a line when the two disagree -- a hand-run powerprofilesctl,
    # or PPD refusing "performance" because the machine is on battery or hot.
    if [[ -n $live && $live != "$mode" ]]; then
        tooltip+='\nCPU profile is '"$live"' right now'
    fi
    tooltip+='\nClick to cycle, right-click to pick'
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "${ICONS[$mode]}" "$tooltip" "$mode"
}

case "${1:-}" in
    waybar) cmd_waybar ;;
    next)   cmd_cycle 1 ;;
    prev)   cmd_cycle -1 ;;
    menu)   cmd_menu ;;
    set)    cmd_set "${2:-}" ;;
    apply)  cmd_apply ;;
    get)    current ;;
    *)
        echo "Usage: $0 {waybar|next|prev|menu|set <mode>|apply|get}" >&2
        exit 1
        ;;
esac
