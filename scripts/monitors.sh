#!/usr/bin/env bash

# Turns individual monitors on and off from a rofi list, and feeds waybar a
# tile showing how many are currently active.
#
# Why not `hyprctl keyword monitor ...`: under the Lua config parser that
# command is refused outright ("keyword can't work with non-legacy parsers"),
# so every change here goes through `hyprctl eval` calling hl.monitor() --
# the same call hyprland.lua itself uses.
#
# Persistence: Hyprland has no memory of a switched-off output, and the
# wildcard monitor rule in hyprland.lua re-enables anything it sees. So the
# set of switched-off outputs is written to a state file that hyprland.lua
# reads back when it loads and whenever a monitor appears. That file lives
# outside the nixcfg repo on purpose -- it is per-machine state, and the
# desktop and the framework have different output names.
#
# Worth knowing: switching an output off and back on can rearrange where the
# screens sit relative to each other. That is the `position = "auto"` wildcard
# rule in hyprland.lua doing its job -- "auto" places a monitor to the right of
# whatever is already on, so the one that comes back last lands on the right,
# regardless of where it used to be. Give an output an explicit position in
# hyprland.lua if its place in the row should be fixed, or nudge it afterwards
# with wdisplays (Meta+P, or right-click the waybar tile).
#
# Usage:
#   monitors.sh waybar          JSON for the custom/monitors module
#   monitors.sh menu            turn displays on/off from a rofi list
#   monitors.sh toggle <name>   flip one output
#   monitors.sh on <name>       turn one output on
#   monitors.sh off <name>      turn one output off
#   monitors.sh apply           re-apply the saved state to a running session
#   monitors.sh list            name<TAB>description<TAB>disabled<TAB>mode

set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/disabled-monitors"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Must match "signal" in the custom/monitors module in waybarconfig/config.
WAYBAR_SIGNAL=8

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
ICON_DISPLAY=$'\uf108'   # nf-fa-desktop
ICON_LAPTOP=$'\uf109'    # nf-fa-laptop

# name<TAB>description<TAB>disabled<TAB>mode, one monitor per line, in
# hyprctl's own order. The "all" is what makes this work at all: without it
# hyprctl omits disabled outputs entirely, so anything switched off would
# disappear from the menu and could never be switched back on.
monitor_list() {
    hyprctl monitors all | awk '
        function flush() {
            if (name != "")
                printf "%s\t%s\t%s\t%s\n", name, (desc == "" ? name : desc), dis, mode
        }
        /^Monitor / { flush(); name = $2; desc = ""; dis = "false"; mode = ""; next }
        # The current mode, e.g. "\t2560x1440@143.99001 at 0x0". Anchored on a
        # leading digit so the "availableModes:" line cannot match it.
        /^[ \t]+[0-9]+x[0-9]+@/ { if (mode == "") { split($1, m, "@"); mode = m[1] } next }
        /^[ \t]+description: / { sub(/^[ \t]+description: /, ""); desc = $0; next }
        /^[ \t]+disabled: /    { dis = $2; next }
        END { flush() }
    '
}

icon_for() {
    case "$1" in
        eDP-*|LVDS-*) printf '%s' "$ICON_LAPTOP" ;;
        *)            printf '%s' "$ICON_DISPLAY" ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# Output names are interpolated into a Lua snippet below, so refuse anything
# that is not shaped like one ("DP-2", "eDP-1", "HDMI-A-1").
valid_name() {
    [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]
}

saved_contains() {
    [[ -f $STATE_FILE ]] && grep -qxF "$1" "$STATE_FILE"
}

saved_add() {
    mkdir -p "$STATE_DIR"
    saved_contains "$1" || printf '%s\n' "$1" >>"$STATE_FILE"
}

saved_remove() {
    [[ -f $STATE_FILE ]] || return 0
    grep -vxF "$1" "$STATE_FILE" >"$STATE_FILE.tmp" || true
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# waybar only re-runs this script every "interval" seconds; the signal makes a
# toggle land on the bar at once instead of on the next poll.
refresh_waybar() {
    pkill "-RTMIN+$WAYBAR_SIGNAL" waybar 2>/dev/null || true
}

notify() {
    local title=$1 body=$2 id_file="$RUNTIME_DIR/monitors-notify.id" prev_id new_id
    prev_id=$(cat "$id_file" 2>/dev/null || echo 0)
    new_id=$(notify-send -p -r "$prev_id" -a "monitors" "$title" "$body" 2>/dev/null || echo 0)
    printf '%s\n' "$new_id" >"$id_file"
}

enabled_count() {
    local name desc dis mode n=0
    while IFS=$'\t' read -r name desc dis mode; do
        if [[ $dis == false ]]; then n=$((n + 1)); fi
    done < <(monitor_list)
    printf '%s' "$n"
}

describe() {
    local target=$1 name desc dis mode
    while IFS=$'\t' read -r name desc dis mode; do
        [[ $name == "$target" ]] && { printf '%s' "$desc"; return; }
    done < <(monitor_list)
    printf '%s' "$target"
}

# The state file is written *before* the compositor call on purpose: enabling
# an output makes Hyprland fire monitor.added, and hyprland.lua answers that by
# re-applying the saved state. Were the name still listed as off at that
# moment, the monitor would be switched straight back off again.
set_monitor() {
    local name=$1 disabled=$2
    valid_name "$name" || { echo "Refusing odd output name: $name" >&2; return 1; }

    if [[ $disabled == true ]]; then saved_add "$name"; else saved_remove "$name"; fi
    hyprctl eval "hl.monitor({ output = \"$name\", disabled = $disabled })" >/dev/null

    if [[ $disabled == true ]]; then
        notify "$(icon_for "$name") Display off" "$(describe "$name")"
    else
        notify "$(icon_for "$name") Display on" "$(describe "$name")"
    fi
    refresh_waybar
}

# Refuse to switch off the last one standing: Hyprland with zero enabled
# outputs has nowhere to put windows, and leaves no screen to undo it on.
turn_off() {
    local name=$1
    if (( $(enabled_count) <= 1 )); then
        notify "Keeping $name on" "It is the only active display."
        return 0
    fi
    set_monitor "$name" true
}

cmd_toggle() {
    local target=$1 name desc dis mode state=""
    while IFS=$'\t' read -r name desc dis mode; do
        if [[ $name == "$target" ]]; then state=$dis; break; fi
    done < <(monitor_list)

    if [[ -z $state ]]; then
        notify "No such display" "$target is not connected."
        return 1
    fi

    if [[ $state == false ]]; then turn_off "$target"; else set_monitor "$target" false; fi
}

# Stays open after each pick so several displays can be flipped in one go;
# Esc closes it. rofi exits non-zero on Esc, hence the `|| return 0`.
cmd_menu() {
    local -a names=() rows=()
    local name desc dis mode marker choice i menu

    while :; do
        names=(); rows=()
        while IFS=$'\t' read -r name desc dis mode; do
            names+=("$name")
            [[ $dis == false ]] && marker="●" || marker="○"
            rows+=("$marker $(icon_for "$name")  $desc ($name)  $mode")
        done < <(monitor_list)
        (( ${#names[@]} )) || return 0

        menu=""
        for i in "${!rows[@]}"; do menu+="${rows[i]}"$'\n'; done

        # -format i returns the row index, so two identical panels stay
        # distinguishable.
        choice=$(printf '%s' "$menu" | rofi -dmenu -i -p "Displays" -format i \
            -mesg "Enter toggles a display, Esc when done") || return 0
        [[ -n $choice ]] || return 0

        cmd_toggle "${names[choice]}" || true
        # Hyprland needs a moment before hyprctl reports the new state.
        sleep 0.4
    done
}

cmd_waybar() {
    local name desc dis mode total=0 active=0 tooltip="" marker text class
    while IFS=$'\t' read -r name desc dis mode; do
        total=$((total + 1))
        if [[ $dis == false ]]; then
            active=$((active + 1)); marker="● "
        else
            marker="○ "
        fi
        tooltip+="$marker$(json_escape "$desc") ($(json_escape "$name")) $mode\\n"
    done < <(monitor_list)

    (( total )) || { printf '{"text":"","tooltip":"No displays"}\n'; return 0; }

    # The count only says anything when there is more than one display to
    # count, so a single-panel laptop just gets the icon.
    if (( total > 1 )); then text="$ICON_DISPLAY $active"; else text="$ICON_DISPLAY"; fi
    if (( active < total )); then class="partial"; else class="all"; fi

    tooltip="Displays: $active of $total active\\n\\n${tooltip%\\n}"
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "$(json_escape "$text")" "$tooltip" "$class"
}

# hyprland.lua applies the saved state itself when it loads; this entry point
# is for repairing a running session by hand. It keeps the same last-display
# guard, so a stale state file can never black out the session.
cmd_apply() {
    [[ -f $STATE_FILE ]] || return 0
    local name
    while read -r name; do
        [[ -n $name && $name != \#* ]] || continue
        turn_off "$name"
    done <"$STATE_FILE"
    refresh_waybar
}

case "${1:-}" in
    waybar) cmd_waybar ;;
    menu)   cmd_menu ;;
    toggle) cmd_toggle "${2:?usage: $0 toggle <output>}" ;;
    on)     set_monitor "${2:?usage: $0 on <output>}" false ;;
    off)    turn_off "${2:?usage: $0 off <output>}" ;;
    apply)  cmd_apply ;;
    list)   monitor_list ;;
    *)
        echo "Usage: $0 {waybar|menu|toggle <output>|on <output>|off <output>|apply|list}" >&2
        exit 1
        ;;
esac
