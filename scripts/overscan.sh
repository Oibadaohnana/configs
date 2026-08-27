#!/usr/bin/env bash

# Sizes a window to the region an overscanning display actually shows.
#
# Overscan is the habit HDMI televisions have of magnifying the picture past
# the panel edges and throwing the border away. Two uses, one piece of
# geometry:
#
#   * Watching something on such a TV. Fullscreen video loses its edges to the
#     crop; inset the window by the same amount and the whole picture lands
#     inside what the TV really shows.
#   * Checking what a TV would cut off, from a monitor that does not overscan.
#     Everything outside the window is what would have been eaten.
#
# The amount belongs to the screen, not to the session: the TV in the corner
# crops, the desk monitor does not. So it is stored per output, set once with
# `set`, and the hotkey then applies whatever the window's own monitor asks
# for. Configuring and applying are separate commands on purpose -- `set`
# never touches a window.
#
# PERCENT IS PER EDGE, not in total. `overscan.sh set 5` crops 5% off each of
# the four sides and leaves the central 90% x 90%. That is the broadcast
# "action safe" convention; 10 is "title safe". Consumer TV specs often quote
# the figure the other way round (5% meaning 2.5% a side), so halve theirs to
# get this one. The useful range is small -- most overscanning sets take 2-5%
# a side -- and anything from 50 up is refused, because it leaves no window.
#
# The inset is measured from the physical panel edge, not from the usable
# area, because the panel edge is what the display crops -- so the window
# overlaps waybar's strip. That is correct: on a real overscanning TV part of
# waybar would be cut off too.
#
# Usage:
#   overscan.sh set <percent> [output]   remember it for that screen, and do
#                                        nothing else; defaults to the focused
#                                        screen
#   overscan.sh                          toggle the focused window, using its
#                                        own monitor's remembered percentage
#   overscan.sh <percent>                toggle at this percentage just once,
#                                        without changing what is remembered
#   overscan.sh off                      put the window back
#   overscan.sh show                     print the region, change nothing
#   overscan.sh --plain                  inset only, no client-side fullscreen
#   overscan.sh <percent> <sel>          target a window other than the focused
#                                        one, by any Hyprland selector:
#                                        address:0x..., class:firefox

set -euo pipefail

# What a screen with nothing remembered for it gets.
FALLBACK_PERCENT=5

# Per-window geometry, so a window can be put back where it came from. Runtime,
# because a saved position is meaningless once the window is gone.
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/hypr-overscan"
REPORT="$STATE_DIR/report"

# The remembered percentages, one "OUTPUT<TAB>PERCENT" line per screen. Same
# shape and same directory as monitors.sh's monitor-sides file, and outside
# this repo for the same reason: it describes one machine's displays, not the
# configuration both hosts share.
PREF_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
PREF_FILE="$PREF_DIR/overscan-percent"

mode=""
percent=-1          # -1 means "look it up from the window's monitor"
selector=""
client_fs=2         # 2 = tell the client it is fullscreen; see the note below

# The selector is picked out by shape rather than by position: it is optional,
# and "overscan.sh show class:firefox" and "overscan.sh show 10 class:firefox"
# would otherwise put it in different argument slots.
args=()
for a in "$@"; do
    case "$a" in
        --plain) client_fs=0 ;;
        *:*)     selector=$a ;;
        *)       args+=("$a") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

valid_percent() {
    [[ $1 =~ ^[0-9]+$ ]] || { echo "Not a percentage: $1" >&2; return 1; }
    # 50% a side would leave a window zero pixels wide, and the compositor
    # would clamp it to its minimum rather than refuse -- so catch it here,
    # where the number still means something.
    if (( $1 > 49 )); then
        echo "Percent is cropped off EACH edge, so it must be 0-49 (got $1)." >&2
        echo "A TV that overscans usually needs 2-5." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# set: remember a percentage for one screen. Deliberately the only command
# that writes the preference, and deliberately the only one that touches no
# window at all -- it is configuration, not an action.
# ---------------------------------------------------------------------------
if [[ ${1:-} == set ]]; then
    pct=${2:?usage: $0 set <percent> [output]}
    valid_percent "$pct" || exit 1

    output=${3:-}
    if [[ -z $output ]]; then
        output=$(hyprctl monitors | awk '/^Monitor /{ n = $2 } /focused: yes/{ print n; exit }')
    fi
    [[ -n $output ]] || { echo "Could not tell which screen is focused." >&2; exit 1; }
    [[ $output =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Refusing odd output name: $output" >&2; exit 1; }

    mkdir -p "$PREF_DIR"
    # Rewritten wholesale rather than edited in place: it is one short line per
    # screen. Malformed lines are dropped on the way past, which also clears
    # out the single bare number this file held before it was per-screen.
    tmp="$PREF_FILE.tmp"
    : >"$tmp"
    if [[ -f $PREF_FILE ]]; then
        while IFS=$'\t' read -r mon val; do
            [[ $mon == "$output" ]] && continue
            [[ $mon =~ ^[A-Za-z0-9._-]+$ && $val =~ ^[0-9]+$ ]] || continue
            printf '%s\t%s\n' "$mon" "$val" >>"$tmp"
        done <"$PREF_FILE"
    fi
    printf '%s\t%s\n' "$output" "$pct" >>"$tmp"
    mv "$tmp" "$PREF_FILE"

    printf 'Overscan for %s set to %s%% per edge.\n' "$output" "$pct"
    printf 'Nothing moved -- press Meta+Alt+O on a window to apply it.\n'
    exit 0
fi

case "${1:-}" in
    "")            mode=toggle ;;
    off|0)         mode=off; percent=0 ;;
    show)          mode=show; [[ -n ${2:-} ]] && { valid_percent "$2" || exit 1; percent=$2; } ;;
    -h|--help)     sed -n '3,45p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)             valid_percent "$1" || exit 1; mode=toggle; percent=$1 ;;
esac

# Interpolated into the Lua below, so refuse anything not shaped like a
# Hyprland selector.
if [[ -n $selector && ! $selector =~ ^(address|class|title|initialclass|initialtitle|pid):[A-Za-z0-9._:^$-]+$ ]]; then
    echo "Refusing odd selector: $selector" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"
rm -f "$REPORT"

# Why one big Lua expression rather than shell arithmetic over `hyprctl -j`:
# `hyprctl dispatch` wraps its argument in `return hl.dispatch(<arg>)`, so it
# takes an expression and nothing else -- hence the immediately-invoked
# function. Everything then happens in one round trip, against typed monitor
# and window objects, with no JSON to parse. (jq is not installed on either
# host, and the compositor is the only thing that knows the logical geometry.)
#
# The preference file is read in here rather than in the shell because only
# this side knows which monitor the target window is actually on -- which is
# the whole point of storing the percentage per screen.
lua="(function()
  local PERCENT, MODE = $percent, '$mode'
  local STATE, REPORT = '$STATE_DIR', '$REPORT'
  local PREF_FILE, FALLBACK = '$PREF_FILE', $FALLBACK_PERCENT
  local SELECTOR, CLIENT_FS = '$selector', $client_fs

  local function report(line)
    local f = io.open(REPORT, 'w')
    if f then f:write(line .. '\n') f:close() end
  end

  local function stored_for(name)
    local f = io.open(PREF_FILE, 'r')
    if not f then return nil end
    local found
    for line in f:lines() do
      local mon, pct = line:match('^(%S+)\t(%d+)\$')
      if mon == name then found = tonumber(pct) end
    end
    f:close()
    return found
  end

  -- A selector picks the window out of the list rather than going through a
  -- focus dispatch, so targeting one on another workspace does not drag the
  -- focus over there to do it.
  local w
  if SELECTOR == '' then
    w = hl.get_active_window()
  else
    local kind, val = SELECTOR:match('^(%w+):(.+)')
    for _, x in ipairs(hl.get_windows()) do
      local field = (kind == 'address' and x.address)
                 or (kind == 'class' and x.class)
                 or (kind == 'title' and x.title)
                 or (kind == 'initialclass' and x.initial_class)
                 or (kind == 'pid' and tostring(x.pid))
      if field and (field == val or field:match(val)) then w = x break end
    end
  end
  if not w then report('none 0 0 0 0 0 - -') return hl.dsp.no_op() end

  local sel  = 'address:' .. w.address
  local path = STATE .. '/' .. w.address
  local m    = w.monitor

  local saved
  local sf = io.open(path, 'r')
  if sf then saved = sf:read('*l') sf:close() end

  local function restore()
    local fl, x, y, sw, sh = saved:match('^(%a+) (-?%d+) (-?%d+) (%d+) (%d+)')
    -- Tell the client it is a normal window again before anything else, or
    -- Firefox stays in its chrome-less video mode inside a re-tiled window.
    hl.dispatch(hl.dsp.window.fullscreen_state({ window = sel, internal = 0, client = 0 }))
    if fl == 'tiled' then
      -- Back into the layout; Hyprland re-tiles it and the old floating size
      -- stops mattering.
      hl.dispatch(hl.dsp.window.float({ window = sel, action = 'disable' }))
    elseif fl then
      hl.dispatch(hl.dsp.window.resize({ window = sel, x = tonumber(sw), y = tonumber(sh), relative = false }))
      hl.dispatch(hl.dsp.window.move({ window = sel, x = tonumber(x), y = tonumber(y), relative = false }))
    end
    os.remove(path)
  end

  -- Which percentage applies: an explicit one from the command line, else
  -- whatever this window's own screen has remembered, else the fallback.
  local src = 'explicit'
  if PERCENT < 0 then
    local s = stored_for(m.name)
    if s then PERCENT, src = s, 'stored' else PERCENT, src = FALLBACK, 'fallback' end
  end

  -- Logical geometry: monitor.width/height are physical pixels, and everything
  -- a window is positioned in is those divided by the scale. Transforms 1/3/5/7
  -- are the 90 and 270 degree rotations, where a portrait panel occupies its
  -- height horizontally.
  local lw, lh = m.width / m.scale, m.height / m.scale
  if m.transform % 2 == 1 then lw, lh = lh, lw end

  local ix, iy = math.floor(lw * PERCENT / 100), math.floor(lh * PERCENT / 100)
  local x, y   = math.floor(m.x + ix), math.floor(m.y + iy)
  local sw, sh = math.floor(lw - 2 * ix), math.floor(lh - 2 * iy)

  if MODE == 'show' then
    report(string.format('show %d %d %d %d %d %s %s %s', PERCENT, x, y, sw, sh, m.name, w.class, src))
    return hl.dsp.no_op()
  end

  if MODE == 'off' or (MODE == 'toggle' and saved) then
    if saved then restore() report(string.format('off 0 0 0 0 0 %s %s %s', m.name, w.class, src))
    else report(string.format('noop 0 0 0 0 0 %s %s %s', m.name, w.class, src)) end
    return hl.dsp.no_op()
  end

  -- Only the first application records the original geometry: re-running at a
  -- different percentage must still restore to where the window started, not
  -- to the previous inset.
  if not saved then
    local f = io.open(path, 'w')
    if f then
      f:write(string.format('%s %d %d %d %d',
        w.floating and 'float' or 'tiled', w.at.x, w.at.y, w.size.x, w.size.y))
      f:close()
    end
  end

  -- A fullscreen window ignores position and size entirely, so drop that first
  -- or the move below is silently discarded.
  --
  -- 'unset', not 'disable': the two dispatchers do not share a vocabulary --
  -- float takes enable/disable/toggle, fullscreen takes set/unset/toggle. A
  -- wrong verb here is not a no-op, it raises and takes the rest of this
  -- function down with it.
  if w.fullscreen ~= 0 then
    hl.dispatch(hl.dsp.window.fullscreen({ window = sel, action = 'unset' }))
  end

  hl.dispatch(hl.dsp.window.float({ window = sel, action = 'enable' }))
  hl.dispatch(hl.dsp.window.resize({ window = sel, x = sw, y = sh, relative = false }))
  hl.dispatch(hl.dsp.window.move({ window = sel, x = x, y = y, relative = false }))

  -- internal = 0, client = 2: the compositor keeps treating this as an
  -- ordinary floating window at the size just set, while the client is told it
  -- is fullscreen. That is the whole trick for video -- Firefox drops its tabs
  -- and toolbars and fills its window with the picture, but the window is the
  -- inset one, so nothing runs off the edge of the TV. Real fullscreen would
  -- snap it back to the whole panel and hand the crop right back.
  --
  -- It goes last on purpose: floating and resizing a window clear the client
  -- fullscreen flag, so setting it any earlier is undone before it is seen.
  --
  -- Dispatched unconditionally, including for --plain's client = 0. Skipping
  -- it there would leave the flag set from a previous run: re-applying to an
  -- already-floating window at the same size changes nothing, so nothing
  -- clears the flag on the way past.
  hl.dispatch(hl.dsp.window.fullscreen_state({ window = sel, internal = 0, client = CLIENT_FS }))

  report(string.format('on %d %d %d %d %d %s %s %s', PERCENT, x, y, sw, sh, m.name, w.class, src))
  return hl.dsp.no_op()
end)()"

# hyprctl prints Lua errors on stdout and still exits 0 for some of them, so
# check the text as well as the status. Swallowing this is how a mistyped
# dispatcher verb turns into "the script silently does nothing".
if ! out=$(hyprctl dispatch "$lua" 2>&1) || [[ $out == error:* ]]; then
    printf 'Hyprland rejected the request:\n%s\n' "$out" >&2
    exit 1
fi

read -r state pct x y w h monitor class src < "$REPORT" 2>/dev/null || {
    echo "Hyprland did not answer -- is it running?" >&2
    exit 1
}

case "$state" in
    none)
        echo "No window to inset." >&2
        exit 1
        ;;
    show)
        case "$src" in
            stored)   note="remembered for $monitor" ;;
            fallback) note="nothing remembered for $monitor, using the $FALLBACK_PERCENT% fallback" ;;
            *)        note="given on the command line" ;;
        esac
        printf 'Overscan %s%% per edge on %s (%s)\n' "$pct" "$monitor" "$class"
        printf '  visible region: %sx%s at %s,%s\n' "$w" "$h" "$x" "$y"
        printf '  %s\n' "$note"
        ;;
    on)
        notify-send -a overscan -r 9002 \
            "Overscan ${pct}% — ${class}" "${w}x${h} of ${monitor}"
        ;;
    off)
        notify-send -a overscan -r 9002 "Overscan off — ${class}" "Restored on ${monitor}"
        ;;
    noop)
        notify-send -a overscan -r 9002 "Overscan off — ${class}" "It was not inset"
        ;;
esac

# Windows that have since been closed would otherwise leave their saved
# geometry behind forever. Cheap to sweep here; the directory is tiny and lives
# in the runtime dir, so it is empty again after a reboot regardless.
if [[ -d $STATE_DIR ]]; then
    live=$(hyprctl clients | awk '/^Window /{ print "0x" $2 }')
    for f in "$STATE_DIR"/0x*; do
        [[ -e $f ]] || continue
        grep -qxF "$(basename "$f")" <<<"$live" || rm -f "$f"
    done
fi
