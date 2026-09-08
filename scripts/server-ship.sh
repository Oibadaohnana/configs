#!/usr/bin/env bash
#
# server-ship.sh — one run from local work to a deployed server.
#
#   1. gitgo   — add / commit / push every git repo under the root
#   2. *update — bump each private flake input whose branch has moved
#                (bobbyupdate, wormsupdate, todoupdate, makinglistupdate)
#   3. bsyssl  — build here, copy the closure over, switch the server
#
# The inputs are read out of flake.lock, so a new game repo is picked up
# without touching this script.
#
# Usage: ./server-ship.sh [--root DIR] [--dry-run] [--yes]
#                         [--no-git] [--no-update] [--no-deploy]

set -uo pipefail

NIXCFG="${NIXCFG:-$HOME/nixcfg}"
FLAKE_DIR="$NIXCFG/nixos"
GITGO="$NIXCFG/scripts/git-batch-push.sh"
TARGET="${SERVER_HOST:-benji@45.129.182.102}"
SSH_KEY="${GIT_BATCH_SSH_KEY:-$HOME/.ssh/id_ed25519}"
ROOT="$PWD"                                    # gitgo alias passes --root "$PWD"
DRY_RUN=0 ASSUME_YES=0
DO_GIT=1 DO_UPDATE=1 DO_DEPLOY=1

# ---------------------------------------------------------------- ui ---

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
    YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

info()  { printf '%s\n' "$*"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()   { printf '%sx%s %s\n' "$RED" "$RESET" "$*" >&2; }
ok()    { printf '%s+%s %s\n' "$GREEN" "$RESET" "$*"; }

header() {
    local rule pad=$(( 62 - ${#1} ))
    (( pad < 3 )) && pad=3
    printf -v rule '%*s' "$pad" ''
    printf '\n%s%s== %s %s%s\n' "$BOLD" "$BLUE" "$1" "${rule// /=}" "$RESET"
}

confirm() {
    local prompt="$1" default="${2:-y}" reply hint
    (( ASSUME_YES )) && return 0
    [[ $default == y ]] && hint='[Y/n]' || hint='[y/N]'
    while true; do
        read -r -p "$prompt $hint " reply </dev/tty || return 1
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  please answer y or n" ;;
        esac
    done
}

run() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
        return 0
    fi
    "$@"
}

# --------------------------------------------------------------- ssh ---

# ls-remote and the nix fetch both talk to github over ssh. Unlock once
# here so neither step stops to ask; gitgo runs its own agent for itself.
ensure_ssh_agent() {
    local state=0
    ssh-add -l >/dev/null 2>&1 || state=$?
    (( state == 0 )) && return 0
    (( state == 2 )) && { eval "$(ssh-agent -s)" >/dev/null || return 1; AGENT_STARTED=1; }
    [[ -f $SSH_KEY ]] || { warn "no key at $SSH_KEY — ssh may prompt per repo"; return 1; }
    info "${DIM}unlocking $SSH_KEY${RESET}"
    SSH_ASKPASS_REQUIRE=never ssh-add "$SSH_KEY" </dev/tty || return 1
}

AGENT_STARTED=0
cleanup() { (( AGENT_STARTED )) && ssh-agent -k >/dev/null 2>&1; }
trap cleanup EXIT

# --------------------------------------------------------------- cli ---

while (( $# )); do
    case "$1" in
        --root)      ROOT="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        --no-git)    DO_GIT=0; shift ;;
        --no-update) DO_UPDATE=0; shift ;;
        --no-deploy) DO_DEPLOY=0; shift ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0 ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

[[ -d $FLAKE_DIR ]] || { err "no flake at $FLAKE_DIR"; exit 1; }
[[ -t 0 ]] || { err "this script is interactive — run it from a terminal"; exit 1; }
(( DRY_RUN )) && warn "dry-run: nothing is pushed, bumped or deployed"

# ---------------------------------------------------------- 1. gitgo ---

if (( DO_GIT )); then
    header "gitgo — $ROOT"
    if [[ -x $GITGO ]]; then
        gitgo_args=(--root "$ROOT")
        (( DRY_RUN )) && gitgo_args+=(--dry-run)
        "$GITGO" "${gitgo_args[@]}" || warn "gitgo reported failures — carrying on"
    else
        err "not executable: $GITGO"; exit 1
    fi
fi

# --------------------------------------------------- 2. flake inputs ---

BUMPED=() UNCHANGED=() SKIPPED=()

if (( DO_UPDATE )); then
    header "flake inputs"

    # every git input in the lock: name, url, branch, pinned rev
    mapfile -t INPUTS < <(nix eval --raw --impure --expr '
      let
        lock   = builtins.fromJSON (builtins.readFile "'"$FLAKE_DIR"'/flake.lock");
        nodes  = lock.nodes;
        rootIn = nodes.root.inputs;
        nodeOf = n: let v = rootIn.${n}; in nodes.${if builtins.isList v then builtins.head v else v};
        keep   = builtins.filter (n: ((nodeOf n).locked.type or "") == "git") (builtins.attrNames rootIn);
        line   = n: let l = (nodeOf n).locked;
                    in builtins.concatStringsSep "\t" [ n l.url (l.ref or "HEAD") l.rev ];
      in builtins.concatStringsSep "\n" (map line keep)
    ' 2>/dev/null)

    if (( ${#INPUTS[@]} == 0 )); then
        warn "no git inputs found in flake.lock"
    else
        ensure_ssh_agent
        for entry in "${INPUTS[@]}"; do
            IFS=$'\t' read -r name url ref rev <<<"$entry"
            [[ -n ${name:-} ]] || continue

            remote="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | cut -f1)"
            if [[ -z $remote ]]; then
                warn "$name: cannot reach $url ($ref) — left at ${rev:0:7}"
                SKIPPED+=("$name"); continue
            fi
            if [[ $remote == "$rev" ]]; then
                info "${DIM}$name: already at ${rev:0:7}${RESET}"
                UNCHANGED+=("$name"); continue
            fi

            info "$name: ${BOLD}${rev:0:7} -> ${remote:0:7}${RESET} on $ref"
            if confirm "  bump it?" y; then
                if run nix flake update "$name" --flake "$FLAKE_DIR"; then
                    ok "$name bumped"; BUMPED+=("$name")
                else
                    err "$name update failed"; SKIPPED+=("$name")
                fi
            else
                SKIPPED+=("$name")
            fi
        done
    fi

    if (( ${#BUMPED[@]} )) && ! (( DRY_RUN )); then
        warn "flake.lock changed — commit it in $NIXCFG so the server build is reproducible"
    fi
fi

# --------------------------------------------------------- 3. bsyssl ---

DEPLOY_RC=0

if (( DO_DEPLOY )); then
    header "bsyssl — build here, switch $TARGET"
    if confirm "build the server closure locally and deploy it?" y; then
        run nixos-rebuild switch \
            --flake "$FLAKE_DIR#server" \
            --target-host "$TARGET" \
            --ask-sudo-password
        DEPLOY_RC=$?
        (( DEPLOY_RC == 0 )) && ok "server switched" || err "deploy failed (rc=$DEPLOY_RC)"
    else
        warn "deploy skipped — run bsyssl when ready"
    fi
fi

# ------------------------------------------------------------ report ---

report() {
    local label="$1" color="$2"; shift 2
    (( $# )) || return 0
    local joined; printf -v joined '%s, ' "$@"
    printf '%s%-16s%s %s\n' "$color" "$label" "$RESET" "${joined%, }"
}

header "summary"
report 'bumped'    "$GREEN"  "${BUMPED[@]}"
report 'unchanged' "$DIM"    "${UNCHANGED[@]}"
report 'skipped'   "$YELLOW" "${SKIPPED[@]}"
exit "$DEPLOY_RC"
