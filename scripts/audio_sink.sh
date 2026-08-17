#!/usr/bin/env bash

# Switches the default audio sink, and feeds waybar an icon showing which one
# is currently active.
#
# The volume keys run volume_notify.sh, which drives @DEFAULT_SINK@ -- so
# "which device the knob controls" is exactly "which sink is the default".
# This script is the other half of that: it moves the default around.
#
# It also drags every already-playing stream to the new sink. pactl
# set-default-sink on its own only affects streams that *start* afterwards,
# which is why switching the output in pavucontrol looks like it does nothing
# to whatever is playing right now.
#
# Usage:
#   audio_sink.sh waybar        JSON feed for the custom/audiosink module
#   audio_sink.sh next          cycle to the next sink
#   audio_sink.sh menu          pick a sink from a rofi list
#   audio_sink.sh set <name>    make <name> the default sink

set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Nerd Font glyphs, written as \u escapes rather than literal characters: the
# codepoints sit in the private use area, so a literal glyph is invisible in
# most editors and trivial to mangle on a careless save. Look them up on
# nerdfonts.com/cheat-sheet.
ICON_BLUETOOTH=$'\uf025'   # nf-fa-headphones
ICON_HDMI=$'\uf108'        # nf-fa-desktop
ICON_ANALOG=$'\uf028'      # nf-fa-volume_up

# name<TAB>description, one sink per line, in pactl's own order.
sink_list() {
    pactl list sinks | awk '
        /^[ \t]*Name: / { name = $2; next }
        /^[ \t]*Description: / {
            sub(/^[ \t]*Description: /, "")
            print name "\t" $0
        }
    '
}

icon_for() {
    case "$1" in
        bluez_output.*) printf '%s' "$ICON_BLUETOOTH" ;;
        *hdmi*)         printf '%s' "$ICON_HDMI" ;;
        *)              printf '%s' "$ICON_ANALOG" ;;
    esac
}

class_for() {
    case "$1" in
        bluez_output.*) printf 'bluetooth' ;;
        *hdmi*)         printf 'hdmi' ;;
        *)              printf 'analog' ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# Resolve a sink name to its description, falling back to the raw name for a
# sink that vanished between listing and lookup.
describe() {
    local target=$1 name desc
    while IFS=$'\t' read -r name desc; do
        [[ $name == "$target" ]] && { printf '%s' "$desc"; return; }
    done < <(sink_list)
    printf '%s' "$target"
}

set_default() {
    local name=$1 id rest
    pactl set-default-sink "$name"

    # Streams pinned to another sink (by pavucontrol, or by an app that
    # remembers its last output) ignore the new default entirely, so move them
    # explicitly. A stream can disappear mid-loop; that is not an error.
    while read -r id rest; do
        [[ -n $id ]] || continue
        pactl move-sink-input "$id" "$name" 2>/dev/null || true
    done < <(pactl list sink-inputs short)

    notify_switch "$name"
}

notify_switch() {
    local name=$1 id_file="$RUNTIME_DIR/audio-sink-notify.id" prev_id new_id
    prev_id=$(cat "$id_file" 2>/dev/null || echo 0)
    new_id=$(notify-send -p -r "$prev_id" -a "audio-sink" \
        "$(icon_for "$name") Output" "$(describe "$name")")
    printf '%s\n' "$new_id" >"$id_file"
}

cmd_next() {
    local -a names=()
    local name desc current i
    while IFS=$'\t' read -r name desc; do names+=("$name"); done < <(sink_list)
    (( ${#names[@]} > 1 )) || exit 0

    current=$(pactl get-default-sink)
    for i in "${!names[@]}"; do
        if [[ ${names[i]} == "$current" ]]; then
            set_default "${names[(i + 1) % ${#names[@]}]}"
            return
        fi
    done
    set_default "${names[0]}"
}

cmd_menu() {
    local -a names=() descs=()
    local name desc current marker choice i menu=""
    current=$(pactl get-default-sink)
    while IFS=$'\t' read -r name desc; do
        names+=("$name")
        descs+=("$desc")
    done < <(sink_list)
    (( ${#names[@]} )) || exit 0

    for i in "${!names[@]}"; do
        [[ ${names[i]} == "$current" ]] && marker="●" || marker="○"
        menu+="$marker $(icon_for "${names[i]}")  ${descs[i]}"$'\n'
    done

    # -format i returns the row index, so two devices sharing a description
    # (two identical USB headsets, say) stay distinguishable.
    choice=$(printf '%s' "$menu" | rofi -dmenu -i -p "Output" -format i) || exit 0
    [[ -n $choice ]] || exit 0
    set_default "${names[choice]}"
}

emit_state() {
    local current desc icon class text tooltip="" name d marker
    current=$(pactl get-default-sink 2>/dev/null) || return 0
    [[ -n $current ]] || return 0

    desc=$(describe "$current")
    icon=$(icon_for "$current")
    class=$(class_for "$current")

    while IFS=$'\t' read -r name d; do
        [[ $name == "$current" ]] && marker="● " || marker="○ "
        tooltip+="$marker$(json_escape "$d")\\n"
    done < <(sink_list)
    tooltip="Output: $(json_escape "$desc")\\n\\n${tooltip%\\n}"

    text=$(json_escape "$icon")
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
}

# waybar reads one JSON object per line for as long as this runs, so state
# changes show up immediately instead of on a poll interval.
cmd_waybar() {
    local last="" line state
    while true; do
        state=$(emit_state) && [[ -n $state ]] && { printf '%s\n' "$state"; last=$state; }

        # Deliberately not `set -e`-fatal: pactl subscribe only returns when
        # the audio daemon goes away, and waybar should keep the module rather
        # than lose it until the next bar restart.
        while read -r line; do
            case $line in
                *"on server"*|*"on sink "*|*"on card"*)
                    state=$(emit_state) || continue
                    [[ -n $state && $state != "$last" ]] || continue
                    printf '%s\n' "$state"
                    last=$state
                    ;;
            esac
        done < <(pactl subscribe 2>/dev/null)

        # Daemon restarting. Back off so we do not spin on a dead socket.
        sleep 2
    done
}

case "${1:-}" in
    waybar) cmd_waybar ;;
    next)   cmd_next ;;
    menu)   cmd_menu ;;
    set)    set_default "${2:?usage: $0 set <sink-name>}" ;;
    list)   sink_list ;;
    *)
        echo "Usage: $0 {waybar|next|menu|set <sink-name>|list}" >&2
        exit 1
        ;;
esac
