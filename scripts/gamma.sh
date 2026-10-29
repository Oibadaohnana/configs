#!/usr/bin/env bash

# Lifts the shadows on the TV so dark scenes stay readable. Real gamma curve,
# so blacks brighten while whites stay put; only external outputs, eDP stays
# normal.
#
# Usage:
#   gamma          level 1
#   gamma <1-9>    gamma 1.2, 1.4, 1.6 ... 2.8
#   gamma 0|off    back to normal
#
# Done as a Hyprland screen shader, not wlr-gamma-control: wlsunset already
# owns the gamma ramps, and a second gamma client makes Hyprland 0.56 leak a
# controller that blocks the output until relogin. The shader gets the
# monitor id as wl_output, so it can touch the TV alone.
# A config reload drops the shader; rerun gamma.

set -euo pipefail

DIR="${XDG_RUNTIME_DIR:-/tmp}/hypr-gamma"

level=${1:-1}
[[ $level == off ]] && level=0
[[ $level =~ ^[0-9]$ ]] || { echo "usage: gamma [0-9|off]" >&2; exit 1; }

shader() { hyprctl eval "hl.config({ decoration = { screen_shader = \"$1\" } })" >/dev/null; }

mkdir -p "$DIR"
rm -f "$DIR"/*.frag

if (( level == 0 )); then
    shader ""
    echo "Gamma normal."
    exit 0
fi

# Ids change on hotplug, so look them up every run.
ids=() names=()
while read -r _ name id; do
    [[ $name == eDP* ]] && continue
    ids+=("${id%):}") names+=("$name")
done < <(hyprctl monitors | awk '/^Monitor /{print $1, $2, $4}')

(( ${#ids[@]} )) || { shader ""; echo "No TV connected." >&2; exit 1; }

g=$(awk -v l="$level" 'BEGIN { printf "%.1f", 1 + l * 0.2 }')
cond=$(printf 'wl_output == %s || ' "${ids[@]}"); cond=${cond% || }

# New file name each run: the same path again would not reload.
frag="$DIR/$g-${ids[*]// /-}.frag"
cat >"$frag" <<EOF
#version 300 es
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
uniform int wl_output;
layout(location = 0) out vec4 fragColor;
void main() {
    vec4 c = texture(tex, v_texcoord);
    if ($cond) c.rgb = pow(c.rgb, vec3(1.0 / $g));
    fragColor = c;
}
EOF

shader "$frag"
echo "Gamma $g on ${names[*]}"
