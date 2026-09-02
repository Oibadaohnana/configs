#!/usr/bin/env bash

if [[ -z $HOME ]]; then
    echo "Environment variable HOME not set."
    exit 2
fi

CONFIG=$HOME/nixcfg

function make_symlink {
    target="$CONFIG/$1"
    name="$HOME/$2"
    mkdir -p $(dirname "$name")
    if [[ -L "$name" ]]; then
        if [[ $(readlink -f "$name") != $target ]]; then
            echo "Deleting previously existing symlink: $target"
            rm $name
            ln -s "$target" "$name"
        fi
    elif [[ ! -a "$name" ]]; then
        echo "$target\t\t -> $name"
        ln -s "$target" "$name"
    else
        echo "File already exists: $name"
    fi
}

make_symlink configs/bashrc .bashrc
make_symlink configs/zshrc .zshrc
make_symlink configs/waybarconfig/config .config/waybar/config
make_symlink configs/waybarconfig/style.css .config/waybar/style.css
make_symlink configs/makoconfig .config/mako/config
make_symlink configs/hyprland.lua .config/hypr/hyprland.lua
make_symlink configs/hyprpaperconfig .config/hypr/hyprpaper.conf
make_symlink configs/hypridleconfig .config/hypr/hypridle.conf

# X11/i3 session -- the counterparts of the Wayland session entries above.
# Harmless while nixos/i3.nix is out of flake.nix: nothing reads them until an
# i3 session actually starts.
make_symlink configs/i3config .config/i3/config
make_symlink configs/polybarconfig/config.ini .config/polybar/config.ini
make_symlink configs/dunstrc .config/dunst/dunstrc
# Default path for a bare `picom`. i3config passes --config explicitly, so this
# only matters when starting it by hand to debug.
make_symlink configs/picom.conf .config/picom.conf

make_symlink configs/kitty.conf .config/kitty/kitty.conf
make_symlink configs/mimeapps.list .config/mimeapps.list
# Names the colorscheme below. Was "simple" (16-colour, drawn from kitty.conf's
# color0-15); gruvbox-dark-hard carries its own RGB instead.
make_symlink configs/micro/settings.json .config/micro/settings.json
# Not built in -- micro ships gruvbox/gruvbox-tc, but only at medium contrast.
# Needs MICRO_TRUECOLOR=1 (configuration.nix), else micro quantises to 256.
make_symlink configs/micro/colorschemes/gruvbox-dark-hard.micro .config/micro/colorschemes/gruvbox-dark-hard.micro
# Terminal-style line editing, mirroring the zsh bindings above. Only the keys
# micro gets wrong are listed: Ctrl+Left/Right (word motion) and Ctrl+W
# (delete word back, which kitty sends for ctrl+backspace) already match.
# JSON allows no comments, hence the explanation living here.
make_symlink configs/micro/bindings.json .config/micro/bindings.json
# Down/Up walk search matches while a search is live, which micro cannot do on
# its own. bindings.json chains "lua:searchnav.down|CursorDown", so the keys go
# dead without this plugin.
make_symlink configs/micro/plug/searchnav .config/micro/plug/searchnav
# Ctrl+B / Ctrl+U wrap the selection -- or the word under the cursor -- in
# **bold** / <u>underline</u>, and strip them again on a second press. Ctrl+U
# no longer deletes to the start of the line.
make_symlink configs/micro/plug/emphasis .config/micro/plug/emphasis
# What renders those markers: micro's own markdown rules with **strong** split
# off into a bold colour group, plus the .txt rules micro ships no syntax for.
# A whole copy is needed -- micro replaces a syntax file rather than merging.
make_symlink configs/micro/syntax .config/micro/syntax
# Shadows the micro.desktop from pkgs.micro -- same desktop-file ID, and
# XDG_DATA_HOME beats XDG_DATA_DIRS, so Dolphin resolves this one and still
# shows a single "Micro" entry in Open With. mimeapps.list names it as the
# default for text/* so a double-click lands here. See the file for why it
# spells out kitty instead of using Terminal=true.
make_symlink configs/micro/micro.desktop .local/share/applications/micro.desktop

# Not a symlink either: KDE keeps its own index of every .desktop file it knows
# in ~/.cache/ksycoca6*, and micro.desktop above is invisible to Dolphin until
# that index is rebuilt. Deleting rather than rebuilding in place, because
# KSycoca treats an existing cache as valid even when it holds zero applications
# and never repairs itself -- so a cache built before
# /etc/xdg/menus/applications.menu was installed (see configuration.nix) would
# otherwise stay broken forever.
if command -v kbuildsycoca6 >/dev/null; then
    rm -f "$HOME"/.cache/ksycoca6*
    kbuildsycoca6 >/dev/null 2>&1
fi

# Not a symlink: blueman stores plugin state in dconf, so no file in this repo
# can stand in for it. The "!" prefix is blueman's disable marker -- killing
# StatusIcon drops the duplicate bluetooth tray icon (the waybar bluetooth
# module already shows it) while leaving the applet's pairing prompts and
# auto-connect alone.
if command -v dconf >/dev/null; then
    dconf write /org/blueman/general/plugin-list "['!StatusIcon']"
fi

