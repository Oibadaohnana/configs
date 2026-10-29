#!/usr/bin/env bash
#
# setup.sh — guided setup of a PC from this repo, as a checklist.
#
# Run it right after cloning to ~/nixcfg, and again after the reboot it asks
# for. Every run re-checks the whole list from scratch, so it is safe to run
# any number of times and picks up where the last run stopped:
#
#   1. Before the first build — user, repo, host entry in flake.nix, disk
#                               UUIDs, dotfile symlinks, a dry evaluation
#   2. First build            — nixos-rebuild for this host, then a reboot
#   3. After the first boot   — SSH key, GitHub, git identity, Nextcloud
#   4. Optional               — server access, logins, Bluetooth, printer,
#                               Steam, … The walk-through doesn't stop at
#                               these; most tick themselves off with use
#
# Steps it can do itself it does after asking, and says what it did. Steps
# only you can do it explains and then waits for you to mark them done or
# skip them; those marks live in ~/.local/state/nixcfg-setup/marks.
#
# Before the clone (nothing here exists yet):
#   nix-shell -p git
#   git clone git@github.com:Oibadaohnana/configs.git ~/nixcfg   # or https://
#   ~/nixcfg/scripts/setup.sh
#
# Usage: ./setup.sh [--list] [--host NAME] [--reset]
#   --list       print the checklist and exit, change nothing
#   --host NAME  treat this PC as flake host NAME
#   --reset      forget every "done"/"skip" mark and the chosen host

set -uo pipefail

REPO="$HOME/nixcfg"
FLAKE="$REPO/nixos"
SELF_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nixcfg-setup"
MARKS="$STATE_DIR/marks"
NIX=(nix --extra-experimental-features "nix-command flakes")
NC_HOST="cloud.buggly.de"
NC_USER="benji"
NC_DIR="$HOME/OneDrive"
ME=$(id -un)
TTY=/dev/tty

LIST_ONLY=0 HOST_ARG="" DO_RESET=0

# ---------------------------------------------------------------- ui ---

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
    YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; RESET=''
fi

info()    { printf '  %s\n' "$*"; }
ok()      { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()     { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
cmdline() { printf '      %s%s%s\n' "$CYAN" "$*" "$RESET"; }
indent()  { sed 's/^/      /'; }

have_tty() { { : <"$TTY"; } 2>/dev/null; }

ask() {
    local q=$1 def=${2:-y} hint reply
    [[ $def == y ]] && hint='[Y/n]' || hint='[y/N]'
    while true; do
        printf '  %s %s ' "$q" "$hint"
        read -r reply <"$TTY" || return 1
        reply=${reply:-$def}
        case ${reply,,} in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
    done
}

# prompt VAR "question" [default]
prompt() {
    local __var=$1 q=$2 def=${3:-} reply
    if [[ -n $def ]]; then printf '  %s [%s]: ' "$q" "$def"; else printf '  %s: ' "$q"; fi
    read -r reply <"$TTY" || return 1
    printf -v "$__var" '%s' "${reply:-$def}"
}

wait_enter() {
    printf '  %s%s%s' "$DIM" "${1:-Press Enter to continue…}" "$RESET"
    read -r _ <"$TTY"
}

# Shows the command, lets it talk to the terminal, reports a failure.
run() {
    printf '  %s$ %s%s\n' "$DIM" "$*" "$RESET"
    "$@"
    local rc=$?
    (( rc == 0 )) || err "failed (exit $rc): $*"
    return "$rc"
}

# ------------------------------------------------------------ helpers ---

# A fresh install has no git. Fetch it once through nix and remember where.
GIT_BIN=""
git_() {
    if [[ -z $GIT_BIN ]]; then
        if command -v git >/dev/null; then
            GIT_BIN=$(command -v git)
        else
            local p
            p=$("${NIX[@]}" build --no-link --print-out-paths nixpkgs#git 2>/dev/null | head -n1)
            [[ -x $p/bin/git ]] || { err "git is not installed and nix could not fetch it"; return 127; }
            GIT_BIN=$p/bin/git
        fi
    fi
    "$GIT_BIN" -C "$REPO" "$@"
}

mark_get() { [[ -f $MARKS ]] && awk -v k="$1" '$1 == k { v = $2 } END { print v }' "$MARKS"; }
mark_del() { [[ -f $MARKS ]] && awk -v k="$1" '$1 != k' "$MARKS" >"$MARKS.tmp" && mv "$MARKS.tmp" "$MARKS"; }
mark_set() {
    mkdir -p "$STATE_DIR" || return 1
    mark_del "$1"
    printf '%s %s\n' "$1" "$2" >>"$MARKS"
}

this_hostname() { cat /proc/sys/kernel/hostname 2>/dev/null; }

flake_hosts() { grep -oE '^    nixosConfigurations\."[^"]+"' "$FLAKE/flake.nix" 2>/dev/null | sed -E 's/.*"([^"]+)"/\1/'; }
pc_hosts()    { flake_hosts | grep -vx server; }

# The host's block in flake.nix, from its first line to its closing "    };".
host_block() {
    awk -v start="    nixosConfigurations.\"$1\" =" '
        index($0, start) == 1 { on = 1 }
        on { print }
        on && /^    };$/ { exit }
    ' "$FLAKE/flake.nix"
}
host_hw()  { host_block "$1" | grep -oE '\./hardware/[^ ;]+\.nix' | head -n1 | sed 's|^\./||'; }
host_has() { [[ -n $HOST ]] && host_block "$HOST" | grep -qF "./$1"; }
host_modules() { host_block "$1" | grep -oE '\./[^ ;]+\.nix' | grep -v '/hardware/' | sed 's|^\./||' | paste -sd' '; }

# <hash>-nixos-system-<hostName>-<version>; the digit stops "benji" matching
# "benji-desktop".
system_is() { [[ $(basename -- "$(readlink -f "$1" 2>/dev/null)") == *-nixos-system-"$HOST"-[0-9]* ]]; }
booted()    { [[ -n $HOST ]] && system_is /run/booted-system; }

HOST=""
resolve_host() {
    HOST=""
    local h
    if [[ -n $HOST_ARG ]]; then
        h=$HOST_ARG
    else
        h=$(mark_get host)
        [[ -n $h ]] || h=$(this_hostname)
    fi
    pc_hosts | grep -qxF -- "$h" && HOST=$h
}

# --------------------------------------------------------------- steps ---
#
# Each step has check_<id> (sets ST and MSG), help_<id> (what and why) and,
# unless it is purely manual, do_<id>. Kinds decide what Enter does:
#   auto   — the script does it
#   guide  — the script walks you through it, then checks again
#   manual — nothing to detect; Enter marks it done
#   gate   — only you can fix it outside the script; Enter checks again

declare -a STEPS=()
declare -A PHASE=() KIND=() TITLE=() SKIP_OK=() STATUS=() MSGS=() NUM=()

step() {
    STEPS+=("$1"); KIND[$1]=$2; SKIP_OK[$1]=$3; PHASE[$1]=$CUR_PHASE; TITLE[$1]=$4
}

ST="" MSG=""
st() { ST=$1; MSG=${2:-}; }

need_host() { [[ -n $HOST ]] && return 1; st wait "pick the host first"; return 0; }
need_boot() { booted && return 1; st wait "after the reboot into the new system"; return 0; }

# Step numbers of earlier "before the first build" steps that still need you.
pre_pending() {
    local id out=()
    for id in "${STEPS[@]}"; do
        [[ ${PHASE[$id]} == pre ]] || continue
        [[ ${STATUS[$id]:-} == todo || ${STATUS[$id]:-} == warn ]] && out+=("${NUM[$id]}")
    done
    local IFS=,; printf '%s' "${out[*]}"
}

# ===================================================== before the build ===
CUR_PHASE=pre

step user gate n "Logged in as benji, not root"
check_user() {
    if (( EUID == 0 )); then st todo "running as root"
    elif [[ $ME != benji ]]; then st todo "logged in as '$ME'"
    else st ok; fi
}
help_user() {
    info "The config declares one user, benji, and its paths are all /home/benji."
    info "Run this script as benji and without sudo; it asks for sudo itself."
    if (( EUID != 0 )) && [[ $ME != benji ]]; then
        info "If the installer created '$ME' instead, add benji, then log in as benji:"
        cmdline "sudo useradd -m -G wheel benji && sudo passwd benji"
        info "and clone the repo again into /home/benji/nixcfg."
    fi
}

step repo auto n "Repo cloned at ~/nixcfg and owned by you"
check_repo() {
    if [[ $SELF_REPO != "$(readlink -f "$REPO" 2>/dev/null)" ]]; then
        st todo "this copy is at $SELF_REPO"; return
    fi
    [[ -d $REPO/.git ]] || { st todo "~/nixcfg is not a git clone"; return; }
    local foreign
    foreign=$(find "$REPO" ! -user "$ME" -print -quit 2>/dev/null)
    [[ -z $foreign ]] || { st todo "owned by someone else: ${foreign#"$REPO"/}"; return; }
    st ok
}
help_repo() {
    info "Aliases, Hyprland and the scripts all expect exactly ~/nixcfg. Files owned"
    info "by root (left behind by a sudo build) make git and nix fail as benji."
}
do_repo() {
    if [[ $SELF_REPO != "$(readlink -f "$REPO" 2>/dev/null)" ]]; then
        if [[ -e $REPO ]]; then
            err "~/nixcfg already exists, so this copy can't be moved there."
            info "Look inside it, move it away, then move this copy:"
            cmdline "mv ~/nixcfg ~/nixcfg.old && mv '$SELF_REPO' ~/nixcfg"
        else
            info "Move this copy into place and run the script from there:"
            cmdline "mv '$SELF_REPO' ~/nixcfg && ~/nixcfg/scripts/setup.sh"
        fi
        return 1
    fi
    [[ -d $REPO/.git ]] || { err "Clone it instead: git clone git@github.com:Oibadaohnana/configs.git ~/nixcfg"; return 1; }
    run sudo chown -R "$ME:$(id -gn)" "$REPO" && ok "~/nixcfg belongs to $ME again."
}

step platform gate n "NixOS on x86_64 with UEFI boot"
check_platform() {
    local issues=()
    [[ -e /etc/NIXOS ]] || issues+=("not NixOS")
    [[ $(uname -m) == x86_64 ]] || issues+=("$(uname -m), not x86_64")
    [[ -d /sys/firmware/efi ]] || issues+=("booted in legacy BIOS mode")
    if (( ${#issues[@]} )); then local IFS=,; st todo "${issues[*]}"; else st ok; fi
}
help_platform() {
    info "Every host is x86_64-linux and boots with systemd-boot, which needs UEFI."
    info "On a BIOS-mode install: switch the firmware to UEFI and reinstall NixOS,"
    info "or change boot.loader in nixos/configuration.nix to GRUB."
}

step hwcompat manual y "AMD CPU and GPU (what the config assumes)"
check_hwcompat() {
    local cpu gpus probs=()
    cpu=$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
    gpus=$(cat /sys/class/drm/card*/device/vendor 2>/dev/null | sort -u | paste -sd' ')
    [[ $cpu == AuthenticAMD ]] || probs+=("CPU: ${cpu:-unknown}")
    if [[ $gpus != *0x1002* ]]; then
        case $gpus in
            *0x10de*) probs+=("GPU: NVIDIA") ;;
            *0x8086*) probs+=("GPU: Intel") ;;
            *)        probs+=("no AMD GPU found") ;;
        esac
    fi
    if (( ${#probs[@]} )); then local IFS=,; st warn "${probs[*]}"; else st ok; fi
}
help_hwcompat() {
    info "nixos/configuration.nix sets videoDrivers = [ \"amdgpu\" ] for every host."
    info "A generated hardware file picks the right CPU microcode and kvm module on"
    info "its own, but a non-AMD GPU needs that videoDrivers line changed (NVIDIA"
    info "also needs hardware.nvidia.*). Enter = understood, I'll handle it."
}

step network guide n "Internet reachable"
NET_CACHE=""
check_network() {
    if [[ -z $NET_CACHE ]]; then
        if timeout 6 bash -c ': </dev/tcp/cache.nixos.org/443' 2>/dev/null; then NET_CACHE=ok; else NET_CACHE=bad; fi
    fi
    [[ $NET_CACHE == ok ]] && st ok || st todo "cache.nixos.org unreachable"
}
help_network() {
    info "The build downloads several GB from cache.nixos.org."
    info "Wi-Fi from a terminal:"
    cmdline "nmcli device wifi connect '<SSID>' --ask"
}
do_network() { wait_enter "Connect, then press Enter to check again…"; NET_CACHE=""; }

step host auto n "This PC has a host entry in flake.nix"
check_host() {
    if [[ -n $HOST ]]; then
        local hn; hn=$(this_hostname)
        if [[ $hn == "$HOST" ]]; then st ok "$HOST"
        else st ok "$HOST (hostname stays '$hn' until the first build)"; fi
    else
        st todo "'$(this_hostname)' is not a host in nixos/flake.nix"
    fi
}
help_host() {
    info "Each PC is one nixosConfigurations entry in nixos/flake.nix plus a hardware"
    info "file with its disks. Reinstalling a PC you already have: pick its name."
    info "A new PC: the script makes both from what it detects on this machine."
}
do_host() {
    local hosts=() i choice
    mapfile -t hosts < <(pc_hosts)
    info "Which PC is this?"
    for i in "${!hosts[@]}"; do
        printf '    %s%d)%s %s  %s(%s)%s\n' "$BOLD" $((i + 1)) "$RESET" "${hosts[i]}" "$DIM" "$(host_modules "${hosts[i]}")" "$RESET"
    done
    printf '    %sn)%s a new PC\n' "$BOLD" "$RESET"
    prompt choice "Choice" || return 1
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#hosts[@]} )); then
        HOST=${hosts[choice - 1]}
        mark_set host "$HOST"
        ok "This PC is $HOST. The next step checks its hardware file against these disks."
    elif [[ ${choice,,} == n ]]; then
        new_host
    else
        warn "Nothing chosen."
        return 1
    fi
}

new_host() {
    local name hosts=() i choice tpl tpl_hw hw tmp blk backup out
    while true; do
        prompt name "Name for this PC (lowercase, e.g. benji-laptop)" || return 1
        if [[ ! $name =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then warn "Lowercase letters, digits and '-' only."; continue; fi
        if flake_hosts | grep -qxF -- "$name"; then warn "'$name' is already in flake.nix."; continue; fi
        if [[ -e $FLAKE/hardware/$name.nix ]]; then warn "hardware/$name.nix already exists."; continue; fi
        break
    done

    mapfile -t hosts < <(pc_hosts)
    info "Start from which host's module list? (you can edit flake.nix later)"
    for i in "${!hosts[@]}"; do
        printf '    %s%d)%s like %s  %s(%s)%s\n' "$BOLD" $((i + 1)) "$RESET" "${hosts[i]}" "$DIM" "$(host_modules "${hosts[i]}")" "$RESET"
    done
    prompt choice "Choice" 1 || return 1
    [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#hosts[@]} )) || { warn "Not a choice."; return 1; }
    tpl=${hosts[choice - 1]}
    tpl_hw=$(host_hw "$tpl")
    hw="$FLAKE/hardware/$name.nix"

    mkdir -p "$STATE_DIR"
    tmp=$(mktemp) blk=$(mktemp)
    info "Detecting this PC's hardware (nixos-generate-config, needs sudo)…"
    if ! sudo nixos-generate-config --show-hardware-config >"$tmp" 2>/dev/null || ! grep -q 'fileSystems\."/"' "$tmp"; then
        err "nixos-generate-config gave no usable hardware file. Is / mounted normally?"
        rm -f "$tmp" "$blk"
        return 1
    fi

    host_block "$tpl" | sed \
        -e "s|nixosConfigurations\.\"$tpl\"|nixosConfigurations.\"$name\"|" \
        -e "s|\./$tpl_hw|./hardware/$name.nix|" \
        -e "s|networking\.hostName = \"$tpl\"|networking.hostName = \"$name\"|" >"$blk"

    backup="$STATE_DIR/flake.nix.before-$name"
    cp -- "$FLAKE/flake.nix" "$backup" || { rm -f "$tmp" "$blk"; return 1; }
    install -m 644 -- "$tmp" "$hw"
    awk -v start="    nixosConfigurations.\"$tpl\" =" -v f="$blk" '
        { print }
        index($0, start) == 1 { on = 1 }
        on && /^    };$/ { while ((getline l < f) > 0) print l; on = 0 }
    ' "$backup" >"$FLAKE/flake.nix"
    rm -f "$tmp" "$blk"

    git_ add -- "nixos/hardware/$name.nix"
    out=$("${NIX[@]}" eval --raw "$FLAKE#nixosConfigurations.$name.config.networking.hostName" 2>&1)
    if [[ $(tail -n1 <<<"$out") != "$name" ]]; then
        err "The new entry doesn't evaluate; putting flake.nix back as it was:"
        tail -n 20 <<<"$out" | indent
        cp -- "$backup" "$FLAKE/flake.nix"
        git_ rm -q --cached -- "nixos/hardware/$name.nix" >/dev/null 2>&1
        rm -f -- "$hw"
        return 1
    fi

    HOST=$name
    mark_set host "$HOST"
    ok "Wrote nixos/hardware/$name.nix from this PC's hardware (git-added)."
    ok "Added nixosConfigurations.\"$name\" to nixos/flake.nix, copied from $tpl."
    info "${DIM}Old flake.nix kept at $backup${RESET}"
    info "Hand tweaks in hardware/$(basename "$tpl_hw") (kernel params, extra disks) were"
    info "not copied; the new file is plain nixos-generate-config output."
    info "Commit both once this PC works."
}

step disks auto n "Disk UUIDs in the hardware file match this PC"
# "<mountpoint> <uuid> <nofail 0|1>" for every by-uuid fileSystems entry.
fs_entries() {
    awk '
        /fileSystems\."[^"]+"/ {
            match($0, /fileSystems\."[^"]+"/); m = substr($0, RSTART + 13, RLENGTH - 14)
            u = ""; nf = 0; on = 1
        }
        on && /by-uuid\// { match($0, /by-uuid\/[^"]+/); u = substr($0, RSTART + 8, RLENGTH - 8) }
        on && /"nofail"/ { nf = 1 }
        on && /^[[:space:]]*};/ { if (u != "") print m, u, nf; on = 0 }
    ' "$1"
}
check_disks() {
    need_host && return
    local hw m u nf fix=0 bad=0 soft=()
    hw=$(host_hw "$HOST")
    [[ -f $FLAKE/$hw ]] || { st todo "nixos/$hw is missing"; return; }
    while read -r m u nf; do
        [[ -e /dev/disk/by-uuid/$u ]] && continue
        if [[ -n $(findmnt -rno UUID --mountpoint "$m" 2>/dev/null) ]]; then ((fix++))
        elif [[ $nf == 1 ]]; then soft+=("$m")
        else ((bad++)); fi
    done < <(fs_entries "$FLAKE/$hw")
    if (( fix + bad )); then st todo "$((fix + bad)) mount(s) point at disks this PC doesn't have"
    elif (( ${#soft[@]} )); then st ok "${soft[*]} not attached right now (nofail, boots anyway)"
    else st ok "nixos/$hw"; fi
}
help_disks() {
    info "The hardware file mounts / and /boot by UUID. A reinstall formats them and"
    info "the UUIDs change; a stale one boots into emergency mode."
}
do_disks() {
    local hw m u nf cur changed=0
    hw=$(host_hw "$HOST")
    while read -r m u nf; do
        [[ -e /dev/disk/by-uuid/$u ]] && continue
        cur=$(findmnt -rno UUID --mountpoint "$m" 2>/dev/null)
        if [[ -n $cur ]]; then
            info "$m: ${DIM}$u${RESET} → $cur  (what is mounted there now)"
            if ask "Update $m in nixos/$hw?" y; then
                sed -i "s|by-uuid/$u\"|by-uuid/$cur\"|" "$FLAKE/$hw" && ok "$m now uses $cur" && changed=1
            fi
        elif [[ $nf == 1 ]]; then
            warn "$m ($u) isn't attached. It has nofail, so booting doesn't wait for it."
        else
            err "$m ($u) isn't on this PC and nothing is mounted at $m to take it from."
            info "Find the right UUID and edit nixos/$hw by hand:"
            cmdline "lsblk -f"
        fi
    done < <(fs_entries "$FLAKE/$hw")
    (( changed )) && info "Commit this change once the PC boots."
    return 0
}

step tracked auto n "New files are tracked by git"
check_tracked() {
    local u
    u=$(git_ status --porcelain --untracked-files=all -- nixos shells 2>/dev/null | sed -n 's/^?? //p')
    if [[ -z $u ]]; then st ok; else st todo "$(wc -l <<<"$u") untracked — flakes can't see them"; fi
}
help_tracked() {
    info "A flake only sees files git knows about. An untracked .nix file makes the"
    info "build fail with \"path does not exist\", even though it is right there."
}
do_tracked() {
    local f files=()
    mapfile -t files < <(git_ status --porcelain --untracked-files=all -- nixos shells | sed -n 's/^?? //p')
    for f in "${files[@]}"; do info "  $f"; done
    ask "git add these?" y || return 1
    git_ add -- "${files[@]}" && ok "Added ${#files[@]} file(s) to git (not committed)."
}

step links auto y "Dotfiles symlinked (scripts/symlinks.sh)"
link_entries() { sed -nE 's/^make_symlink[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+).*/\1 \2/p' "$REPO/scripts/symlinks.sh"; }
link_state() {
    local t="$REPO/$1" n="$HOME/$2"
    if [[ -L $n ]]; then
        [[ $(readlink -f -- "$n") == "$(readlink -f -- "$t")" ]] && echo ok || echo other
    elif [[ -e $n ]]; then echo file
    else echo missing; fi
}
check_links() {
    local f t miss=0 conf=0
    while read -r f t; do
        case $(link_state "$f" "$t") in
            ok)   ;;
            file) ((conf++)) ;;
            *)    ((miss++)) ;;
        esac
    done < <(link_entries)
    if (( miss + conf == 0 )); then st ok "$(link_entries | wc -l) links"
    elif (( conf )); then st todo "$miss missing, $conf blocked by an existing file"
    else st todo "$miss missing"; fi
}
help_links() {
    info "Links the repo's dotfiles into ~ (zshrc with all aliases, ssh config,"
    info "Hyprland, waybar, mako, kitty, micro, …). Do it before the first Hyprland"
    info "login, or Hyprland writes its own default config into the way."
}
do_links() {
    local f t n dest conflicts=()
    while read -r f t; do
        [[ $(link_state "$f" "$t") == file ]] && conflicts+=("$t")
    done < <(link_entries)
    if (( ${#conflicts[@]} )); then
        warn "These are real files, so symlinks.sh would leave them alone:"
        for t in "${conflicts[@]}"; do info "  ~/$t"; done
        if ask "Move them aside (to <name>.pre-nixcfg) and link the repo's versions?" y; then
            for t in "${conflicts[@]}"; do
                n="$HOME/$t" dest="$HOME/$t.pre-nixcfg"
                [[ -e $dest ]] && dest="$dest.$(date +%s)"
                mv -- "$n" "$dest" && ok "moved ~/$t → ~/${dest#"$HOME"/}"
            done
        fi
    fi
    info "Running scripts/symlinks.sh:"
    bash "$REPO/scripts/symlinks.sh" 2>&1 | indent
    report_links
}
report_links() {
    local f t s bad=0
    info ""
    info "${BOLD}Result:${RESET}"
    while read -r f t; do
        s=$(link_state "$f" "$t")
        case $s in
            ok)    ok "~/$t" ;;
            file)  err "~/$t — a real file is in the way"; ((bad++)) ;;
            other) err "~/$t — links somewhere else"; ((bad++)) ;;
            *)     err "~/$t — missing"; ((bad++)) ;;
        esac
    done < <(link_entries)
    (( bad == 0 ))
}

step eval auto n "Config evaluates without errors"
config_hash() {
    find "$FLAKE" "$REPO/shells" "$REPO/configs/menus" -path "$FLAKE/result" -prune -o -type f -print0 2>/dev/null \
        | sort -z | xargs -0 sha1sum 2>/dev/null | sha1sum | cut -c1-16
}
check_eval() {
    need_host && return
    if system_is /nix/var/nix/profiles/system; then st ok "already built once"; return; fi
    [[ $(mark_get eval) == "$HOST:$(config_hash)" ]] && st ok || st todo "not checked since the last change"
}
help_eval() {
    info "Evaluates nixosConfigurations.$HOST without building anything, so config"
    info "errors show up now and not 20 minutes into the build. Changes nothing."
}
do_eval() {
    local out
    info "Evaluating… (the first time downloads nixpkgs, ~1 min)"
    out=$("${NIX[@]}" eval --raw "$FLAKE#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" 2>&1)
    if grep -qE '^/nix/store/[^ ]+\.drv$' <<<"$out"; then
        ok "nixosConfigurations.$HOST evaluates."
        mark_set eval "$HOST:$(config_hash)"
    else
        err "Evaluation failed. The first 'error:' line is usually the one that matters:"
        tail -n 40 <<<"$out" | indent
        return 1
    fi
}

# ========================================================== first build ===
CUR_PHASE=build

step build auto n "System built from this repo"
check_build() {
    need_host && return
    if system_is /nix/var/nix/profiles/system; then st ok "$HOST is the default boot entry"; return; fi
    local p; p=$(pre_pending)
    [[ -z $p ]] || { st wait "finish step(s) $p first"; return; }
    st todo "nixos-rebuild for $HOST"
}
help_build() {
    info "Builds the whole system for $HOST. The first build downloads a lot and"
    info "compiles a few things from source (Hyprland, agents-ui): 20+ minutes."
    info "  boot   — becomes the default boot entry, used after a reboot (safest:"
    info "           nothing changes under the running desktop)"
    info "  switch — also activates it right now"
}
do_build() {
    local mode
    prompt mode "boot or switch?" boot || return 1
    [[ ${mode,,} == s* ]] && mode=switch || mode=boot
    if run sudo nixos-rebuild "$mode" --flake "$FLAKE#$HOST" --option experimental-features "nix-command flakes"; then
        ok "Built $HOST ($mode)."
    else
        info "Look for the first 'error:' above. Usual causes: an untracked file"
        info "(step ${NUM[tracked]}), a stale disk UUID (step ${NUM[disks]}), no space left on /."
        return 1
    fi
}

step reboot auto n "Booted into the new system"
check_reboot() {
    [[ ${STATUS[build]:-} == ok ]] || { st wait "build first"; return; }
    system_is /run/booted-system && st ok || st todo "still running the installer's system"
}
help_reboot() {
    info "New kernel, groups, login shell and display manager only apply after a"
    info "reboot. Then log in as benji and run this again:"
    cmdline "~/nixcfg/scripts/setup.sh"
}
do_reboot() { ask "Reboot now?" n && run systemctl reboot; }

# ===================================================== after first boot ===
CUR_PHASE=after

step sshkey auto n "SSH key ~/.ssh/id_ed25519"
check_sshkey() { [[ -f $HOME/.ssh/id_ed25519 && -f $HOME/.ssh/id_ed25519.pub ]] && st ok || st todo "no key yet"; }
help_sshkey() {
    info "One key for GitHub and the server. configs/sshconfig offers only this"
    info "file to the server, so it has to be exactly ~/.ssh/id_ed25519."
}
do_sshkey() {
    local email
    email=$(git_ config --global user.email 2>/dev/null)
    [[ -n $email ]] || email="benji@$(this_hostname)"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    info "ssh-keygen asks for a passphrase (Enter for none)."
    run ssh-keygen -t ed25519 -C "$email" -f "$HOME/.ssh/id_ed25519" && ok "Created ~/.ssh/id_ed25519."
}

step github guide n "GitHub accepts this PC's key"
GH_CACHE=""
check_github() {
    [[ -f $HOME/.ssh/id_ed25519.pub ]] || { st wait "needs the SSH key"; return; }
    if [[ -z $GH_CACHE ]]; then
        local out
        out=$(timeout 15 ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 </dev/null)
        [[ $out == *"successfully authenticated"* ]] && GH_CACHE=ok || GH_CACHE=bad
    fi
    [[ $GH_CACHE == ok ]] && st ok || st todo "GitHub doesn't know this key"
}
help_github() {
    info "Needed for git pull/push of this repo and for every private flake input"
    info "(the server's games and apps: *update, ship, bsyss)."
}
do_github() {
    info "Add this public key on GitHub:"
    cmdline "$(cat "$HOME/.ssh/id_ed25519.pub")"
    info "at https://github.com/settings/ssh/new  (title: $(this_hostname))"
    wait_enter "Press Enter once it's added…"
    GH_CACHE=""
}

step remote auto n "Repo pushes over SSH"
check_remote() {
    local url; url=$(git_ remote get-url origin 2>/dev/null)
    case $url in
        "")                  st warn "no 'origin' remote" ;;
        https://github.com/*)
            [[ ${STATUS[github]:-} == ok ]] || { st wait "needs GitHub access first"; return; }
            st todo "origin is HTTPS, pushes would ask for a token" ;;
        *)                   st ok "$url" ;;
    esac
}
help_remote() { info "A clone made over HTTPS can't push with the SSH key."; }
do_remote() {
    local url path
    url=$(git_ remote get-url origin 2>/dev/null)
    [[ -n $url ]] || { run git_ remote add origin git@github.com:Oibadaohnana/configs.git; return; }
    path=${url#https://github.com/}; path=${path%/}; path=${path%.git}
    run git_ remote set-url origin "git@github.com:$path.git" && ok "origin is now git@github.com:$path.git"
}

step gitid auto n "git name and email set"
check_gitid() {
    local n e missing=()
    n=$(git_ config --global user.name 2>/dev/null)
    e=$(git_ config --global user.email 2>/dev/null)
    [[ -n $n ]] || missing+=(name)
    [[ -n $e ]] || missing+=(email)
    if (( ${#missing[@]} == 0 )); then st ok "$n <$e>"
    else st todo "no ${missing[*]}"; fi
}
help_gitid() { info "~/.gitconfig isn't in the repo; commits need a name and an email."; }
do_gitid() {
    local n e
    prompt n "Name"  "$(git_ config --global user.name 2>/dev/null)" || return 1
    prompt e "Email" "$(git_ config --global user.email 2>/dev/null)" || return 1
    [[ -n $n && -n $e ]] || { warn "Both are needed."; return 1; }
    git_ config --global user.name "$n" && git_ config --global user.email "$e" && ok "git uses $n <$e>"
}

step netrc auto y "Nextcloud login for ncsync (~/.netrc)"
check_netrc() {
    need_boot && return
    grep -qE "^[[:space:]]*machine[[:space:]]+$NC_HOST([[:space:]]|$)" "$HOME/.netrc" 2>/dev/null \
        && st ok || st todo "no $NC_HOST entry"
}
help_netrc() {
    info "ncsync reads its login from ~/.netrc. It gets an app password of its own,"
    info "so the real password is never stored and this PC can be revoked alone:"
    info "  1. https://$NC_HOST → log in as $NC_USER"
    info "  2. avatar (top right) → Personal settings → Security"
    info "  3. Devices & sessions: name it '$(this_hostname)' → Create new app password"
}
do_netrc() {
    local pw code tmp
    printf '  App password (not shown): '
    read -rs pw <"$TTY"; echo
    [[ -n $pw ]] || { warn "Nothing entered."; return 1; }
    if command -v curl >/dev/null; then
        code=$(printf 'user = "%s:%s"\n' "$NC_USER" "$pw" | curl -sK - -o /dev/null -w '%{http_code}' \
            -X PROPFIND -H 'Depth: 0' "https://$NC_HOST/remote.php/dav/files/$NC_USER/")
        case $code in
            207) ok "Nextcloud accepts it." ;;
            401) err "Nextcloud rejects it. Copy the app password again."; return 1 ;;
            *)   warn "Couldn't check it (HTTP ${code:-none}), saving anyway." ;;
        esac
    fi
    tmp=$(mktemp)
    [[ -f $HOME/.netrc ]] && awk -v h="$NC_HOST" '$1 == "machine" { skip = ($2 == h) } !skip' "$HOME/.netrc" >"$tmp"
    printf 'machine %s login %s password %s\n' "$NC_HOST" "$NC_USER" "$pw" >>"$tmp"
    install -m 600 -- "$tmp" "$HOME/.netrc" && rm -f "$tmp" && ok "Saved to ~/.netrc (only you can read it)."
}

step onedrive auto y "~/OneDrive synced with Nextcloud"
check_onedrive() {
    need_boot && return
    [[ ${STATUS[netrc]:-} == ok ]] || { st wait "needs the Nextcloud login"; return; }
    compgen -G "$NC_DIR/.sync_*.db" >/dev/null && st ok || st todo "never synced on this PC"
}
help_onedrive() { info "The first ncsync downloads the OneDrive folder from Nextcloud (several GB)."; }
do_onedrive() {
    local cmd dest
    cmd=$(sed -nE 's/^alias ncsync="(.*)"$/\1/p' "$REPO/configs/zshrc")
    [[ -n $cmd ]] || { err "No ncsync alias in configs/zshrc."; return 1; }
    command -v nextcloudcmd >/dev/null || { err "nextcloudcmd isn't installed (nextcloud-client)."; return 1; }
    if [[ -d $NC_DIR && -n $(ls -A "$NC_DIR" 2>/dev/null) ]] && ! compgen -G "$NC_DIR/.sync_*.db" >/dev/null; then
        warn "~/OneDrive already has files but has never been synced here. Anything"
        warn "that differs from the server would turn into conflict copies."
        dest="$NC_DIR.old-$(date +%F)"
        [[ -e $dest ]] && dest="$dest-$(date +%s)"
        if ask "Move it to ~/${dest#"$HOME"/} and download a fresh copy?" y; then
            mv -- "$NC_DIR" "$dest" && ok "Moved to ~/${dest#"$HOME"/}. Delete it once you've checked it."
        fi
    fi
    mkdir -p "$NC_DIR"
    run bash -c "$cmd" && ok "~/OneDrive is synced. From now on: ncsync"
}

# ============================================================ optional ===
# Nothing breaks without these, and the walk-through doesn't stop at them.
# The ones that can be detected tick themselves off as the PC gets used;
# the rest wait for a "done" mark.
CUR_PHASE=opt

step links2 auto y "symlinks.sh re-run on the new system"
check_links2() {
    need_boot && return
    [[ $(mark_get links_after_boot) == done ]] && st ok || st todo "dconf and the KDE menu cache only exist now"
}
help_links2() {
    info "symlinks.sh also sets blueman's tray setting (dconf) and rebuilds KDE's"
    info "app index. Those tools weren't installed before the build."
}
do_links2() { do_links && mark_set links_after_boot done; }

step serverkey guide y "Server lets this PC in (bsyss, ship, share)"
check_serverkey() {
    local key
    key=$(awk '{ print $2 }' "$HOME/.ssh/id_ed25519.pub" 2>/dev/null)
    [[ -n $key ]] || { st wait "needs the SSH key"; return; }
    if ! grep -qF -- "$key" "$FLAKE/server_configuration.nix"; then
        st todo "the server only knows the desktop and framework keys"
    elif ! git_ show HEAD:nixos/server_configuration.nix 2>/dev/null | grep -qF -- "$key"; then
        st todo "key added, not committed and deployed yet"
    elif [[ $(mark_get serverkey) == done ]]; then
        st ok
    else
        st todo "key is in the config, deployed?"
    fi
}
help_serverkey() {
    info "The server takes keys only (no passwords) from authorizedKeys in"
    info "nixos/server_configuration.nix, and only a PC that already has access can"
    info "deploy a new one."
    warn "Don't ssh to the server from here before that: one failed login bans your"
    warn "home IP for an hour, which locks out your other PCs too."
}
do_serverkey() {
    local pub key file="$FLAKE/server_configuration.nix" tmp
    pub=$(cat "$HOME/.ssh/id_ed25519.pub")
    key=$(awk '{ print $2 }' <<<"$pub")
    if ! grep -qF -- "$key" "$file"; then
        ask "Add this PC's key to authorizedKeys in server_configuration.nix?" y || return 1
        tmp=$(mktemp)
        awk -v line="      \"$pub\"" '
            /openssh\.authorizedKeys\.keys = \[/ { inlist = 1 }
            inlist && /^[[:space:]]*\];/ { print line; inlist = 0; added = 1 }
            { print }
            END { exit added ? 0 : 3 }
        ' "$file" >"$tmp"
        if [[ $? -ne 0 ]] || ! nix-instantiate --parse "$tmp" >/dev/null 2>&1; then
            err "Couldn't add it cleanly; server_configuration.nix is unchanged."
            rm -f "$tmp"; return 1
        fi
        cat -- "$tmp" >"$file" && rm -f "$tmp"
        ok "Added the key to nixos/server_configuration.nix:"
        git_ --no-pager diff -- nixos/server_configuration.nix | indent
    fi
    if ! git_ show HEAD:nixos/server_configuration.nix 2>/dev/null | grep -qF -- "$key"; then
        if [[ ${STATUS[github]:-} == ok ]] && ask "Commit just this file?" y; then
            git_ commit -q -m "server: allow $(this_hostname)'s ssh key" -- nixos/server_configuration.nix && ok "Committed."
            local ahead
            ahead=$(git_ rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
            if [[ $ahead == 1 ]]; then
                ask "Push it?" y && run git_ push
            else
                warn "main is $ahead commit(s) ahead of GitHub; a push sends all of them."
                ask "Push all $ahead?" n && run git_ push
            fi
        else
            info "Commit and push nixos/server_configuration.nix yourself."
        fi
    fi
    info "Then, on a PC that already gets into the server:"
    cmdline "cd ~/nixcfg && git pull && bsyss"
    if ask "Is it deployed?" n; then mark_set serverkey done; ok "Marked as deployed."; fi
}

step claude guide y "Claude Code logged in"
check_claude() {
    need_boot && return
    [[ -s ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json ]] && st ok || st todo "not logged in"
}
help_claude() { info "agents and 'agents usage' need claude to be logged in once."; }
do_claude() {
    info "In another terminal, run claude and log in:"
    cmdline "claude"
    wait_enter "Press Enter when done…"
}

step sops guide y "sops age key (only to edit server secrets)"
check_sops() { [[ -s $HOME/.config/sops/age/keys.txt ]] && st ok || st todo "not on this PC"; }
help_sops() {
    info "Decrypting nixos/server/secrets/*.yaml needs the age key that lives on the"
    info "framework. Building, deploying and share-password.sh don't. Skip unless"
    info "this PC should edit secrets."
}
do_sops() {
    info "Copy it from the framework (USB stick, or sshon here and scp from there):"
    cmdline "mkdir -p ~/.config/sops/age"
    cmdline "scp ~/.config/sops/age/keys.txt benji@$(this_hostname):.config/sops/age/   # on the framework"
    cmdline "chmod 600 ~/.config/sops/age/keys.txt"
    wait_enter "Press Enter once it's there…"
}

step rustup auto y "Rust toolchain for nxsh (rustup default stable)"
check_rustup() {
    need_boot && return
    [[ -n $(ls -A "$HOME/.rustup/toolchains" 2>/dev/null) ]] && st ok || st todo "no toolchain installed"
}
help_rustup() { info "shells/shell.nix brings rustup, which has no toolchain until told to."; }
do_rustup() { run nix-shell "$REPO/shells" --run 'rustup default stable'; }

step monitors manual y "Hyprland monitor rules fit this PC"
check_monitors() { need_boot && return; st todo; }
help_monitors() {
    info "configs/hyprland.lua names the desktop's outputs (DP-3, HDMI-A-1). The"
    info "framework's rules are there commented out. Unknown screens still come up"
    info "at their preferred mode through the catch-all rule, so this is polish."
    info "See the names with:"
    cmdline "hyprctl monitors"
    info "Close wdisplays before reloading; while it is open, rule changes are ignored."
}

step plasmamask auto y "Plasma: stray session units masked"
check_plasmamask() {
    host_has plasma.nix || { st na; return; }
    need_boot && return
    local d="$HOME/.config/systemd/user"
    [[ $(readlink "$d/plasma-workspace@.service") == /dev/null && $(readlink "$d/ksmserver-logout-greeter.service") == /dev/null ]] \
        && st ok || st todo
}
help_plasmamask() { info "Masks plasma-workspace@ and ksmserver-logout-greeter, as on the framework."; }
do_plasmamask() { run systemctl --user mask plasma-workspace@.service ksmserver-logout-greeter.service; }

step plasmakeys manual y "Plasma: shortcuts, keyboard layouts, desktops"
check_plasmakeys() { host_has plasma.nix || { st na; return; }; need_boot && return; st todo; }
help_plasmakeys() {
    info "In System Settings, by hand:"
    info "  • Keyboard → Shortcuts → Import: ~/nixcfg/configs/plasma_shortcut_config.kksrc"
    info "  • Keyboard → Layouts: 1st US, 2nd German; switch with Right Alt (while pressed)"
    info "  • Window Management → Virtual Desktops: add 1|2|3|…"
}

step ableton guide y "Ableton Live 10 installed (Wine)"
check_ableton() {
    host_has ableton.nix || { st na; return; }
    need_boot && return
    compgen -G "$HOME/.wine-ableton/drive_c/ProgramData/Ableton/Live 10*/Program" >/dev/null && st ok || st todo "not installed"
}
help_ableton() {
    info "Live runs in its own Wine prefix. The launcher hides the Z: drive, so"
    info "Wine can't see /home: the installer (and later samples, projects) have to"
    info "be inside ~/.wine-ableton/drive_c."
}
do_ableton() {
    info "1. Create the prefix (Wine audio, WineASIO):"
    cmdline "ableton setup"
    info "2. Copy the installer into it, then install from there:"
    cmdline "cp <installer.exe> ~/.wine-ableton/drive_c/"
    cmdline "ableton install ~/.wine-ableton/drive_c/<installer.exe>"
    info "3. Start it with 'ableton' and activate Live in the browser."
    wait_enter "Press Enter when Live is installed…"
}

step bluetooth manual y "Bluetooth devices paired"
check_bluetooth() {
    need_boot && return
    local n
    n=$(timeout 3 bluetoothctl devices Paired 2>/dev/null | grep -c '^Device')
    (( n > 0 )) && st ok "$n paired" || st todo
}
help_bluetooth() {
    info "Pair each device once with blueman-manager (Super+F3). Trusting happens"
    info "automatically. Headset mic is off by design; turn it on per call with"
    info "wpctl set-profile <id> headset-head-unit."
}

step printer manual y "Printer added"
check_printer() {
    need_boot && return
    local p
    p=$(timeout 3 lpstat -e 2>/dev/null | paste -sd' ')
    [[ -n $p ]] && st ok "$p" || st todo
}
help_printer() {
    info "CUPS and hplip are installed; the printer itself is added by hand:"
    cmdline "hp-setup        # or http://localhost:631"
}

step steam manual y "Steam logged in, DayZ set up"
check_steam() {
    need_boot && return
    grep -qs AccountName "$HOME/.local/share/Steam/config/loginusers.vdf" || { st todo; return; }
    [[ -s $HOME/.config/dayz/name ]] && st ok || st ok "logged in; DayZ not joined yet"
}
help_steam() {
    info "Log in to Steam. For DayZ (pkgs/dayz/README.md): enable Proton for it,"
    info "launch options '%command%' (or 'gamemoderun %command%'), and tick"
    info "\"Always use this option → Run DayZ Client\". 'dayz' asks for the player name"
    info "on the first join."
}

step logins manual y "App logins"
check_logins() { need_boot && return; st todo; }
help_logins() { info "Firefox sync, Spotify, Telegram, Signal, Discord, Thunderbird, Mumble."; }

# ----------------------------------------------------------- the list ---

declare -A PHASE_NAME=(
    [pre]="Before the first build"
    [build]="First build"
    [after]="After the first boot"
    [opt]="Optional — ticks itself off as you use the PC"
)

symbol() {
    case $1 in
        ok)   printf '%s✓%s' "$GREEN" "$RESET" ;;
        todo) printf '%s✗%s' "$RED" "$RESET" ;;
        warn) printf '%s!%s' "$YELLOW" "$RESET" ;;
        skip) printf '%s–%s' "$DIM" "$RESET" ;;
        *)    printf '%s·%s' "$DIM" "$RESET" ;;
    esac
}

evaluate_all() {
    local id n=0 m
    resolve_host
    for id in "${STEPS[@]}"; do
        ST=todo MSG=""
        "check_$id"
        if [[ $ST != ok && $ST != na && $ST != wait ]]; then
            m=$(mark_get "$id")
            if [[ $m == skip ]]; then ST=skip
            elif [[ $m == done && ${KIND[$id]} == manual ]]; then ST=ok; MSG=""; fi
        fi
        STATUS[$id]=$ST MSGS[$id]=$MSG
        [[ $ST == na ]] || NUM[$id]=$((++n))
    done
}

# render [current-step-id] — the current step gets an arrow and a highlight.
render() {
    local cur=${1:-} id phase="" color lead sym
    printf '\n%s%s nixcfg setup %s  host: %s%s%s\n' "$BOLD" "$BLUE" "$RESET" "$BOLD" "${HOST:-?}" "$RESET"
    for id in "${STEPS[@]}"; do
        [[ ${STATUS[$id]} == na ]] && continue
        if [[ ${PHASE[$id]} != "$phase" ]]; then
            phase=${PHASE[$id]}
            printf '\n %s%s%s\n' "$BOLD" "${PHASE_NAME[$phase]}" "$RESET"
        fi
        color="" lead="  "
        [[ ${STATUS[$id]} == wait || ${STATUS[$id]} == skip ]] && color=$DIM
        [[ $id == "$cur" ]] && color=$BOLD$CYAN lead="$BOLD$CYAN▶$RESET "
        sym=$(symbol "${STATUS[$id]}")
        [[ $phase == opt && ${STATUS[$id]} == todo ]] && sym="$DIM○$RESET"
        printf '%s%s %s%2d  %s%s' "$lead" "$sym" "$color" "${NUM[$id]}" "${TITLE[$id]}" "$RESET"
        [[ -n ${MSGS[$id]} ]] && printf '  %s— %s%s' "$DIM" "${MSGS[$id]}" "$RESET"
        [[ $id == "$cur" ]] && printf '  %s◀ you are here%s' "$BOLD$CYAN" "$RESET"
        printf '\n'
    done
    printf '\n  %s✓ done  ✗ to do  ! check  ○ optional  – skipped  · later  ▶ current step%s\n' "$DIM" "$RESET"
}

first_open() {
    local id
    for id in "${STEPS[@]}"; do
        [[ ${PHASE[$id]} == opt ]] && continue
        [[ ${STATUS[$id]} == todo || ${STATUS[$id]} == warn ]] && { printf '%s' "$id"; return; }
    done
}

id_for_num() {
    local id
    for id in "${STEPS[@]}"; do
        [[ ${STATUS[$id]} != na && ${NUM[$id]} == "$1" ]] && { printf '%s' "$id"; return; }
    done
}

detail() {
    local id=$1
    printf '\n%s──────────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"
    printf ' %sStep %d · %s%s\n' "$BOLD" "${NUM[$id]}" "${TITLE[$id]}" "$RESET"
    [[ -n ${MSGS[$id]} ]] && printf ' %s%s%s\n' "$YELLOW" "${MSGS[$id]}" "$RESET"
    [[ ${PHASE[$id]} == opt ]] && printf ' %sOptional — nothing breaks without it.%s\n' "$DIM" "$RESET"
    printf '\n'
    declare -F "help_$id" >/dev/null && "help_$id"
    printf '\n'
}

act() {
    local id=$1 rc=0
    case ${KIND[$id]} in
        auto|guide) "do_$id"; rc=$? ;;
        manual)     mark_set "$id" done; ok "Marked done." ;;
        gate)       NET_CACHE=""; GH_CACHE="" ;;
    esac
    (( rc == 0 )) || warn "That didn't finish; the step stays open."
}

finish() {
    local id open=() opt=()
    for id in "${STEPS[@]}"; do
        if [[ ${PHASE[$id]} == opt ]]; then
            [[ ${STATUS[$id]} == todo ]] && opt+=("${NUM[$id]}")
        elif [[ ${STATUS[$id]} == wait ]]; then
            open+=("${NUM[$id]}")
        fi
    done
    if (( ${#open[@]} )); then
        info "Nothing more to do right now. Steps ${open[*]} open up after the next stage;"
        info "run ~/nixcfg/scripts/setup.sh again then."
        return
    fi
    ok "All important steps are done. Commit any changes in ~/nixcfg (gitgo)."
    if (( ${#opt[@]} )); then
        info "Optional steps still open: ${opt[*]}. Most tick themselves off as you"
        info "use the PC; type a number below to do one now."
    fi
}

# --------------------------------------------------------------- cli ---

while (( $# )); do
    case $1 in
        --list)  LIST_ONLY=1; shift ;;
        --host)  HOST_ARG=${2:-}; shift 2 || { err "--host needs a name"; exit 1; } ;;
        --reset) DO_RESET=1; shift ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0 ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -f $FLAKE/flake.nix ]]; then
    err "No ~/nixcfg/nixos/flake.nix. Clone the repo first:"
    cmdline "nix-shell -p git --run 'git clone git@github.com:Oibadaohnana/configs.git ~/nixcfg'"
    exit 1
fi

if [[ -n $HOST_ARG ]] && ! pc_hosts | grep -qxF -- "$HOST_ARG"; then
    err "'$HOST_ARG' isn't a PC host in nixos/flake.nix ($(pc_hosts | paste -sd' '))."
    exit 1
fi

if (( DO_RESET )); then
    rm -f -- "$MARKS" && ok "Forgot all marks and the chosen host."
fi

trap 'printf "\n"; info "Stopped. Run ~/nixcfg/scripts/setup.sh again to continue."; exit 130' INT

have_tty || LIST_ONLY=1

if (( LIST_ONLY )); then
    evaluate_all
    render "$(first_open)"
    exit 0
fi

FOCUS=""
while true; do
    evaluate_all
    id=${FOCUS:-$(first_open)}
    FOCUS=""
    render "$id"
    if [[ -z $id ]]; then
        printf '\n'
        finish
        printf '  %sEnter = quit · <number> = go to step%s\n  > ' "$DIM" "$RESET"
        read -r choice <"$TTY" || break
        if [[ $choice =~ ^[0-9]+$ ]] && target=$(id_for_num "$choice") && [[ -n $target ]]; then
            mark_del "$target"
            FOCUS=$target
            continue
        fi
        break
    fi

    detail "$id"
    case ${KIND[$id]} in
        auto)   hint="Enter = do it" ;;
        guide)  hint="Enter = walk me through it" ;;
        manual) hint="Enter = mark as done" ;;
        gate)   hint="Enter = check again" ;;
    esac
    [[ ${SKIP_OK[$id]} == y ]] && hint+=" · s = skip"
    hint+=" · <number> = go to step · q = quit"
    printf '  %s%s%s\n  > ' "$DIM" "$hint" "$RESET"
    read -r choice <"$TTY" || break

    case ${choice,,} in
        "")
            printf '\n'
            act "$id"
            [[ ${KIND[$id]} == gate ]] || wait_enter "Press Enter to go back to the list…"
            ;;
        s)
            if [[ ${SKIP_OK[$id]} == y ]]; then
                mark_set "$id" skip
                info "Skipped. Pick it again any time by its number."
            else
                warn "This one can't be skipped: the build needs it."
                wait_enter
            fi
            ;;
        q)
            info "Run ~/nixcfg/scripts/setup.sh again to continue."
            break
            ;;
        *)
            if [[ $choice =~ ^[0-9]+$ ]] && target=$(id_for_num "$choice") && [[ -n $target ]]; then
                mark_del "$target"
                FOCUS=$target
            else
                warn "Unknown choice."
            fi
            ;;
    esac
done
