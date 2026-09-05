#!/usr/bin/env bash

# X11 port of monitors.sh. Same job, same command surface, same state files:
# turns individual monitors on and off from a rofi list, pins which of them
# sits at each end of the row, and feeds the bar a tile showing how many are
# currently active.
#
# What changed from the Wayland original, and why:
#
# * hyprctl -> xrandr. Everything hyprctl did through hl.monitor() is a
#   `xrandr --output` flag here, and `xrandr --query` replaces
#   `hyprctl monitors all`. xrandr already lists disconnected and switched-off
#   outputs, so the "all" problem the original had does not arise.
#
# * Output names differ. The xf86-video-amdgpu DDX spells connectors
#   "DisplayPort-2" / "HDMI-A-0" / "eDP", not the DRM names Hyprland uses
#   ("DP-3" / "HDMI-A-1" / "eDP-1"). resolve_name() below accepts either, so a
#   binding written against the Hyprland name keeps working.
#
# * No auto-enable, and no monitor.added event. Hyprland's wildcard monitor
#   rule switched a newly plugged display on by itself and fired an event; X11
#   does neither. `watch` covers both: it polls the connected-output set and
#   switches everything on when it changes -- see cmd_all for why everything,
#   and not just the new arrival.
#
# * No per-output scale. X11 has one DPI for the whole server (see the Xft.dpi
#   line in configs/i3config), so hyprland.lua's scale = 2 on DP-3 and 1.5 on
#   eDP-1 cannot both be honoured. Modes are set here; scaling is not.
#
# Persistence works exactly as before, and deliberately reuses the same state
# directory: an output switched off is written to a file, because neither
# compositor remembers. The files live outside the nixcfg repo on purpose --
# they are per-machine state, and the desktop and the framework have different
# output names.
#
# Usage:
#   monitors_x11.sh polybar        text feed for the custom/script module
#   monitors_x11.sh waybar         JSON, for reuse of the waybar module format
#   monitors_x11.sh menu           turn displays on/off and pin their order
#   monitors_x11.sh toggle <name>  flip one output on/off
#   monitors_x11.sh on <name>      turn one output on
#   monitors_x11.sh off <name>     turn one output off
#   monitors_x11.sh left <name>    pin one output to the left end (again = unpin)
#   monitors_x11.sh right <name>   pin one output to the right end (again = unpin)
#   monitors_x11.sh layout         re-pack the row, and repair any overlap
#   monitors_x11.sh overlap        print "yes" if any two outputs overlap
#   monitors_x11.sh apply          re-apply the saved on/off state
#   monitors_x11.sh all            switch every connected display on
#   monitors_x11.sh rescue         switch everything on if nothing is on
#   monitors_x11.sh init           desktop monitor setup (hyprland.lua's rules)
#   monitors_x11.sh init-framework laptop monitor setup
#   monitors_x11.sh watch          answer a hotplug; stands in for monitor.added
#   monitors_x11.sh list           one line per output, tab separated:
#                                  name desc disabled mode scale width height x y

set -euo pipefail

# Shared with the Wayland session on purpose: the same physical displays are
# being switched off, and keeping one file means the choice survives switching
# session type as well as logging out.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/disabled-monitors"
SIDES_FILE="$STATE_DIR/monitor-sides"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# How often `watch` and the `polybar` feed re-read xrandr, in seconds. X11 has
# no hotplug event on any socket this script can reach, so both poll.
POLL_INTERVAL=2

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
ICON_DISPLAY=$'\uf108'   # nf-fa-desktop
ICON_LAPTOP=$'\uf109'    # nf-fa-laptop

# One line per connected monitor, tab separated, in xrandr's own order:
#   name  description  disabled  mode  scale  width  height  x  y
#
# Kept field-for-field identical to monitors.sh's version so the rest of this
# script reads the same. "description" is xrandr's physical size, the closest
# thing it offers to Hyprland's monitor description; "scale" is always 1,
# since X11 has no per-output scale to report.
#
# Disconnected outputs are dropped: unlike a Hyprland monitor rule, xrandr
# cannot do anything useful with one, and listing them would put dead rows in
# the menu.
monitor_list() {
    xrandr --query | awk '
        function flush() {
            if (name == "") return
            printf "%s\t%s\t%s\t%s\t1\t%s\t%s\t%s\t%s\n",
                name, (desc == "" ? name : desc), dis, mode, w, h, x, y
        }
        # e.g. "DP-3 connected primary 2560x1440+0+0 (normal ...) 597mm x 336mm"
        / connected/ {
            flush()
            name = $1; desc = ""; dis = "true"; mode = ""; w = 0; h = 0; x = 0; y = 0
            if ($2 != "connected") { name = ""; next }   # "disconnected"
            # The geometry field is the one shaped WxH+X+Y. Absent when the
            # output is connected but switched off, which is exactly how a
            # disabled monitor is recognised here.
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9-]+\+[0-9-]+$/) {
                    dis = "false"
                    split($i, g, /[x+]/)
                    w = g[1]; h = g[2]; x = g[3]; y = g[4]
                    mode = g[1] "x" g[2]
                    break
                }
            }
            # Physical size, e.g. "597mm x 336mm", as the description.
            for (i = 3; i < NF; i++)
                if ($i ~ /^[0-9]+mm$/ && $(i+1) == "x") { desc = $i " x " $(i+2); break }
            next
        }
        END { flush() }
    '
}

# The preferred mode of an output, i.e. the "+"-marked line in its mode list.
# Used when switching one back on: xrandr --auto would also do it, but only
# --mode lets the named 720p rule below override the preferred one.
preferred_mode() {
    xrandr --query | awk -v want="$1" '
        $1 == want { found = 1; next }
        found && /^[ \t]+[0-9]+x[0-9]+/ { print $1; exit }
        found && / connected/ { exit }
    '
}

# Accepts either the DRM name hyprland.lua uses ("HDMI-A-1") or the DDX name
# xrandr reports ("HDMI-A-0"), so a keybinding written for one session works in
# the other. Exact match wins; failing that, the first connected output of the
# same connector type does -- the index is not matched, because the two naming
# schemes do not agree on it (Hyprland's "DP-3" is the DDX's "DisplayPort-2").
# With several displays of one type that is a guess, so name them as xrandr
# does if it ever picks the wrong one.
resolve_name() {
    local want=$1 name rest
    while IFS=$'\t' read -r name rest; do
        [[ $name == "$want" ]] && { printf '%s' "$name"; return 0; }
    done < <(monitor_list)

    # "DP-3" and "DisplayPort-2" are the same connector family; match on the
    # leading letters only, and take the first candidate.
    local family=${want%%-*}
    case "$family" in
        DP)          family="DisplayPort" ;;
        DisplayPort) family="DP" ;;
    esac
    while IFS=$'\t' read -r name rest; do
        [[ $name == "$family"-* ]] && { printf '%s' "$name"; return 0; }
    done < <(monitor_list)

    printf '%s' "$want"
}

# "yes" if any two enabled outputs share screen area. Two rectangles miss each
# other when one ends before the other starts on either axis, so they intersect
# only when neither axis separates them.
#
# Worth keeping despite xrandr being stricter than Hyprland: xrandr will not
# refuse an overlap either, and `--same-as` deliberately creates one.
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

icon_for() {
    case "$1" in
        eDP*|LVDS-*) printf '%s' "$ICON_LAPTOP" ;;
        *)           printf '%s' "$ICON_DISPLAY" ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# Output names are passed to xrandr below, so refuse anything not shaped like
# one ("DP-2", "eDP-1", "HDMI-A-1", "DisplayPort-0").
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
# thing that would switch these straight back off at the next hotplug.
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
# `init` set.
#
# The Wayland version had to park every output far below the screen first,
# because moving them one at a time let two sit on the same coordinates
# mid-way. That is not needed here: a single `xrandr` invocation carrying every
# --output flag is applied as one atomic change, so no intermediate state is
# ever visible. The whole row therefore goes in one command.
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

    local -a args=()
    local x=0
    while read -r name lw lh; do
        [[ -n $name ]] || continue
        args+=(--output "$name" --pos "${x}x0")
        x=$((x + lw))
    done <<<"$ordered"

    xrandr "${args[@]}" || true

    # Belt and braces: xrandr reports a failed --pos on stderr and carries on
    # with the rest, so check the result rather than trust the exit code.
    if [[ -n $(has_overlap) ]]; then
        notify "Displays overlap" "Could not arrange them cleanly -- try arandr."
    fi
    return 0
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

# Switch an output on at the mode hyprland.lua would have given it, placed past
# the right-hand end of everything already on so it cannot land on top of
# another output even for an instant. cmd_layout then moves it where the pins
# actually want it.
enable_output() {
    local name=$1 mode anchor
    mode=$(named_mode "$name")
    [[ -n $mode ]] || mode=$(preferred_mode "$name")
    anchor=$(rightmost_output)

    # An empty anchor means nothing is on at all -- xrandr treats --right-of ""
    # as an error rather than a no-op, so start the row at the origin instead.
    local -a place=(--pos 0x0)
    [[ -n $anchor ]] && place=(--right-of "$anchor")

    if [[ -n $mode ]]; then
        xrandr --output "$name" --mode "$mode" "${place[@]}"
    else
        xrandr --output "$name" --auto "${place[@]}"
    fi
}

# Unlike the Hyprland version this need not write the state file before the
# call -- nothing here re-applies the saved state on an output change, so
# there is no race to lose. The order is kept anyway so the two scripts read
# alike, and so a crash between the two lines leaves the file, not the screen,
# as the odd one out.
set_monitor() {
    local name=$1 disabled=$2
    valid_name "$name" || { echo "Refusing odd output name: $name" >&2; return 1; }

    if [[ $disabled == true ]]; then
        saved_add "$name"
        xrandr --output "$name" --off
    else
        saved_remove "$name"
        enable_output "$name"
    fi

    if [[ $disabled == true ]]; then
        notify "$(icon_for "$name") Display off" "$(describe "$name")"
    else
        notify "$(icon_for "$name") Display on" "$(describe "$name")"
    fi

    cmd_layout
    return 0
}

# The name of the output whose right edge is furthest right, for --right-of.
# Empty only when nothing is on at all, which cannot happen while X is running
# -- callers still check, because an empty --right-of argument is an xrandr
# error rather than a no-op.
rightmost_output() {
    monitor_list | awk -F'\t' '
        $3 == "false" { e = $8 + $6; if (e >= max || best == "") { max = e; best = $1 } }
        END { print best }
    '
}

# The mode hyprland.lua pins for this output, if any -- currently only the
# fixed 720p on the secondary screen. Everything else gets its preferred mode,
# which is what `mode = "preferred"` in the wildcard rule meant.
named_mode() {
    case "$(resolve_name "$1")" in
        "$(resolve_name HDMI-A-1)") printf '1280x720' ;;
        *)                          printf '' ;;
    esac
}

# Refuse to switch off the last one standing: an X session with zero enabled
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
# This is what a hotplug does, in place of the enable_new/cmd_apply pair that
# used to answer one. Carrying an off-list across a change of desk is how a
# session ends up with no screen at all -- unplug the external from a laptop
# whose panel is switched off and there is nothing left to switch the panel
# back on with.
#
# Each output is placed past the right-hand end of everything already on, one
# at a time, so no two can land on the same spot; cmd_layout then re-packs the
# row the way the pins want it.
cmd_all() {
    local name desc dis mode scale lw lh px py turned=""
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        [[ $dis == true ]] || continue
        valid_name "$name" || continue
        enable_output "$name" || continue
        turned+="$(icon_for "$name") $desc"$'\n'
    done < <(monitor_list)

    saved_clear

    [[ -n $turned ]] || return 0
    notify "$ICON_DISPLAY All displays on" "${turned%$'\n'}"
    cmd_layout
}

# The way back out of a session with no screen. Nothing can be asked for from
# there -- no menu, no polybar tile, no keybinding whose result could be seen.
cmd_rescue() {
    (( $(enabled_count) == 0 )) || return 0
    cmd_all
}

cmd_toggle() {
    local target name desc dis mode scale lw lh px py state=""
    target=$(resolve_name "$1")
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
    done
}

# The tile text: the display icon, plus how many outputs are on when there is
# more than one to count.
bar_text() {
    local name desc dis mode scale lw lh px py total=0 active=0
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        total=$((total + 1))
        [[ $dis == false ]] && active=$((active + 1))
    done < <(monitor_list)

    (( total )) || return 0
    if (( total > 1 )); then printf '%s %s' "$ICON_DISPLAY" "$active"; else printf '%s' "$ICON_DISPLAY"; fi
}

# polybar script modules read plain text, one line per update, and have no
# tooltip -- so the tooltip waybar showed is dropped rather than faked.
#
# waybar polled this every 30 s and took RTMIN+8 to refresh early; polybar
# script modules take no signal, so this runs as a loop and prints only when
# the text actually changes. Same effect, one less moving part.
cmd_polybar() {
    local last="" text
    while :; do
        text=$(bar_text) || text=""
        if [[ $text != "$last" ]]; then printf '%s\n' "$text"; last=$text; fi
        sleep "$POLL_INTERVAL"
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

    if (( total > 1 )); then text="$ICON_DISPLAY $active"; else text="$ICON_DISPLAY"; fi
    if (( active < total )); then class="partial"; else class="all"; fi

    tooltip="Displays: $active of $total active\\n\\n${tooltip%\\n}"
    if [[ -n $(has_overlap) ]]; then tooltip+="\\n\\nWarning: displays overlap"; fi

    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "$(json_escape "$text")" "$tooltip" "$class"
}

# hyprland.lua applied the saved state itself when it loaded. Nothing does that
# here, so `apply` is on the critical path rather than a repair tool: `watch`
# calls it on every hotplug, and configs/i3config starts `watch` at login.
# The last-display guard is kept, so a stale state file can never black out the
# session.
cmd_apply() {
    local name
    if [[ -f $STATE_FILE ]]; then
        while read -r name; do
            [[ -n $name && $name != \#* ]] || continue
            # Only outputs that are actually on: turn_off on an already-off one
            # would fire a spurious notification on every hotplug.
            if [[ "$(state_of "$name")" == false ]]; then turn_off "$name"; fi
        done <"$STATE_FILE"
    fi
    cmd_layout
    cmd_rescue
}

state_of() {
    local target=$1 name desc dis mode scale lw lh px py
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        if [[ $name == "$target" ]]; then printf '%s' "$dis"; return 0; fi
    done < <(monitor_list)
    printf ''
}

# The wildcard monitor rule from hyprland.lua -- "any other/unlisted external
# display auto-enables at its preferred resolution whenever it's plugged in".
# xrandr has no wildcard, so this is it: switch on every connected output that
# is not in the saved-off list, then let cmd_apply/cmd_layout sort the rest.
enable_new() {
    local name desc dis mode scale lw lh px py
    while IFS=$'\t' read -r name desc dis mode scale lw lh px py; do
        [[ $dis == true ]] || continue
        saved_contains "$name" && continue
        enable_output "$name" || true
    done < <(monitor_list)
}

# The monitor block from hyprland.lua, as xrandr flags.
#
# scale is not set: X11 has one DPI for the server, handled by the Xft.dpi and
# GDK_SCALE/QT_SCALE_FACTOR settings in configs/i3config and nixos/i3.nix.
cmd_init() {
    local primary secondary
    primary=$(resolve_name DP-3)
    secondary=$(resolve_name HDMI-A-1)

    # hl.monitor DP-3: 2560x1440@180 at 0x0
    if [[ "$(state_of "$primary")" != "" ]]; then
        xrandr --output "$primary" --mode 2560x1440 --rate 180 --pos 0x0 --primary || \
        xrandr --output "$primary" --mode 2560x1440 --pos 0x0 --primary || true
    fi

    # hl.monitor HDMI-A-1: always a fixed 720p, not its native resolution.
    if [[ "$(state_of "$secondary")" != "" ]]; then
        xrandr --output "$secondary" --mode 1280x720 --rate 60 --right-of "$primary" || true
    fi

    enable_new
    cmd_apply
}

# The commented-out laptop block from hyprland.lua. eDP-1 at scale 1.5 has no
# X11 counterpart -- see the note at the top of this file.
cmd_init_framework() {
    local panel
    panel=$(resolve_name eDP-1)
    if [[ "$(state_of "$panel")" != "" ]]; then
        xrandr --output "$panel" --auto --pos 0x0 --primary || true
    fi
    enable_new
    cmd_apply
}

# Stands in for hyprland.lua's monitor.added / monitor.removed hooks. X11
# publishes RandR change events, but not on any socket a shell script can read
# without an X client of its own, so the connected-output set is polled and
# compared instead.
cmd_watch() {
    local last="" now
    while :; do
        now=$(xrandr --query | awk '/ connected/ { print $1 }' | sort | tr '\n' ' ')
        if [[ $now != "$last" && -n $last ]]; then
            cmd_all
            cmd_rescue
        fi
        last=$now
        sleep "$POLL_INTERVAL"
    done
}

case "${1:-}" in
    polybar)        cmd_polybar ;;
    waybar)         cmd_waybar ;;
    menu)           cmd_menu ;;
    toggle)         cmd_toggle "${2:?usage: $0 toggle <output>}" ;;
    on)             set_monitor "$(resolve_name "${2:?usage: $0 on <output>}")" false ;;
    off)            turn_off "$(resolve_name "${2:?usage: $0 off <output>}")" ;;
    left)           cmd_side "$(resolve_name "${2:?usage: $0 left <output>}")" left ;;
    right)          cmd_side "$(resolve_name "${2:?usage: $0 right <output>}")" right ;;
    layout)         cmd_layout ;;
    overlap)        has_overlap ;;
    apply)          cmd_apply ;;
    all)            cmd_all ;;
    rescue)         cmd_rescue ;;
    init)           cmd_init ;;
    init-framework) cmd_init_framework ;;
    watch)          cmd_watch ;;
    list)           monitor_list ;;
    *)
        echo "Usage: $0 {polybar|waybar|menu|toggle <o>|on <o>|off <o>|left <o>|right <o>|layout|overlap|apply|all|rescue|init|init-framework|watch|list}" >&2
        exit 1
        ;;
esac
