#!/usr/bin/env bash
set -euo pipefail

# Regenerates the Hyprland keybind cheat-sheet wallpaper from the bindings
# listed below (kept in sync with configs/hyprland by hand). Writes an SVG,
# then rasterizes it to configs/wallpapers/hyprland-cheatsheet.png.
#
# Usage: scripts/generate_hyprland_wallpaper.sh
# Reload after regenerating: hyprctl hyprpaper reload ,~/nixcfg/configs/wallpapers/hyprland-cheatsheet.png

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../configs/wallpapers"
SVG="$OUT_DIR/hyprland-cheatsheet.svg"
PNG="$OUT_DIR/hyprland-cheatsheet.png"
OUT="$SVG"
W=2560
H=1440

esc() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"
}

# ---- layout constants ----
MARGIN=100
GAP=40
COLW=$(( (W - 2*MARGIN - 3*GAP) / 4 ))
COL_X=($MARGIN $((MARGIN+COLW+GAP)) $((MARGIN+2*(COLW+GAP))) $((MARGIN+3*(COLW+GAP))))
CONTENT_TOP=210
KEY_FONT=22
DESC_FONT=19
HEADER_FONT=27
ROW_H=58
HEADER_H=52
SECTION_GAP=32
CARD_PAD_X=22
CARD_PAD_TOP=14
CARD_PAD_BOTTOM=20

body=""
cards=""

col_y=($CONTENT_TOP $CONTENT_TOP $CONTENT_TOP $CONTENT_TOP)

# section_height(nrows) -> px
section_height() {
    local n=$1
    echo $(( HEADER_H + n*ROW_H ))
}

# add_section col title row1 row2 ...  (rows are "KEY|DESC" pairs, alternating)
add_section() {
    local col=$1; shift
    local title=$1; shift
    local rows=("$@")
    local n=$(( ${#rows[@]} / 2 ))
    local x=${COL_X[$col]}
    local y=${col_y[$col]}
    local sh=$(section_height "$n")

    # card background
    local card_h=$(( sh + CARD_PAD_TOP + CARD_PAD_BOTTOM - 14 ))
    cards+="<rect x=\"$((x-CARD_PAD_X))\" y=\"$((y-CARD_PAD_TOP))\" width=\"$((COLW+2*CARD_PAD_X))\" height=\"$card_h\" rx=\"16\" class=\"card\"/>"

    # header
    local ty=$((y+30))
    body+="<text x=\"$x\" y=\"$ty\" class=\"header\">$(esc "$title")</text>"
    body+="<line x1=\"$x\" y1=\"$((ty+12))\" x2=\"$((x+COLW))\" y2=\"$((ty+12))\" class=\"rule\"/>"

    local ry=$((y+HEADER_H+22))
    local i=0
    while [ $i -lt ${#rows[@]} ]; do
        local key="${rows[$i]}"
        local desc="${rows[$((i+1))]}"
        body+="<text x=\"$x\" y=\"$ry\" class=\"key\">$(esc "$key")</text>"
        body+="<text x=\"$x\" y=\"$((ry+26))\" class=\"desc\">$(esc "$desc")</text>"
        ry=$((ry+ROW_H))
        i=$((i+2))
    done

    col_y[$col]=$((y+sh+SECTION_GAP))
}

# ---------------- COLUMN 0 ----------------
add_section 0 "APPLICATIONS" \
    "SUPER + Return"        "Open terminal (kitty)" \
    "SUPER + F2"             "Open Firefox" \
    "SUPER + F1"             "Open volume mixer" \
    "SUPER + F3"             "Open Bluetooth manager" \
    "SUPER + F4"             "Open display manager" \
    "SUPER + D"              "Open app launcher (rofi)" \
    "SUPER + V"              "Show clipboard history" \
    "SUPER + End"            "Toggle gaming display"

add_section 0 "SESSION" \
    "SUPER + L"              "Lock screen" \
    "Ctrl + Alt + Del"       "Logout menu" \
    "SUPER + Shift + P"      "Shut down"

add_section 0 "SCREENSHOT" \
    "SUPER + Shift + Print"  "Screenshot (or F12)"

# ---------------- COLUMN 1 ----------------
add_section 1 "WINDOWS" \
    "SUPER + Alt + Q"        "Close window (or Alt+F4)" \
    "SUPER + Ctrl + Esc"     "Force-kill window" \
    "SUPER + F"               "Fullscreen (or SUPER+PgUp)" \
    "SUPER + Shift + Space"   "Toggle floating" \
    "SUPER + Space"           "Cycle windows" \
    "SUPER + Shift + C"       "Reload Hyprland config" \
    "SUPER + Shift + E"       "Exit session"

add_section 1 "MOUSE" \
    "SUPER + Drag L/R-click"  "Move / resize floating win."

add_section 1 "SCRATCHPAD" \
    "SUPER + Minus"           "Send window to scratchpad" \
    "SUPER + Shift + Minus"   "Toggle scratchpad"

# ---------------- COLUMN 2 ----------------
add_section 2 "FOCUS" \
    "SUPER + Left"            "Focus window left" \
    "SUPER + Right"           "Focus window right" \
    "SUPER + Up"              "Focus window up" \
    "SUPER + Down"            "Focus window down (Alt also works)"

add_section 2 "MOVE WINDOWS" \
    "SUPER + Shift + Left/Right"  "Move to prev/next monitor" \
    "SUPER + Shift + H/J/K/L"     "Move window (vim keys)"

add_section 2 "KEYBOARD LAYOUT" \
    "SUPER + Alt + K"         "Next keyboard layout" \
    "SUPER + Alt + P"         "Previous keyboard layout"

add_section 2 "RESIZE MODE" \
    "SUPER + R"                "Enter resize mode" \
    "H / J / K / L / arrows"   "Resize active window" \
    "Return / Esc"             "Exit resize mode"

# ---------------- COLUMN 3 ----------------
add_section 3 "WORKSPACES" \
    "SUPER + 1..0"                "Switch to workspace 1-10" \
    "SUPER + Shift + 1..0"        "Move window to workspace" \
    "SUPER + Ctrl + arrows"       "Switch workspace +-1" \
    "SUPER + Ctrl + Shift + L/R"  "Move window to workspace +-1"

add_section 3 "WINDOW SWITCHING" \
    "Alt+Tab / SUPER+Tab"     "Cycle windows (+Shift = rev.)"

add_section 3 "VOLUME / BRIGHTNESS / MEDIA" \
    "Volume Up / Down"        "Volume +-5% (on-screen bar)" \
    "Shift + Volume Up/Down"  "Volume +-1% (fine control)" \
    "Mute / Mic Mute"         "Toggle speaker / mic mute" \
    "F9"                      "Push-to-mute mic (Discord etc.)" \
    "Play / Next / Prev"      "Media playback control" \
    "Rewind / Forward"        "Seek -+5s in track" \
    "Brightness Up / Down"    "Brightness +-5%" \
    "Shift + Brightness"      "Brightness +-1% (fine)"

cat > "$OUT" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#11111b"/>
      <stop offset="100%" stop-color="#1e1e2e"/>
    </linearGradient>
    <radialGradient id="glow1" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0%" stop-color="#ff8800" stop-opacity="0.16"/>
      <stop offset="100%" stop-color="#ff8800" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow2" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0%" stop-color="#89b4fa" stop-opacity="0.14"/>
      <stop offset="100%" stop-color="#89b4fa" stop-opacity="0"/>
    </radialGradient>
    <style>
      .card   { fill: #24243a; fill-opacity: 0.55; stroke: #45475a; stroke-width: 1.5; }
      .header { font-family: 'Liberation Sans'; font-weight: bold; font-size: ${HEADER_FONT}px; fill: #89b4fa; letter-spacing: 1px; }
      .rule   { stroke: #45475a; stroke-width: 1.5; }
      .key    { font-family: 'Hack'; font-weight: bold; font-size: ${KEY_FONT}px; fill: #ff9a3d; }
      .desc   { font-family: 'Liberation Sans'; font-size: ${DESC_FONT}px; fill: #cdd6f4; }
      .title  { font-family: 'Liberation Sans'; font-weight: bold; font-size: 76px; fill: #ff8800; letter-spacing: 6px; }
      .subtitle { font-family: 'Liberation Sans'; font-size: 26px; fill: #89b4fa; letter-spacing: 3px; }
      .footer { font-family: 'Hack'; font-size: 18px; fill: #6c7086; }
    </style>
  </defs>

  <rect x="0" y="0" width="$W" height="$H" fill="url(#bg)"/>
  <circle cx="200" cy="200" r="500" fill="url(#glow1)"/>
  <circle cx="2360" cy="1300" r="600" fill="url(#glow2)"/>

  <text x="$((W/2))" y="100" text-anchor="middle" class="title">HYPRLAND</text>
  <text x="$((W/2))" y="140" text-anchor="middle" class="subtitle">KEYBOARD SHORTCUTS  ·  SUPER = MOD KEY</text>
  <line x1="$MARGIN" y1="168" x2="$((W-MARGIN))" y2="168" class="rule"/>

  $cards
  $body

  <text x="$((W/2))" y="$((H-40))" text-anchor="middle" class="footer">Reload config after edits: SUPER+Shift+C  or  hyprctl reload   ·   ~/nixcfg/configs/hyprland</text>
</svg>
SVG

echo "Wrote $SVG"

if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$W" -h "$H" "$SVG" -o "$PNG"
    echo "Wrote $PNG"
else
    echo "rsvg-convert not found; run: nix-shell -p librsvg --run \"rsvg-convert -w $W -h $H '$SVG' -o '$PNG'\""
fi
