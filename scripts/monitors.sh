#!/usr/bin/env bash

# Turns individual monitors on and off from a rofi list, pins which of them
# sits at each end of the row, and feeds waybar a tile showing how many are
# currently active.
#
# Why not `hyprctl keyword monitor ...`: under the Lua config parser that
# command is refused outright ("keyword can't work with non-legacy parsers"),
# so every change here goes through `hyprctl eval` calling hl.monitor() --
# the same call hyprland.lua itself uses.
#
# Persistence: Hyprland has no memory of a switched-off output, and the
# wildcard monitor rule in hyprland.lua re-enables anything it sees. So both
# the switched-off outputs and the end-of-row pins are written to state files
# that hyprland.lua reads back when it loads, and that cmd_hotplug re-applies
# while the session is still starting up and its outputs are still arriving.
# Those files live outside the nixcfg repo on purpose -- they are per-machine
# state, and the desktop and the framework have different output names.
#
# A display appearing or vanishing overrides all of that: `hotplug` switches
# every connected output back on and empties the off-list. Carrying an off-list
# across a change of desk is how a session ends up with no screen at all --
# unplug the external from a laptop whose panel is switched off and there is
# nothing left to switch the panel back on with.
#
# Pinning an end also settles where the screens sit: with nothing pinned, the
# `position = "auto"` wildcard rule in hyprland.lua places each output to the
# right of whatever is already on, so switching one off and back on can leave
# the row in a different order than it started. Pin an end and this script
# lays the whole row out explicitly instead, and that order then holds.
#
# Overlaps: Hyprland will happily stack two outputs on the same coordinates and
# says nothing about it -- no log line, no warning -- so an overlap, once made,
# just stays until something notices. cmd_layout therefore never lets one exist
# even for an instant (see the two passes there), and repairs one it finds.
#
# Usage:
#   monitors.sh waybar          JSON for the custom/monitors module
#   monitors.sh menu            turn displays on/off and pin their order
#   monitors.sh toggle <name>   flip one output on/off
#   monitors.sh on <name>       turn one output on
#   monitors.sh off <name>      turn one output off
#   monitors.sh left <name>     pin one output to the left end (again = unpin)
#   monitors.sh right <name>    pin one output to the right end (again = unpin)
#   monitors.sh layout          re-pack the row, and repair any overlap
#   monitors.sh overlap         print "yes" if any two outputs overlap
#   monitors.sh apply           re-apply the saved on/off state
#   monitors.sh all             switch every connected display on
#   monitors.sh rescue          switch everything on if nothing is on
#   monitors.sh hotplug         answer a display appearing or vanishing
#   monitors.sh list            one line per output, tab separated:
#                               name desc disabled mode scale width height x y

set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/disabled-monitors"
SIDES_FILE="$STATE_DIR/monitor-sides"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Both per-session, hence XDG_RUNTIME_DIR: it is emptied at logout, so a fresh
# session starts with no memory of the last one's screens.
#   SEEN_FILE     the connected outputs as of the last hotplug, for telling a
#                 real plug/unplug apart from this script's own switching.
#   SESSION_FILE  created at the first monitor event; its age is how long this
#                 session has been up (see cmd_hotplug).
SEEN_FILE="$RUNTIME_DIR/monitors-seen"
SESSION_FILE="$RUNTIME_DIR/monitors-session"

# How long after the first monitor event a session still counts as starting up.
# Outputs arrive one at a time then, so the connected set changes on its own
# with nothing plugged in.
SETTLE_SECONDS=10

# Must match "signal" in the custom/monitors module in waybarconfig/config.
WAYBAR_SIGNAL=8

# Where outputs are stashed while the row is being rearranged. Far enough down
# that a parked output cannot touch the row being built at y=0, whatever the
# screens are.
PARK_Y=100000

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
ICON_DISPLAY=$'\uf108'   # nf-fa-desktop
ICON_LAPTOP=$'\uf109'    # nf-fa-laptop

# One line per monitor, tab separated, in hyprctl's own order:
#   name  description  disabled  mode  scale  width  height  x  y
#
# The "all" is what makes this work at all: without it hyprctl omits disabled
# outputs entirely, so anything switched off would disappear from the menu and
# could never be switched back on.
#
# width/height are *logical* -- pixels divided by the scale, which is the unit
# positions are expressed in and therefore the unit overlaps have to be judged
# in. Computed in awk because the scale is often fractional and the rest of
# this script is integer-only shell arithmetic.
monitor_list() {
    hyprctl monitors all | awk '
        function flush(   t) {
            if (name == "") return
            lw = (scale > 0) ? int(pw / scale + 0.5) : pw
            lh = (scale > 0) ? int(ph / scale + 0.5) : ph
            # Transforms 1/3/5/7 are the 90 and 270 degree rotations: a
            # portrait monitor occupies its height horizontally, not its width.
            if (tr % 2 == 1) { t = lw; lw = lh; lh = t }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                name, (desc == "" ? name : desc), dis, mode, scale, lw, lh, px, py
        }
        /^Monitor / {
            flush()
            name = $2; desc = ""; dis = "false"; mode = ""
            scale = 1; tr = 0; pw = 0; ph = 0; px = 0; py = 0
            # Hyprland conjures a headless output when the last real one goes
            # away. Nothing is on it and nothing can be plugged into it, so
            # counting it as a display would hide exactly the situation
            # cmd_rescue exists to get out of. Blanking the name drops it:
            # flush() ignores a nameless record.
            if (name ~ /^(HEADLESS|FALLBACK)/) name = ""
            next
        }
        # The current mode and origin, e.g. "\t2560x1440@143.99001 at 0x0".
        # Anchored on a leading digit so "availableModes:" cannot match it.
        /^[ \t]+[0-9]+x[0-9]+@/ {
            if (mode == "") {
                split($1, m, "@");  mode = m[1]
                split(mode, wh, "x"); pw = wh[1]; ph = wh[2]
                split($3, p, "x");    px = p[1];  py = p[2]
            }
            next
        }
        /^[ \t]+description: / { sub(/^[ \t]+description: /, ""); desc = $0; next }
        /^[ \t]+disabled: /    { dis = $2; next }
        /^[ \t]+scale: /       { scale = $2; next }
        /^[ \t]+transform: /   { tr = $2; next }
        END { flush() }
    '
}

# "yes" if any two enabled outputs share screen area. Two rectangles miss each
# other when one ends before the other starts on either axis, so they intersect
# only when neither axis separates them.
has_overlap() {
    monitor_list | awk -F'\t' '
        $3 == "false" { n++; x[n] = $8; y[n] = $9; w[n] = $6; h[n] = $7 }
        END {
            for (i = 1; i <= n; i++)
                for (j = i + 1; j <= n; j++)
                    if (x[i] < x[j] + w[j] && x[j] < x[i] + w[i] &&
                        y[i] < y[j] + h[j] && y[j] < y[i] + h[i]) { print "yes"; exit }
        }
    '
}

# The x coordinate just past the right-hand end of every enabled output, i.e. a
# spot guaranteed to be clear of all of them.
rightmost_edge() {
    monitor_list | awk -F'\t' '
        $3 == "false" { e = $8 + $6; if (e > max) max = e }
        END { print (max > 0) ? max : 0 }
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

# Nothing is off any more. Called by cmd_all, because the off-list is the one
# thing that would switch these straight back off at the next monitor event.
saved_clear() {
    [[ -f $STATE_FILE ]] || return 0
    : >"$STATE_FILE"
}

# ---------------------------------------------------------------------------
# End-of-row pins: name<TAB>left or name<TAB>right, at most two lines.
# ---------------------------------------------------------------------------

side_of() {
    local target=$1 name side
    [[ -f $SIDES_FILE ]] || return 0
    while IFS=$'\t' read -r name side; do
        if [[ $name == "$target" ]]; then printf '%s' "$side"; return 0; fi
    done <"$SIDES_FILE"
}

# Pinning is exclusive both ways: an end belongs to one output, and an output
# sits at one end. So setting a pin drops whoever held that end before, and
# drops any other end this output was holding. Rewriting the file wholesale is
# simpler than editing in place, and it is never more than two lines long.
# An empty $2 just clears the pin.
side_set() {
    local target=$1 want=$2 name side
    mkdir -p "$STATE_DIR"
    : >"$SIDES_FILE.tmp"
    if [[ -f $SIDES_FILE ]]; then
        while IFS=$'\t' read -r name side; do
            [[ -n $name ]] || continue
            if [[ $side == "$want" || $name == "$target" ]]; then continue; fi
            printf '%s\t%s\n' "$name" "$side" >>"$SIDES_FILE.tmp"
        done <"$SIDES_FILE"
    fi
    if [[ -n $want ]]; then printf '%s\t%s\n' "$target" "$want" >>"$SIDES_FILE.tmp"; fi
    mv "$SIDES_FILE.tmp" "$SIDES_FILE"
}

# Lay the enabled outputs out in one row, left to right, edge to edge with
# their tops aligned, so the cursor and windows cross between them without
# falling into a gap or an overlap.
#
# Runs when an end has been pinned, and also whenever the outputs are actually
# overlapping -- so a bad arrangement gets repaired even when nothing is
# pinned. Otherwise it stays out of the way and positions remain whatever
# hyprland.lua says, which on the desktop means the explicit DP-3 rule; a
# script nobody asked to take charge should not quietly override that.
cmd_layout() {
    if [[ ! -s $SIDES_FILE && -z $(has_overlap) ]]; then return 0; fi

    local name desc dis mode scale lw lh px py
    local left="" middle="" right=""

    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        [[ $dis == false ]] || continue
        case "$(side_of "$name")" in
            left)  left+="$name $lw $lh"$'\n' ;;
            right) right+="$name $lw $lh"$'\n' ;;
            *)     middle+="$name $lw $lh"$'\n' ;;
        esac
    done < <(monitor_list)

    local ordered
    ordered=$(printf '%s%s%s' "$left" "$middle" "$right")
    [[ -n $ordered ]] || return 0

    # Two passes, both inside a single eval.
    #
    # Moving each output straight to its new place can put two of them on the
    # same coordinates part-way through: two displays swapping ends is the
    # plain case, where whichever moves first lands squarely on the other. That
    # window is brief, but Hyprland neither refuses nor reports an overlap, so
    # anything sampling the layout at that moment -- wdisplays, a client
    # reacting to the output change -- sees a genuinely broken arrangement, and
    # if the second pass never lands it stays broken.
    #
    # So the row is first parked well below the screen in a vertical stack.
    # Stacked by height it cannot overlap itself, and at y=100000 it cannot
    # reach the row being rebuilt at y=0. Every output is therefore out of the
    # way before any of them is put down, and no intermediate state overlaps.
    local lua="" y=$PARK_Y
    while read -r name lw lh; do
        [[ -n $name ]] || continue
        lua+="hl.monitor({ output = \"$name\", position = \"0x${y}\" }) "
        y=$((y + lh))
    done <<<"$ordered"

    local x=0
    while read -r name lw lh; do
        [[ -n $name ]] || continue
        lua+="hl.monitor({ output = \"$name\", position = \"${x}x0\" }) "
        x=$((x + lw))
    done <<<"$ordered"

    hyprctl eval "$lua" >/dev/null

    # Hyprland stays silent about a bad layout, so check rather than assume.
    sleep 0.3
    if [[ -n $(has_overlap) ]]; then
        notify "Displays overlap" "Could not arrange them cleanly -- try wdisplays."
    fi
    return 0
}

# waybar only re-runs this script every "interval" seconds; the signal makes a
# change land on the bar at once instead of on the next poll.
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
    local name desc dis mode scale lw lh px py n=0
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        if [[ $dis == false ]]; then n=$((n + 1)); fi
    done < <(monitor_list)
    printf '%s' "$n"
}

describe() {
    local target=$1 name desc dis mode scale lw lh px py
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        if [[ $name == "$target" ]]; then printf '%s' "$desc"; return 0; fi
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

    if [[ $disabled == true ]]; then
        saved_add "$name"
        hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })" >/dev/null
    else
        saved_remove "$name"
        # Hyprland brings an output back at the coordinates it last held, and by
        # now something else may be sitting there: the row shuffles left every
        # time a display is switched off, so the place this one used to occupy
        # is often taken. It would then sit exactly on top of another display
        # until the re-layout below catches up -- close to a second, which is
        # long enough for anything inspecting the layout to see a broken one.
        # Switching it on *at* a free spot, in the same call, closes that
        # window; cmd_layout then moves it where the pins actually want it.
        hyprctl eval "hl.monitor({ output = \"$name\", disabled = false, position = \"$(rightmost_edge)x0\" })" >/dev/null
    fi

    if [[ $disabled == true ]]; then
        notify "$(icon_for "$name") Display off" "$(describe "$name")"
    else
        notify "$(icon_for "$name") Display on" "$(describe "$name")"
    fi

    # Hyprland reports the new state a moment later, and the row has to be
    # rebuilt around whichever outputs are left -- an output it auto-places on
    # the way back in can land on top of another. monitor.removed does not fire
    # for a disable, so this has to happen here rather than on an event.
    sleep 0.3
    cmd_layout
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

# Switch on every connected output, whatever the off-list says, and empty the
# off-list: after this nothing is meant to be off.
#
# Each one is enabled past the right-hand end of everything already on, and the
# widths accumulate, so no two land on the same spot even for the instant
# before cmd_layout re-packs the row. hyprctl reports the last known mode of a
# switched-off output, which is the one it comes back at, so those widths are
# the real ones; the fallback is only for an output that has never been on.
cmd_all() {
    local name desc dis mode scale lw lh px py
    local lua="" turned="" x
    x=$(rightmost_edge)

    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        [[ $dis == true ]] || continue
        valid_name "$name" || continue
        (( lw > 0 )) || lw=1920
        lua+="hl.monitor({ output = \"$name\", disabled = false, position = \"${x}x0\" }) "
        x=$((x + lw))
        turned+="$(icon_for "$name") $desc"$'\n'
    done < <(monitor_list)

    saved_clear

    [[ -n $lua ]] || return 0
    hyprctl eval "$lua" >/dev/null
    notify "$ICON_DISPLAY All displays on" "${turned%$'\n'}"

    # Hyprland reports the new state a moment later, and the row has to be
    # rebuilt around the outputs that just joined it.
    sleep 0.3
    cmd_layout
    refresh_waybar
}

# The way back out of a session with no screen. Nothing can be asked for from
# there -- no menu, no waybar tile, no keybinding whose result could be seen --
# so every path that could have been the last change ends here.
#
# Reachable without doing anything wrong: pull the external out of a laptop
# whose panel is switched off and Hyprland is left with nothing lit.
cmd_rescue() {
    (( $(enabled_count) == 0 )) || return 0
    cmd_all
}

# Answer a display appearing or vanishing.
#
# Which needs telling apart from this script's own switching, because enabling
# an output makes Hyprland fire monitor.added exactly as plugging one in does.
# Answering that by switching everything on would mean no display could ever be
# turned on by itself -- the rest of them would follow it. The set of connected
# outputs is what separates the two: a plug or an unplug changes it, switching
# one on or off does not.
#
# A session that is still starting up is the exception. Its outputs arrive one
# at a time, so the set grows on its own with nothing plugged in, and reading
# that as a hotplug would empty the off-list at every login. The saved state is
# applied instead, which is what restores it.
cmd_hotplug() {
    local now prev age
    now=$(monitor_list | cut -f1 | sort | tr '\n' ' ')
    prev=$(cat "$SEEN_FILE" 2>/dev/null || true)
    printf '%s\n' "$now" >"$SEEN_FILE"
    age=$(session_age)

    if (( age < SETTLE_SECONDS )); then
        cmd_apply
    elif [[ $now != "$prev" ]]; then
        cmd_all
    else
        cmd_layout
    fi

    cmd_rescue
    refresh_waybar
}

# Seconds since the first monitor event of this session, and 0 on the event
# that creates the marker.
session_age() {
    if [[ ! -f $SESSION_FILE ]]; then
        : >"$SESSION_FILE"
        printf '0'
        return 0
    fi
    printf '%s' "$(( $(date +%s) - $(stat -c %Y "$SESSION_FILE") ))"
}

cmd_toggle() {
    local target=$1 name desc dis mode scale lw lh px py state=""
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        if [[ $name == "$target" ]]; then state=$dis; break; fi
    done < <(monitor_list)

    if [[ -z $state ]]; then
        notify "No such display" "$target is not connected."
        return 1
    fi

    if [[ $state == false ]]; then turn_off "$target"; else set_monitor "$target" false; fi
}

# Ticking the end an output already holds unpins it, so the same row toggles
# both ways -- the same way the on/off row does.
cmd_side() {
    local name=$1 want=$2
    valid_name "$name" || { echo "Refusing odd output name: $name" >&2; return 1; }

    if [[ "$(side_of "$name")" == "$want" ]]; then
        side_set "$name" ""
        notify "$(icon_for "$name") Unpinned" "$(describe "$name")"
    else
        side_set "$name" "$want"
        notify "$(icon_for "$name") Pinned $want" "$(describe "$name")"
    fi
    cmd_layout
    refresh_waybar
}

# Three rows per display: the display itself, and one for each end of the row
# it can be pinned to. Stays open after each pick so several can be changed in
# one go; Esc closes it. rofi exits non-zero on Esc, hence the `|| return 0`.
cmd_menu() {
    local -a rows=() actions=()
    local name desc dis mode scale lw lh px py side marker choice i menu act arg1 arg2

    while :; do
        rows=(); actions=()
        while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
            [[ $dis == false ]] && marker="●" || marker="○"
            rows+=("$marker $(icon_for "$name")  $desc ($name)  $mode")
            actions+=("toggle $name")

            side=$(side_of "$name")
            [[ $side == left ]] && marker="●" || marker="○"
            rows+=("      $marker  leftmost")
            actions+=("side $name left")

            [[ $side == right ]] && marker="●" || marker="○"
            rows+=("      $marker  rightmost")
            actions+=("side $name right")
        done < <(monitor_list)
        (( ${#rows[@]} )) || return 0

        menu=""
        for i in "${!rows[@]}"; do menu+="${rows[i]}"$'\n'; done

        # -format i returns the row index, so two identical panels stay
        # distinguishable, and the index maps straight onto the action list.
        choice=$(printf '%s' "$menu" | rofi -dmenu -i -p "Displays" -format i \
            -mesg "Enter toggles a row, Esc when done") || return 0
        [[ -n $choice ]] || return 0

        read -r act arg1 arg2 <<<"${actions[choice]}"
        case "$act" in
            toggle) cmd_toggle "$arg1" || true ;;
            side)   cmd_side "$arg1" "$arg2" || true ;;
        esac
        # Hyprland needs a moment before hyprctl reports the new state.
        sleep 0.4
    done
}

cmd_waybar() {
    local name desc dis mode scale lw lh px py
    local total=0 active=0 tooltip="" marker text class pin
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        total=$((total + 1))
        if [[ $dis == false ]]; then
            active=$((active + 1)); marker="● "
        else
            marker="○ "
        fi
        case "$(side_of "$name")" in
            left)  pin=" [left]" ;;
            right) pin=" [right]" ;;
            *)     pin="" ;;
        esac
        tooltip+="$marker$(json_escape "$desc") ($(json_escape "$name")) $mode$pin\\n"
    done < <(monitor_list)

    (( total )) || { printf '{"text":"","tooltip":"No displays"}\n'; return 0; }

    # The count only says anything when there is more than one display to
    # count, so a single-panel laptop just gets the icon.
    if (( total > 1 )); then text="$ICON_DISPLAY $active"; else text="$ICON_DISPLAY"; fi
    if (( active < total )); then class="partial"; else class="all"; fi

    tooltip="Displays: $active of $total active\\n\\n${tooltip%\\n}"
    if [[ -n $(has_overlap) ]]; then tooltip+="\\n\\nWarning: displays overlap"; fi

    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "$(json_escape "$text")" "$tooltip" "$class"
}

# "true", "false" or empty for an output that is not connected.
state_of() {
    local target=$1 name desc dis mode scale lw lh px py
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        if [[ $name == "$target" ]]; then printf '%s' "$dis"; return 0; fi
    done < <(monitor_list)
    printf ''
}

# Put the off-list back into effect: what cmd_hotplug does while a session is
# starting up, and what to run by hand after something has switched everything
# on. The last-display guard in turn_off still applies, so a stale off-list can
# never black out the session, and cmd_rescue catches it if one somehow does.
cmd_apply() {
    local name
    if [[ -f $STATE_FILE ]]; then
        while read -r name; do
            [[ -n $name && $name != \#* ]] || continue
            # Only ones that are actually on: cmd_hotplug calls this for every
            # output arriving at login, and turn_off on an already-off one
            # would fire a notification each time round.
            [[ "$(state_of "$name")" == false ]] || continue
            turn_off "$name"
        done <"$STATE_FILE"
    fi
    cmd_layout
    cmd_rescue
    refresh_waybar
}

case "${1:-}" in
    waybar)  cmd_waybar ;;
    menu)    cmd_menu ;;
    toggle)  cmd_toggle "${2:?usage: $0 toggle <output>}" ;;
    on)      set_monitor "${2:?usage: $0 on <output>}" false ;;
    off)     turn_off "${2:?usage: $0 off <output>}" ;;
    left)    cmd_side "${2:?usage: $0 left <output>}" left ;;
    right)   cmd_side "${2:?usage: $0 right <output>}" right ;;
    layout)  cmd_layout ;;
    overlap) has_overlap ;;
    apply)   cmd_apply ;;
    all)     cmd_all ;;
    rescue)  cmd_rescue ;;
    # Serialised: cmd_all's own switching fires monitor.added, so a second copy
    # of this arrives while the first is still working. Taking turns means the
    # second one reads a settled monitor list and finds nothing left to do.
    hotplug) exec 9>"$RUNTIME_DIR/monitors-hotplug.lock"
             flock -w 20 9 || exit 0
             cmd_hotplug ;;
    list)    monitor_list ;;
    *)
        echo "Usage: $0 {waybar|menu|toggle <o>|on <o>|off <o>|left <o>|right <o>|layout|overlap|apply|all|rescue|hotplug|list}" >&2
        exit 1
        ;;
esac
