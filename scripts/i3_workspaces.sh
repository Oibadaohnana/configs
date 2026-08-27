#!/usr/bin/env bash

# polybar's workspace tile, standing in for waybar's "hyprland/workspaces" with
# format "{id} {windows}" and the window-rewrite icon map.
#
# Why a script and not a module: polybar's internal/i3 can print a workspace
# name and nothing else. It has no notion of the windows *on* a workspace, so
# the per-window icons -- the whole point of waybar's window-rewrite -- cannot
# be expressed in the config at all.
#
# Output is one line per update, for a `tail = true` custom/script module.
# %{A1:...:} wraps each workspace in a click action and %{B}/%{F} colour it,
# which is how polybar spells what style.css did with CSS classes.
#
# It re-renders on i3 events rather than on a timer, so it is as prompt as
# waybar's was.

set -euo pipefail

# style.css #workspaces button, class for class.
BG_ACTIVE="#64727D"    # button.active   -- focused
BG_VISIBLE="#23292e"   # button.visible  -- on another output, not focused
BG_OCCUPIED="#3a3a3a"  # button:not(.active):not(.visible)
BG_URGENT="#eb4d4b"    # button.urgent
FG="#ffffff"

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
#
# The keys are X11 WM_CLASS values, which are NOT the Wayland app_ids the
# waybar map used -- the glyphs are the same, the names they hang off are not.
# Dolphin reports "dolphin" here and "org.kde.dolphin" there; VS Code "Code"
# rather than "code"; zathura "Zathura" rather than "org.pwmt.zathura". The
# match below is case-insensitive so only the genuinely different names had to
# be rewritten. To check one: xprop WM_CLASS, then click the window.
icon_for_class() {
    shopt -s nocasematch
    case "$1" in
        firefox*)                   printf '%s' $'\uf269' ;;
        kitty)                      printf '%s' $'\uf120' ;;
        code)                       printf '%s' $'\uf121' ;;
        discord)                    printf '%s' $'\U000f066f' ;;
        dolphin|org.kde.dolphin)    printf '%s' $'\uf07c' ;;
        blender)                    printf '%s' $'\uf1b2' ;;
        obs|com.obsproject.Studio)  printf '%s' $'\uf03d' ;;
        reaper)                     printf '%s' $'\uf001' ;;
        mumble)                     printf '%s' $'\uf130' ;;
        pavucontrol)                printf '%s' $'\uf028' ;;
        .blueman-manager-wrapped|blueman-manager) printf '%s' $'\uf293' ;;
        steam_app_*)                printf '%s' $'\uf1b6' ;;
        steam)                      printf '%s' $'\uf1b6' ;;
        libreoffice*)               printf '%s' $'\uf15c' ;;
        zathura|org.pwmt.zathura)   printf '%s' $'\uf1c1' ;;
        imv)                        printf '%s' $'\uf03e' ;;
        mpv)                        printf '%s' $'\uf008' ;;
        # waybar's window-rewrite-default
        *)                          printf '%s' $'\uf2d0' ;;
    esac
}

render() {
    local -A classes=()
    local name cls num focused visible urgent bg icons out=""

    # Every window's WM_CLASS, grouped under the workspace it sits on. One
    # get_tree call for the lot; a call per workspace would mean re-walking the
    # whole tree once per row.
    while IFS=$'\t' read -r name cls; do
        [[ -n $name ]] || continue
        classes["$name"]+="$cls "
    done < <(
        i3-msg -t get_tree | jq -r '
            def leaves: recurse(.nodes[]?, .floating_nodes[]?)
                        | select(.nodes == [] and .floating_nodes == []);
            recurse(.nodes[]?, .floating_nodes[]?)
            | select(.type == "workspace")
            | .name as $ws
            | [ leaves | select(.window != null) ]
            | .[]
            | [$ws, (.window_properties.class // "")] | @tsv
        '
    )

    # get_workspaces rather than the tree, because focused/visible/urgent are
    # only reported there. i3 discards a workspace as soon as its last window
    # closes, so this list is already "occupied plus the focused one" -- the
    # same set waybar showed after its persistent-workspaces were removed.
    while IFS=$'\t' read -r num name focused visible urgent; do
        if   [[ $urgent  == true ]]; then bg=$BG_URGENT
        elif [[ $focused == true ]]; then bg=$BG_ACTIVE
        elif [[ $visible == true ]]; then bg=$BG_VISIBLE
        else                              bg=$BG_OCCUPIED
        fi

        icons=""
        for cls in ${classes["$name"]:-}; do
            icons+="$(icon_for_class "$cls") "
        done

        # style.css gave the buttons "padding: 0 8px"; polybar has no padding
        # inside a script module's output, so it is spaces.
        out+="%{A1:i3-msg -t command workspace number ${num}:}%{B${bg}}%{F${FG}}  ${num} ${icons}%{F-}%{B-}%{A} "
    done < <(
        i3-msg -t get_workspaces |
            jq -r '.[] | [.num, .name, .focused, .visible, .urgent] | @tsv'
    )

    printf '%s\n' "${out% }"
}

render

# -m keeps i3-msg running and prints one JSON object per event. "window" is
# needed as well as "workspace": opening or closing a window changes the icon
# row without the workspace itself changing at all.
i3-msg -t subscribe -m '[ "workspace", "window" ]' | while read -r _; do
    render
done
