#!/usr/bin/env bash
set -euo pipefail

# Get output names (works without jq)
outputs=$(swaymsg -t get_outputs | sed -n 's/.*"name": "\([^"]*\)".*/\1/p' | uniq)

if [ -z "$outputs" ]; then
  echo "No outputs found (are you running under sway?)"
  exit 1
fi

for out in $outputs; do
  echo "Attempting to set $out -> 1920x1080@180"
  # Try the common mode command first
  if swaymsg output "$out" mode 1920x1080@180 >/dev/null 2>&1; then
    echo "Success: $out set to 1920x1080@180 (mode)"
    continue
  fi

  # Fallback: try custom resolution if mode failed
  if swaymsg -- output "$out" resolution --custom 1920 1080 >/dev/null 2>&1; then
    echo "Success: $out set to 1920x1080 (custom resolution)"
  else
    echo "Failed to set resolution for $out. Check available modes with: swaymsg -t get_outputs"
  fi
done
