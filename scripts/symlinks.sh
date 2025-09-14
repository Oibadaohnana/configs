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

make_symlink configs/configs/bashrc .bashrc
make_symlink configs/configs/swayconfig .config/sway/config
