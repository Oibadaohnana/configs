#!/usr/bin/env bash

# X11 port of screenshot.sh: slop selects the region grim/slurp used to,
# maim grabs it, and xclip puts it on the clipboard in place of wl-copy.
#
# xclip must keep running to own the CLIPBOARD selection -- X11 has no
# clipboard manager in the protocol, and the data lives in the owning process
# until something else claims it. Hence the background fork, which wl-copy
# needed no equivalent of.

maim -s -u | tee /tmp/screenshot.png | xclip -selection clipboard -t image/png -i &
notify-send "📸 Screenshot copied to clipboard you awesome stupid biaatch"
