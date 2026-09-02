#!/usr/bin/env bash

# Opens and closes sshd from the terminal. The unit is declared in
# configuration.nix but its wantedBy is forced empty, so it only runs when
# started here -- a reboot leaves ssh closed.
#
# "sshon 2h" additionally arms a transient root timer that closes sshd again
# after the given span, so a session left open does not stay open. System
# scope, not --user: the timer has to stop sshd without a password prompt at
# fire time, and must survive logout.
#
# Usage:
#   ssh_toggle.sh on [span]   start sshd, optionally auto-closing after span
#   ssh_toggle.sh off         stop sshd and cancel any pending auto-close
#   ssh_toggle.sh toggle      on <-> off
#   ssh_toggle.sh status      print state, address, sessions, auto-close

set -euo pipefail

UNIT=sshd.service
PORT=22
SSHD_CONFIG=/etc/ssh/sshd_config
AUTOCLOSE=sshd-autoclose
SYSTEMCTL=/run/current-system/sw/bin/systemctl

is_up() {
    systemctl is-active --quiet "$UNIT"
}

lan_ip() {
    ip -4 -o addr show scope global 2>/dev/null |
        awk '{ split($4, a, "/"); print a[1]; exit }'
}

# established inbound connections on the ssh port
conn_count() {
    ss -Htn state established "( sport = :$PORT )" 2>/dev/null | wc -l
}

allowed_users() {
    awk 'tolower($1) == "allowusers" { $1 = ""; sub(/^ /, ""); print; exit }' \
        "$SSHD_CONFIG" 2>/dev/null
}

# span -> whole seconds. Feeding systemd an integer avoids it reparsing the
# string the user typed.
span_secs() {
    systemd-analyze timespan "$1" 2>/dev/null |
        sed -n '2s/.*: *//p' |
        awk '{ printf "%d\n", $1 / 1000000 }'
}

# Seconds until the auto-close fires, failing if none is pending. An elapsed
# transient timer still reports is-active, so a numeric "next" is the only
# reliable signal -- systemd prints null for it once the timer has run.
autoclose_secs_left() {
    local next now
    next=$(systemctl list-timers "$AUTOCLOSE.timer" --output=json --no-pager 2>/dev/null |
        grep -o '"next":[0-9]\+' | head -1 | cut -d: -f2)
    [[ -n $next ]] || return 1
    now=$(date +%s)
    (( next / 1000000 > now )) || return 1
    printf '%s' $(( next / 1000000 - now ))
}

autoclose_pending() {
    autoclose_secs_left >/dev/null
}

# let systemd phrase the span rather than hand-rolling it
autoclose_left() {
    local secs
    secs=$(autoclose_secs_left) || return 1
    systemd-analyze timespan "${secs}s" 2>/dev/null | sed -n '3s/.*: *//p'
}

autoclose_loaded() {
    [[ $(systemctl show -p LoadState --value "$AUTOCLOSE.timer" 2>/dev/null) == loaded ]]
}

# An elapsed or failed transient unit keeps its name taken and systemd-run
# would refuse to reuse it, so this runs before every arm as well as on off.
# Skipped entirely when nothing is loaded, to avoid a pointless sudo prompt.
autoclose_clear() {
    autoclose_loaded || return 0
    sudo systemctl stop "$AUTOCLOSE.timer" 2>/dev/null || true
    sudo systemctl reset-failed "$AUTOCLOSE.timer" "$AUTOCLOSE.service" 2>/dev/null || true
}

autoclose_arm() {
    local span=$1 secs
    secs=$(span_secs "$span")
    if (( secs < 1 )); then
        echo "span too short: $span" >&2
        exit 1
    fi
    autoclose_clear
    sudo systemd-run --quiet --unit="$AUTOCLOSE" --on-active="$secs" \
        "$SYSTEMCTL" stop "$UNIT" >/dev/null
    printf '  auto-close at %s (in %s)\n' \
        "$(date -d "+$secs seconds" '+%H:%M')" "$span"
}

# what to hand the person connecting
print_target() {
    local ip user
    ip=$(lan_ip)
    user=$(allowed_users)
    printf '  connect with:  ssh %s@%s\n' "${user:-$USER}" "${ip:-<no address>}"
    printf '  copy files:    scp <files> %s@%s:~/\n' "${user:-$USER}" "${ip:-<no address>}"
}

cmd_on() {
    local span=${1:-}
    if [[ -n $span ]] && ! systemd-analyze timespan "$span" >/dev/null 2>&1; then
        echo "not a duration: $span  (try 2h, 30m, 90s, 1h30m)" >&2
        exit 1
    fi

    if is_up; then
        echo "sshd already open"
    else
        sudo systemctl start "$UNIT"
        echo "sshd open on port $PORT"
    fi

    if [[ -n $span ]]; then
        autoclose_arm "$span"
    elif autoclose_pending; then
        # plain "sshon" means open-ended, so drop a timer set by an earlier run
        autoclose_clear
        echo "  auto-close cancelled -- open until you run sshoff"
    fi
    print_target
}

cmd_off() {
    # cancel first, so a stale timer cannot close a later sshon behind our back
    autoclose_clear
    if ! is_up; then
        echo "sshd already closed"
        return
    fi
    local live
    live=$(conn_count)
    sudo systemctl stop "$UNIT"
    echo "sshd closed -- no new logins"
    # KillMode=process, so stopping only drops the listener
    if (( live > 0 )); then
        echo "note: $live session(s) still connected, they keep running until they exit"
    fi
}

cmd_toggle() {
    if is_up; then cmd_off; else cmd_on "${1:-}"; fi
}

cmd_status() {
    local allowed
    allowed=$(allowed_users)
    if is_up; then
        echo "sshd: OPEN (port $PORT, $(conn_count) live session(s))"
        if autoclose_pending; then
            echo "  auto-close in $(autoclose_left)"
        else
            echo "  no auto-close -- open until you run sshoff"
        fi
        print_target
    else
        echo "sshd: closed"
    fi
    echo "  allowed users: ${allowed:-<unset -- any user with an account>}"
}

case "${1:-}" in
    on)     cmd_on "${2:-}" ;;
    off)    cmd_off ;;
    toggle) cmd_toggle "${2:-}" ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 {on [span]|off|toggle|status}" >&2
        exit 1
        ;;
esac
