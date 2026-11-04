#!/usr/bin/env bash

# Two-way sync of ~/OneDrive with /OneDrive on cloud.buggly.de, then how much
# room is left on the server. Login comes from ~/.netrc (see setup.sh).
#
# nextcloudcmd prints nothing at all by default, and its only verbose mode
# (--logdebug) is a few hundred lines of Qt debug output per handful of files.
# So it always runs with --logdebug, the log goes to $LOG, and only the
# per-file lines are pulled out of it and shown as they finish.
#
# Usage:
#   ncsync.sh       sync, list every file that moved, show free space
#   ncsync.sh -v    same, but also stream the full debug log
#   ncsync.sh -q    only show free space, don't sync

set -uo pipefail

HOST=cloud.buggly.de
NC_USER=benji
LOCAL=$HOME/OneDrive
REMOTE=/OneDrive
LOG=${XDG_CACHE_HOME:-$HOME/.cache}/ncsync.log

# Quota first; with no quota set (-3, "unlimited") the real limit is the
# server's disk, which only the admin serverinfo endpoint reports.
storage() {
    local dav free used info
    dav=$(curl -sfn -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' \
        --data '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>' \
        "https://$HOST/remote.php/dav/files/$NC_USER/") || { echo "Storage: couldn't reach $HOST"; return; }
    free=$(sed -n 's/.*<d:quota-available-bytes>\(-\?[0-9]*\)<.*/\1/p' <<<"$dav")
    used=$(sed -n 's/.*<d:quota-used-bytes>\([0-9]*\)<.*/\1/p' <<<"$dav")
    if [[ ${free:--3} -lt 0 ]]; then
        info=$(curl -sfn -H 'OCS-APIRequest: true' \
            "https://$HOST/ocs/v2.php/apps/serverinfo/api/v1/info?format=json&skipApps=true&skipUpdate=true")
        free=$(grep -o '"freespace":[0-9]*' <<<"$info" | cut -d: -f2)
    fi
    printf 'Storage: %s free on the server, %s used by your files\n' \
        "$(numfmt --to=iec --suffix=B "${free:-0}" 2>/dev/null || echo '?')" \
        "$(numfmt --to=iec --suffix=B "${used:-0}" 2>/dev/null || echo '?')"
}

# Reads the debug log. "Investigating" (before propagation) carries the
# direction, "Item completed" the result; print one line per finished item.
summarize() {
    awk -v verbose="$1" '
    function path(s) {
        sub(/^[^"]*"/, "", s)
        sub(/" (OCC|CSyncEnums)::.*$/, "", s)
        return s
    }
    verbose { print; fflush() }
    /Investigating "/ {
        p = path($0)
        dir[p] = ($0 ~ /SyncFileItem::Up /) ? "up" : "down"
        isdir[p] = ($0 ~ /ItemTypeDirectory/)
        next
    }
    /Item completed "/ {
        p = path($0)
        match($0, /CSYNC_INSTRUCTION_[A-Z_]+/)
        ins = substr($0, RSTART + 18, RLENGTH - 18)
        if (ins == "NONE" || ins == "IGNORE" || ins == "UPDATE_METADATA") next
        match($0, /SyncFileItem::[A-Za-z]+/)
        st = substr($0, RSTART + 14, RLENGTH - 14)
        up = (dir[p] == "up")
        if      (ins == "NEW")         what = up ? "uploaded" : "downloaded"
        else if (ins == "SYNC")        what = up ? "updated on server" : "updated here"
        else if (ins == "REMOVE")      what = up ? "deleted on server" : "deleted here"
        else if (ins == "RENAME")      what = up ? "renamed on server" : "renamed here"
        else if (ins == "CONFLICT")    what = "conflict"
        else if (ins == "TYPE_CHANGE") what = "type changed"
        else                           what = tolower(ins)
        arrow = (ins == "CONFLICT") ? "!" : (up ? "↑" : "↓")
        if (st != "Success" && st != "NoStatus") { arrow = "✗"; what = what " FAILED (" st ")"; failed++ }
        else count[up ? "up" : "down"]++
        printf "%s %-18s %s%s\n", arrow, what, p, (isdir[p] ? "/" : ""); fflush()
    }
    END {
        if (!count["up"] && !count["down"] && !failed) print "Already up to date."
        else printf "%d to the server, %d from the server%s\n", count["up"], count["down"],
            failed ? ", " failed " failed" : ""
    }'
}

verbose=0
case ${1:-} in
    -v) verbose=1 ;;
    -q) storage; exit ;;
    "") ;;
    *) sed -n '/^# Usage:/,/^$/s/^# \?//p' "$0"; exit 2 ;;
esac

mkdir -p "$(dirname "$LOG")" "$LOCAL"
nextcloudcmd -n --non-interactive --logdebug --path "$REMOTE" "$LOCAL" "https://$HOST" 2>&1 |
    tee "$LOG" | summarize "$verbose"
rc=${PIPESTATUS[0]}
((rc)) && echo "nextcloudcmd exited with $rc -- full log: $LOG"
storage
exit "$rc"
