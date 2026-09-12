#!/usr/bin/env bash

# Clickable desktop tiles for waybar -- one custom module per desktop.
#
# waybar's own hyprland/workspaces hardcodes "dispatch workspace N" over IPC,
# which the Lua config parser rejects as a syntax error, so its buttons can
# never switch here. ext/workspaces clicks fine but has no {windows}, losing
# the app icons -- hence rebuilding the tiles, and their icon table, here.
#
# Usage:
#   hypr_workspaces.sh waybar <n>   JSON for the custom/wsN module
#   hypr_workspaces.sh focus <n>    switch to desktop n
#   hypr_workspaces.sh list         one line per desktop: n state icons
#   hypr_workspaces.sh poke         redraw the tiles

set -euo pipefail

# Must match "signal" on the custom/ws* modules in waybarconfig/config and the
# pkill in the event hooks in hyprland.lua.
WAYBAR_SIGNAL=11

# Tiles to draw. Matches the Meta+1..0 binds in hyprland.lua.
WORKSPACES=10

# Nerd Font glyphs as \u escapes, never literals: private-use codepoints are
# invisible in most editors and trivial to mangle on a save. Was
# "window-rewrite" in waybarconfig/config.
ICON_DEFAULT=$'\uF2D0'           # nf-fa-window_maximize
ICON_FIREFOX=$'\uF269'           # nf-fa-firefox
ICON_TERMINAL=$'\uF120'          # nf-fa-terminal
ICON_CODE=$'\uF121'              # nf-fa-code
ICON_DISCORD=$'\U000F066F'       # nf-md-discord
ICON_FILES=$'\uF07C'             # nf-fa-folder_open
ICON_BLENDER=$'\uF1B2'           # nf-fa-cube
ICON_OBS=$'\uF03D'               # nf-fa-video_camera
ICON_REAPER=$'\uF001'            # nf-fa-music
ICON_MUMBLE=$'\uF130'            # nf-fa-microphone
ICON_MIXER=$'\uF028'             # nf-fa-volume_up
ICON_BLUETOOTH=$'\uF293'         # nf-fa-bluetooth
ICON_STEAM=$'\uF1B6'             # nf-fa-steam
ICON_OFFICE=$'\uF15C'            # nf-fa-file_text
ICON_PDF=$'\uF1C1'               # nf-fa-file_pdf_o
ICON_IMAGE=$'\uF03E'             # nf-fa-picture_o
ICON_VIDEO=$'\uF008'             # nf-fa-film

# Class -> glyph. Globs, not the regexes waybar used; these patterns agree.
icon_for() {
    case "$1" in
        firefox)                    printf '%s' "$ICON_FIREFOX" ;;
        kitty)                      printf '%s' "$ICON_TERMINAL" ;;
        code)                       printf '%s' "$ICON_CODE" ;;
        discord)                    printf '%s' "$ICON_DISCORD" ;;
        org.kde.dolphin)            printf '%s' "$ICON_FILES" ;;
        blender)                    printf '%s' "$ICON_BLENDER" ;;
        com.obsproject.Studio)      printf '%s' "$ICON_OBS" ;;
        REAPER)                     printf '%s' "$ICON_REAPER" ;;
        mumble)                     printf '%s' "$ICON_MUMBLE" ;;
        pavucontrol)                printf '%s' "$ICON_MIXER" ;;
        .blueman-manager-wrapped)   printf '%s' "$ICON_BLUETOOTH" ;;
        steam|steam_app_*)          printf '%s' "$ICON_STEAM" ;;
        libreoffice*)               printf '%s' "$ICON_OFFICE" ;;
        org.pwmt.zathura)           printf '%s' "$ICON_PDF" ;;
        imv)                        printf '%s' "$ICON_IMAGE" ;;
        mpv)                        printf '%s' "$ICON_VIDEO" ;;
        *)                          printf '%s' "$ICON_DEFAULT" ;;
    esac
}

# "<ws-id> <class>" per mapped window, in hyprctl's order (= creation order).
# Scratchpad windows come back with a negative id and so match no tile.
client_classes() {
    hyprctl clients | awk '
        function flush() {
            if (ws != "" && cls != "" && mapped == 1) print ws, cls
        }
        /^Window /              { flush(); ws = ""; cls = ""; mapped = 0; next }
        /^[ \t]+mapped: /       { mapped = $2; next }
        /^[ \t]+workspace: /    { ws = $2; next }
        /^[ \t]+class: /        { cls = $2; next }
        END { flush() }
    '
}

# "<ws-id> active|visible" -- active is on the focused output, visible is the
# same workspace shown on any other one.
monitor_states() {
    hyprctl monitors | awk '
        /^[ \t]+active workspace: / { ws = $3; next }
        /^[ \t]+focused: /          { print ws, ($2 == "yes" ? "active" : "visible") }
    '
}

# n <TAB> state <TAB> icons; state is active, visible or empty (occupied only).
# Unoccupied and unwatched desktops print nothing -- that is what hides them.
cmd_list() {
    local states clients
    states=$(monitor_states)
    clients=$(client_classes)

    local n state icons cls
    for ((n = 1; n <= WORKSPACES; n++)); do
        state=$(awk -v n="$n" '$1 == n { print $2; exit }' <<<"$states")
        icons=""
        while read -r _ cls; do
            [ -n "$cls" ] || continue
            icons="$icons $(icon_for "$cls")"
        done < <(awk -v n="$n" '$1 == n' <<<"$clients")

        [ -n "$state" ] || [ -n "$icons" ] || continue
        printf '%s\t%s\t%s\n' "$n" "$state" "${icons# }"
    done
}

cmd_waybar() {
    local n=$1 line state icons classes
    # No awk `exit`: quitting early SIGPIPEs cmd_list, and pipefail takes the
    # whole run down with it.
    line=$(cmd_list | awk -v n="$n" -F'\t' '$1 == n')

    # Empty text takes the module off the bar.
    if [ -z "$line" ]; then
        printf '{"text":""}\n'
        return
    fi

    state=$(cut -f2 <<<"$line")
    icons=$(cut -f3 <<<"$line")

    # "ws" on every tile so the stylesheet can reach all ten at once.
    # if, not &&: a false test is the line's exit status, and set -e reads it.
    classes="\"ws\""
    if [ -n "$state" ]; then classes="$classes,\"$state\""; fi

    printf '{"text":"%s","class":[%s],"tooltip":"Desktop %s"}\n' \
        "$n${icons:+ $icons}" "$classes" "$n"
}

# Named the way hyprland.lua names it -- "workspace n" is not valid Lua.
cmd_focus() {
    hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null
}

case "${1:-}" in
    waybar) cmd_waybar "${2:?workspace number required}" ;;
    focus)  cmd_focus  "${2:?workspace number required}" ;;
    list)   cmd_list ;;
    poke)   pkill -RTMIN+$WAYBAR_SIGNAL waybar || true ;;
    *)      sed -n '3,14p' "$0" >&2; exit 1 ;;
esac
