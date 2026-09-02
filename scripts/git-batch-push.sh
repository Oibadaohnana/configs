#!/usr/bin/env bash
#
# git-batch-push.sh — walk every git repo under a root directory and
# add / commit / push them one at a time.
#
#   * commit messages carry an auto-incrementing index, counted per repo
#   * the counters live in a state file outside the repos
#   * the SSH passphrase is asked for exactly once (ssh-agent)
#
# Usage: ./git-batch-push.sh [--root DIR] [--dry-run] [--depth N]

set -uo pipefail

ROOT="${GIT_BATCH_ROOT:-$HOME/projects}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/git-batch-push"
STATE_FILE="$STATE_DIR/counters"
SSH_KEY="${GIT_BATCH_SSH_KEY:-$HOME/.ssh/id_ed25519}"
DEPTH=3
DRY_RUN=0

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

# Ask a yes/no question on the terminal. $2 = default (y|n).
confirm() {
    local prompt="$1" default="${2:-y}" reply hint
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

# ------------------------------------------------------------- state ---

counter_get() {
    [[ -f $STATE_FILE ]] || { echo 0; return; }
    awk -F'\t' -v k="$1" '$1 == k { c = $2 } END { print c + 0 }' "$STATE_FILE"
}

counter_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/.counters.XXXXXX")"
    {
        [[ -f $STATE_FILE ]] && awk -F'\t' -v k="$key" '$1 != k' "$STATE_FILE"
        printf '%s\t%s\n' "$key" "$val"
    } >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

# --------------------------------------------------------------- ssh ---

AGENT_STARTED=0

cleanup() {
    if (( AGENT_STARTED )); then
        ssh-agent -k >/dev/null 2>&1
    fi
}
trap cleanup EXIT

# Unlock the SSH key once; every later push reuses the running agent.
# Called lazily, so a run with nothing to push never asks for a passphrase.
ensure_ssh_agent() {
    local state=0
    ssh-add -l >/dev/null 2>&1 || state=$?
    (( state == 0 )) && return 0               # agent already holds a key

    if (( state == 2 )); then                  # no agent reachable -> start one
        eval "$(ssh-agent -s)" >/dev/null || { err "could not start ssh-agent"; return 1; }
        AGENT_STARTED=1
    fi

    [[ -f $SSH_KEY ]] || { warn "no key at $SSH_KEY — git will prompt per repo"; return 1; }

    # force the passphrase prompt onto this terminal instead of a GUI popup
    info "${DIM}unlocking $SSH_KEY (asked once for the whole run)${RESET}"
    SSH_ASKPASS_REQUIRE=never ssh-add "$SSH_KEY" </dev/tty || {
        err "ssh-add failed — pushes may prompt individually"
        return 1
    }
    ok "ssh key loaded"
}

# --------------------------------------------------------------- git ---

run() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
        return 0
    fi
    "$@"
}

current_branch() {
    git symbolic-ref --short HEAD 2>/dev/null || echo '(detached HEAD)'
}

push_repo() {
    local branch="$1" remote

    remote="$(git remote get-url origin 2>/dev/null)" || {
        warn "no 'origin' remote — commit stays local"
        return 2
    }

    [[ $branch == '(detached HEAD)' ]] && { warn "detached HEAD — skipping push"; return 2; }
    [[ $remote == git@* || $remote == ssh://* ]] && ensure_ssh_agent

    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        run git push
    else
        info "${DIM}no upstream set — pushing with -u${RESET}"
        run git push -u origin "$branch"
    fi
}

# --------------------------------------------------------------- cli ---

while (( $# )); do
    case "$1" in
        --root)    ROOT="$2"; shift 2 ;;
        --depth)   DEPTH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0 ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

[[ -d $ROOT ]] || { err "no such directory: $ROOT"; exit 1; }
[[ -t 0 ]] || { err "this script is interactive — run it from a terminal"; exit 1; }

mkdir -p "$STATE_DIR"

# -------------------------------------------------------------- main ---

mapfile -t REPOS < <(
    find "$ROOT" -maxdepth "$DEPTH" -type d -name .git -prune 2>/dev/null \
        | sed 's|/\.git$||' | sort
)

(( ${#REPOS[@]} )) || { warn "no git repositories found under $ROOT"; exit 0; }

info "${BOLD}Found ${#REPOS[@]} repositories under $ROOT${RESET}"
(( DRY_RUN )) && warn "dry-run: nothing will be added, committed or pushed"

declare -a COMMITTED=() PUSHED=() SKIPPED=() LOCAL_ONLY=() FAILED=()

for repo in "${REPOS[@]}"; do
    name="${repo#$ROOT/}"
    header "$name"

    cd "$repo" || { FAILED+=("$name (cannot cd)"); continue; }

    branch="$(current_branch)"
    status="$(git status --porcelain 2>/dev/null)"

    # --- unpushed commits but a clean tree -----------------------------
    if [[ -z $status ]]; then
        ahead='' ahead_label=''
        if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
            ahead="$(git log --oneline '@{upstream}..HEAD' 2>/dev/null)"
            [[ -n $ahead ]] && ahead_label="$(wc -l <<<"$ahead") commit(s) not pushed"
        elif git remote get-url origin >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
            # branch has commits but was never pushed — offer to publish it
            ahead="$(git log --oneline -5 2>/dev/null)"
            ahead_label="no upstream yet, last commits"
        fi
        if [[ -n $ahead ]]; then
            info "clean tree, but $ahead_label on ${BOLD}$branch${RESET}:"
            sed 's/^/    /' <<<"$ahead"
            if confirm "  push them?" y; then
                push_repo "$branch"; rc=$?
                case $rc in
                    0) ok "pushed"; PUSHED+=("$name") ;;
                    2) LOCAL_ONLY+=("$name") ;;
                    *) err "push failed"; FAILED+=("$name (push)") ;;
                esac
            else
                SKIPPED+=("$name")
            fi
        else
            info "${DIM}nothing to do — working tree clean, nothing ahead${RESET}"
            SKIPPED+=("$name")
        fi
        continue
    fi

    # --- there are changes to add --------------------------------------
    info "branch ${BOLD}$branch${RESET} — changes:"
    git -c color.status=always status --short | sed 's/^/    /'

    if ! confirm "  add all of these and commit?" y; then
        SKIPPED+=("$name")
        continue
    fi

    run git add -A || { err "git add failed"; FAILED+=("$name (add)"); continue; }

    # index counts up per repository, kept in the state file
    count="$(counter_get "$repo")"
    next=$(( count + 1 ))

    info "  ${DIM}commit #$next for this repo (edit the line below as you like)${RESET}"
    msg=''
    while [[ -z ${msg// } ]]; do
        read -e -r -i "[#$next] " -p "  message: " msg </dev/tty || { msg=''; break; }
        [[ -z ${msg// } ]] && echo "  message cannot be empty"
    done
    [[ -z ${msg// } ]] && { warn "aborted"; SKIPPED+=("$name"); continue; }

    if run git commit -m "$msg"; then
        (( DRY_RUN )) || counter_set "$repo" "$next"
        ok "committed: $msg"
        COMMITTED+=("$name")
    else
        err "commit failed"
        FAILED+=("$name (commit)")
        continue
    fi

    if confirm "  push to origin?" y; then
        push_repo "$branch"; rc=$?
        case $rc in
            0) ok "pushed"; PUSHED+=("$name") ;;
            2) LOCAL_ONLY+=("$name") ;;
            *) err "push failed"; FAILED+=("$name (push)") ;;
        esac
    else
        LOCAL_ONLY+=("$name")
    fi
done

# ------------------------------------------------------------ report ---

# Print "label: a, b, c" — or nothing at all when the list is empty.
report() {
    local label="$1" color="$2"; shift 2
    (( $# )) || return 0
    local joined; printf -v joined '%s, ' "$@"
    printf '%s%-16s%s %s\n' "$color" "$label" "$RESET" "${joined%, }"
}

header "summary"
report 'committed'      "$GREEN"  "${COMMITTED[@]}"
report 'pushed'         "$GREEN"  "${PUSHED[@]}"
report 'commit only'    "$YELLOW" "${LOCAL_ONLY[@]}"
report 'skipped'        "$DIM"    "${SKIPPED[@]}"
report 'failed'         "$RED"    "${FAILED[@]}"
(( ${#FAILED[@]} )) && exit 1
exit 0
