#!/usr/bin/env bash

# Directory containing wallpapers
WALLPAPER_DIR="/home/benji/Pictures/Wallpapers"

# Function to set wallpaper using swaymsg
set_wallpaper() {
    echo "Looking for wallpapers in: $WALLPAPER_DIR"
    wallpaper=$(find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | shuf -n 1)
    echo "Selected wallpaper: $wallpaper"

    if [ -n "$wallpaper" ]; then
        swaymsg output "*" background "$wallpaper" fill
        echo "✅ Wallpaper set successfully!"
    else
        echo "❌ No wallpapers found!"
    fi
}

# Run immediately
set_wallpaper

# Optional: add cron job for daily change (not typical on NixOS)
# Instead, use systemd user timer or swayidle hook
# (crontab -l 2>/dev/null; echo "0 7 * * * $(readlink -f "$0")") | crontab -
