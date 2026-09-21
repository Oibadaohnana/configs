#!/usr/bin/env bash
# agents.sh -- launch Claude Code agents in their own terminal windows, from the
# current directory, and keep an overview of them.
#
#   agents add "prompt"     queue: opens once fewer than $AGENTS_SLOTS (1 by
#                           default) agents are working -- whatever mode they
#                           were started in -- so queued prompts run one after
#                           another, each opening when everything before it
#                           has finished its turn
#   agents now "prompt"     parallel: opens right away next to whatever runs
#   agents                  the app (same as agents ui); agents status for text
#   agents ui               the app: overview plus an always-visible
#                           micro prompt box (Enter sends, Tab toggles
#                           queue/parallel, Esc: agent list, Enter there jumps
#                           into its window
#
# Each agent is a normal interactive `claude` session in a new terminal window
# (kitty), started with the prompt as its first message: you talk to it there
# exactly as if you had typed the prompt yourself. Hooks injected into that
# session report back when it finished a turn, which is what frees a queue
# slot. Every agent is told (via --append-system-prompt) which other agents
# work in the same directory, how to check again and where to leave notes.
#
# State: ~/.local/state/claude-agents/<dir>/jobs/<id>/{prompt,mode,status,...}
# Tunables (env): AGENTS_SLOTS=1  AGENTS_PERMISSION=auto  AGENTS_TERM=kitty
#                 AGENTS_CLAUDE_ARGS=""
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
STATE_ROOT=${AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-agents}
SLOTS=${AGENTS_SLOTS:-1}
PERM=${AGENTS_PERMISSION:-auto}
TERM_APP=${AGENTS_TERM:-kitty}

case ${1:-} in
    __term|__run|__hook)
        # Detached worker / hook: derive the directory from the job path, not from cwd.
        STATE=$(dirname "$(dirname "$2")")
        DIR=$(<"$STATE/dir") ;;
    *)  DIR=$(pwd -P)
        STATE="$STATE_ROOT/${DIR//\//%}" ;;
esac
JOBS="$STATE/jobs"
NOTES="$STATE/notes.md"
LOCK="$STATE/lock"

die() { echo "agents: $*" >&2; exit 1; }
now() { date +%s; }
rd()  { [[ -f $1 ]] && cat "$1"; }
fmt_dur() {
    local s=$1
    if (( s >= 3600 )); then printf '%dh%02dm' $((s/3600)) $((s%3600/60))
    elif (( s >= 60 )); then printf '%dm%02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}
init() {
    mkdir -p "$JOBS"
    echo "$DIR" > "$STATE/dir"
    [[ -f $NOTES ]] || printf '# Notes between agents working in %s\n' "$DIR" > "$NOTES"
}
# Serialise everything that touches job state. fd 9 must not leak into the
# detached terminals (see start_job), otherwise they would hold the lock forever.
locked() { ( flock -w 30 9 || die "could not take lock"; "$@" ) 9>>"$LOCK"; }

jobdir() {
    local id; printf -v id '%03d' "$((10#$1))" 2>/dev/null || die "bad id: $1"
    [[ -d $JOBS/$id ]] || die "no job #$((10#$id))"
    echo "$JOBS/$id"
}
all_jobs() { ls -d "$JOBS"/[0-9]* 2>/dev/null | sort -V; }
job_id() { echo $((10#$(basename "$1"))); }
first_line() { local l; IFS= read -r l < "$1"; printf '%s' "$l"; }
# Statuses: queued -> running (working on a turn) -> done | asks (turn
# finished, the window waits for you) -> exited (window closed; open again to
# resume) | failed | killed. Only "running" agents hold a queue slot.
alive() { [[ $1 == running || $1 == done || $1 == asks ]]; }

# ---------------------------------------------------------------- scheduling
# Called under lock. A job whose window/worker went away without reporting
# counts as exited; one whose terminal never came up as failed.
reap() {
    local jd pid st
    for jd in $(all_jobs); do
        st=$(rd "$jd/status"); alive "$st" || continue
        pid=$(rd "$jd/pid")
        if [[ -n $pid ]]; then
            kill -0 "$pid" 2>/dev/null && continue
            echo exited > "$jd/status"
        elif (( $(now) - $(rd "$jd/started" || echo 0) < 30 )); then
            continue    # terminal still coming up
        else
            echo failed > "$jd/status"; echo "terminal ($TERM_APP) did not start" > "$jd/err"
        fi
        now > "$jd/ended"
    done
}
# Called under lock. Opens the agent's terminal window, detached from us.
start_job() {
    local jd=$1
    echo running > "$jd/status"; now > "$jd/started"; rm -f "$jd/pid" "$jd/ended" "$jd/exit"
    setsid -f "$SELF" __term "$jd" 9>&- </dev/null >/dev/null 2>&1
}
# Called under lock. A queued job opens once fewer than $SLOTS agents are
# working, in any mode; parallel ("now") jobs open regardless, but count.
fill_slots() {
    reap
    local jd running=0
    for jd in $(all_jobs); do
        [[ $(rd "$jd/status") == running ]] && ((running++))
    done
    for jd in $(all_jobs); do
        (( running < SLOTS )) || break
        [[ $(rd "$jd/status") == queued ]] || continue
        start_job "$jd"; ((running++))
    done
}
# Called under lock. Prints the new id.
new_job() {
    local mode=$1 perm=$2 model=$3 prompt=$4
    # Numbers start over at #1 whenever the list is empty (after a clear).
    [[ -n $(all_jobs) ]] || rm -f "$STATE/counter"
    local n=$(( $(rd "$STATE/counter" || echo 0) + 1 )) id jd
    echo "$n" > "$STATE/counter"
    printf -v id '%03d' "$n"; jd="$JOBS/$id"; mkdir -p "$jd"
    printf '%s\n' "$prompt" > "$jd/prompt"
    echo "$mode" > "$jd/mode"; echo "$perm" > "$jd/perm"
    [[ -n $model ]] && echo "$model" > "$jd/model"
    # Session id chosen up front (claude --session-id) so the window can be
    # reopened with --resume at any time; the class finds the window again.
    cat /proc/sys/kernel/random/uuid > "$jd/session"
    echo "claude-agent-$(printf '%s' "$DIR" | cksum | cut -d' ' -f1)-$id" > "$jd/class"
    echo queued > "$jd/status"; now > "$jd/created"
    if [[ $mode == now ]]; then reap; start_job "$jd"; else fill_slots; fi
    echo "$n"
}

# What every agent gets appended to its system prompt.
build_sysprompt() {
    local me=$1 jd st others=""
    for jd in $(all_jobs); do
        st=$(rd "$jd/status")
        [[ $jd != "$me" ]] && alive "$st" || continue
        others+="  - agent #$(job_id "$jd") ($st, opened $(fmt_dur $(( $(now) - $(rd "$jd/started") ))) ago): $(first_line "$jd/prompt")"$'\n'
    done
    cat <<EOT
You are agent #$(job_id "$me"), one of several Claude Code agents opened from a launcher in this directory ($DIR). You run in your own terminal window; the user keeps an overview of all agents in the launcher and switches into your window to talk to you, so work as you normally would and ask when you need to. When you are done with your task, end with a short summary of what you changed: the launcher takes your finished turn as the signal that the next queued agent may start.

EOT
    if [[ -n $others ]]; then
        cat <<EOT
Other agents are working IN THIS SAME DIRECTORY right now, on their own tasks, and may edit files at the same time as you:
$others
EOT
    else
        echo "No other agent is open right now, but more can be started while you work."
    fi
    cat <<EOT

Rules for sharing the directory:
- Stay within the scope of your task. Re-read a file right before editing it; another agent may have changed it since you last looked, and you must not undo their work.
- Do not run git commit, stash, checkout, reset, rebase, or repo-wide formatters/linters with --fix unless your task explicitly asks for it: they would sweep up the other agents' half-done changes.
- Do not start or stop shared long-running processes (dev servers, watchers, builds in progress) another agent obviously relies on.
- Live list of agents: run \`"$SELF" status\` (from this directory) before anything sweeping.
- Coordination notes: read $NOTES before you start; append a dated line there when you do something the others should know (a rename, a moved file, a changed interface).
EOT
}
# Settings JSON for --settings: hooks that report the session's state back here.
hooks_json() {
    local cmd="'$SELF' __hook '$1'" ev out="{\"hooks\":{" sep=""
    cmd=${cmd//\\/\\\\}; cmd=${cmd//\"/\\\"}
    for ev in SessionStart UserPromptSubmit Stop; do
        out+="$sep\"$ev\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd $ev\",\"timeout\":10}]}]"; sep=","
    done
    echo "$out}}"
}

# The terminal window: runs __run inside, closes when claude exits.
cmd_term() {
    local jd=$1 title
    printf -v title 'agent #%s: %s' "$(job_id "$jd")" "$(first_line "$jd/prompt")"
    title=${title:0:80}
    case $TERM_APP in
        kitty)     exec kitty --class "$(<"$jd/class")" --title "$title" -d "$DIR" "$SELF" __run "$jd" ;;
        foot)      exec foot --app-id "$(<"$jd/class")" --title "$title" -D "$DIR" "$SELF" __run "$jd" ;;
        alacritty) exec alacritty --class "$(<"$jd/class")" --title "$title" --working-directory "$DIR" -e "$SELF" __run "$jd" ;;
        *)         exec "$TERM_APP" -e "$SELF" __run "$jd" ;;
    esac
}
# Inside the window: the interactive claude session, then the bookkeeping.
cmd_run() {
    local jd=$1 rc perm args=()
    echo $$ > "$jd/pid"
    cd "$DIR" || { echo failed > "$jd/status"; exit 1; }
    perm=$(rd "$jd/perm"); perm=${perm:-$PERM}
    if [[ $perm == bypassPermissions || $perm == yolo ]]; then args+=(--dangerously-skip-permissions)
    else args+=(--permission-mode "$perm"); fi
    [[ -f $jd/model ]] && args+=(--model "$(<"$jd/model")")
    # shellcheck disable=SC2206
    args+=(${AGENTS_CLAUDE_ARGS:-})
    build_sysprompt "$jd" > "$jd/sysprompt"
    args+=(--settings "$(hooks_json "$jd")" --append-system-prompt "$(<"$jd/sysprompt")")
    if [[ -f $jd/transcript ]]; then
        # Reopened: pick the conversation up where the closed window left it.
        args+=(--resume "$(<"$jd/session")")
    else
        args+=(--session-id "$(<"$jd/session")" "$(<"$jd/prompt")")
    fi
    # Scrub the identity of a Claude session we may have been started from
    # (agents ui run inside claude): the agent must be its own top-level session.
    local v; for v in $(compgen -e | grep -E "^(CLAUDECODE|CLAUDE_PID|CLAUDE_CODE_(CHILD_SESSION|SESSION_ID|SESSION_ATTENDED|MESSAGING_.*|ENTRYPOINT))$"); do unset "$v"; done
    claude "${args[@]}"; rc=$?
    echo "$rc" > "$jd/exit"; now > "$jd/ended"
    if [[ $(rd "$jd/status") != killed ]]; then
        if (( rc == 0 || rc > 128 )); then echo exited > "$jd/status"
        else
            echo failed > "$jd/status"
            printf '\nclaude exited with %d -- press Enter to close this window\n' "$rc"; read -r
        fi
    fi
    locked fill_slots
}
# Hook inside the session (stdin: the hook's JSON). Tracks the session id
# (changes on /clear and /resume), the transcript, and the turn boundaries.
cmd_hook() {
    local jd=$1 ev=$2 sid tp asks busy last
    { read -r sid; read -r tp; read -r asks; read -r busy; IFS= read -r last; } < <(perl -MJSON::PP -e '
        local $/; my $j = eval { decode_json(<STDIN>) } or exit;
        my $m = $j->{last_assistant_message} // "";
        my ($tail) = (grep { /\S/ } split /\n/, $m)[-1] // "";
        (my $one = $m) =~ s/\s+/ /g;
        my $bg = ref $j->{background_tasks} eq "ARRAY" ? scalar @{ $j->{background_tasks} } : 0;
        print $j->{session_id} // "", "\n", $j->{transcript_path} // "", "\n", ($tail =~ /\?/ ? 1 : 0), "\n$bg\n$one\n";')
    [[ -n $sid ]] && echo "$sid" > "$jd/session"
    [[ -n $tp ]] && echo "$tp" > "$jd/transcript"
    case $ev in
        UserPromptSubmit)
            alive "$(rd "$jd/status")" && echo running > "$jd/status" ;;
        Stop)
            printf '%s\n' "$last" > "$jd/last"
            # A turn that ends with background tasks still running is not the
            # end: the agent gets woken again when they finish.
            (( busy )) && return
            if [[ $(rd "$jd/status") == running ]]; then
                if (( asks )); then echo asks > "$jd/status"; else echo done > "$jd/status"; fi
            fi
            locked fill_slots ;;    # a turn ended: the queue may move on
    esac
}

# ---------------------------------------------------------------- transcript
# One-line "what is it doing right now" from the tail of a session transcript.
activity() {
    [[ -s ${1:-} ]] || { echo "(starting)"; return; }
    tail -n 40 "$1" | perl -MJSON::PP -e '
        binmode STDOUT, ":utf8"; my $last = "";
        while (<>) {
            my $j = eval { decode_json($_) } or next; $j->{type} //= "";
            next if $j->{isSidechain};
            if ($j->{type} eq "assistant") {
                for my $c (@{ $j->{message}{content} || [] }) {
                    if ($c->{type} eq "tool_use") {
                        my $i = $c->{input};
                        my $s = $i->{command} // $i->{file_path} // $i->{pattern} // $i->{description} // $i->{prompt} // $i->{query} // "";
                        $s =~ s/\s+/ /g; $last = "$c->{name}: $s";
                    } elsif ($c->{type} eq "text" && length $c->{text}) {
                        (my $t = $c->{text}) =~ s/\s+/ /g; $last = "\"$t\"";
                    }
                }
            }
        }
        print $last;'
}
# Human-readable rendering of a session transcript (stdin).
pretty_log() {
    perl -MJSON::PP -e '
        $| = 1; binmode STDOUT, ":utf8"; my $max = $ENV{AGENTS_RESULT_LINES} || 15;
        while (<STDIN>) {
            my $j = eval { decode_json($_) } or next; my $t = $j->{type} // "";
            next if $j->{isSidechain};
            if ($t eq "assistant") {
                for my $c (@{ $j->{message}{content} || [] }) {
                    if ($c->{type} eq "text") { print "\n$c->{text}\n" }
                    elsif ($c->{type} eq "tool_use") {
                        my $i = $c->{input};
                        my $s = join " ", map { "$_=" . (ref $i->{$_} ? encode_json($i->{$_}) : $i->{$_}) } sort keys %$i;
                        $s =~ s/\n/\\n/g;
                        print "\n\e[1;34m> $c->{name}\e[0m ", substr($s, 0, 400), (length $s > 400 ? " ..." : ""), "\n";
                    }
                }
            } elsif ($t eq "user") {
                my $c = $j->{message}{content};
                if (!ref $c) { print "\n\e[1;36myou:\e[0m $c\n" if defined $c && $c !~ /^<[a-z-]+>/; next }
                for my $c (@$c) {
                    next unless ref $c;
                    if ($c->{type} eq "text") { print "\n\e[1;36myou:\e[0m $c->{text}\n" if $c->{text} !~ /^<[a-z-]+>/; next }
                    next unless $c->{type} eq "tool_result";
                    my $r = $c->{content} // "";
                    $r = join "", map { ref $_ ? ($_->{text} // "") : $_ } @$r if ref $r eq "ARRAY";
                    my @l = split /\n/, $r; my $n = @l;
                    splice @l, $max if $n > $max;
                    print "  \e[2m| $_\e[0m\n" for @l;
                    print "  \e[2m| ... ($n lines)\e[0m\n" if $n > $max;
                }
            }
        }'
}

# ---------------------------------------------------------------- windows
# Bring the agent's terminal window to the front. Returns 1 when not found.
focus_window() {
    local class; class=$(rd "$1/class"); [[ -n $class ]] || return 1
    command -v hyprctl >/dev/null || return 1
    # The lua config parser has no exit code for a missed focus: match the text.
    ! hyprctl dispatch "hl.dsp.focus({ window = \"class:^${class}\$\" })" 2>&1 | grep -q "not found"
}
# Enter/open on an agent: jump to its window, or open a new one that resumes
# the conversation when the old window is gone.
cmd_open() {
    local jd; jd=$(jobdir "$1") || exit 1
    local st; st=$(rd "$jd/status")
    case $st in
        queued) die "#$1 is queued and has no window yet" ;;
        running|done|asks)
            locked reap
            if alive "$(rd "$jd/status")"; then
                focus_window "$jd" || die "could not focus the window of #$1 (class $(rd "$jd/class"))"
                return
            fi ;;&
        *)  locked start_job "$jd"
            [[ -f $jd/transcript ]] && echo waiting > "$jd/status"     # resumed: waits for you
            echo "#$1 opened again" ;;
    esac
}

# ---------------------------------------------------------------- commands
# Plain-text overview, one job per line (+ what it does / asks for live ones).
render_status() {
    local jd id st mode dur line width=${1:-$(tput cols 2>/dev/null || echo 120)}
    local nrun=0 nwait=0 nq=0 nask=0 prefix='                              > '
    locked reap
    for jd in $(all_jobs); do
        id=$(job_id "$jd"); st=$(rd "$jd/status"); mode=$(rd "$jd/mode")
        case $st in
            queued)  dur=-; ((nq++)) ;;
            running|done|asks)
                dur=$(fmt_dur $(( $(now) - $(rd "$jd/started") )))
                case $st in running) ((nrun++)) ;; asks) ((nask++)) ;; *) ((nwait++)) ;; esac ;;
            *)       dur=$(fmt_dur $(( $(rd "$jd/ended" || now) - $(rd "$jd/started" || rd "$jd/created") ))) ;;
        esac
        printf -v line ' #%-3s %-8s %-4s %7s  %s' "$id" "$st" "$mode" "$dur" "$(first_line "$jd/prompt")"
        echo "${line:0:width}"
        case $st in
            running) line="$prefix$(activity "$(rd "$jd/transcript")")"; echo "${line:0:width}" ;;
            asks)    line="$prefix$(rd "$jd/last")"; echo "${line:0:width}" ;;
            failed)  [[ -s $jd/err ]] && { line="$prefix$(first_line "$jd/err")"; echo "${line:0:width}"; } ;;
        esac
    done
    echo "$DIR: $nrun working, $nwait done, $nq queued$( (( nask )) && echo ", $nask ASKING YOU" ), $SLOTS queue slot(s)$( [[ $(wc -l < "$NOTES") -gt 1 ]] && echo ", notes in $NOTES" )"
}
cmd_status() { render_status; }
cmd_watch()  { while :; do clear; render_status; sleep 2; done; }

cmd_add() {
    local mode=$1 perm=$PERM model="" prompt="" args=(); shift
    while (($#)); do
        case $1 in
            -y|--yolo) perm=bypassPermissions ;;
            -m|--model) model=$2; shift ;;
            -f|--file) prompt=$(<"$2"); shift ;;
            --) shift; args+=("$@"); break ;;
            *) args+=("$1") ;;
        esac; shift
    done
    [[ -z $prompt && ${#args[@]} -gt 0 ]] && prompt=${args[*]}
    if [[ -z $prompt ]]; then
        if [[ -t 0 ]]; then
            local tmp; tmp=$(mktemp --suffix=.md)
            ${EDITOR:-micro} "$tmp"; prompt=$(<"$tmp"); rm -f "$tmp"
        else prompt=$(cat); fi
    fi
    [[ -n ${prompt//[[:space:]]/} ]] || die "empty prompt"
    local id; id=$(locked new_job "$mode" "$perm" "$model" "$prompt") || exit 1
    echo "#$id $mode: $(first_line <(printf '%s\n' "$prompt"))"
}
# Close #N's window (the job stays in the list as killed).
cmd_kill() {
    local jd; jd=$(jobdir "$1") || exit 1
    alive "$(rd "$jd/status")" || die "#$1 has no open window"
    echo killed > "$jd/status"; close_window "$jd"
    now > "$jd/ended"; locked fill_slots; echo "#$1 killed"
}
# The window's own process group (the terminal gave it a fresh session):
# claude, its hooks and our worker go down together, the window closes.
close_window() {
    local pid pg; pid=$(rd "$1/pid"); pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $pg ]] && kill -- -"$pg" 2>/dev/null; [[ -n $pid ]] && kill "$pid" 2>/dev/null
    return 0
}
# Remove #N from the list, whatever its state; an open window is closed first.
cmd_drop() {
    local jd; jd=$(jobdir "$1") || exit 1
    local st; st=$(rd "$jd/status")
    if alive "$st"; then echo killed > "$jd/status"; close_window "$jd"; fi
    rm -rf "$jd"; alive "$st" && locked fill_slots
    echo "#$1 removed"
}
# Forget every agent that is finished: closed ones, and done ones (waiting for
# you / asking) whose windows get closed. Working and queued agents stay.
cmd_clear() {
    local jd st n=0 closed=0
    locked reap
    for jd in $(all_jobs); do
        st=$(rd "$jd/status")
        case $st in
            done|asks) echo killed > "$jd/status"; close_window "$jd"; ((closed++)) ;;
            exited|failed|killed) ;;
            *) continue ;;
        esac
        rm -rf "$jd"; ((n++))
    done
    echo "removed $n finished agent(s)$( (( closed )) && echo ", closed $closed window(s)" )"
}
cmd_retry() {
    local jd; jd=$(jobdir "$1") || exit 1
    local id; id=$(locked new_job "$(rd "$jd/mode")" "$(rd "$jd/perm")" "$(rd "$jd/model")" "$(<"$jd/prompt")")
    echo "#$id queued again (was #$1)"
}
cmd_log() {
    local follow=""; [[ ${1:-} == -f ]] && { follow=1; shift; }
    local jd; jd=$(jobdir "${1:-}") || exit 1
    local tp; tp=$(rd "$jd/transcript")
    [[ -s $tp ]] || { echo "(no transcript yet)"; cat "$jd/err" 2>/dev/null; return; }
    if [[ -n $follow ]]; then tail -n +1 -f "$tp" | pretty_log; else pretty_log < "$tp"; fi
}
cmd_show() {
    local jd; jd=$(jobdir "$1") || exit 1
    echo "#$1  $(rd "$jd/status")  mode=$(rd "$jd/mode")  perm=$(rd "$jd/perm")  session=$(rd "$jd/session")  window=$(rd "$jd/class")"
    echo "--- prompt"; cat "$jd/prompt"
    [[ -s $jd/last ]] && { echo "--- last message"; cat "$jd/last"; }
    [[ -s $jd/err ]] && { echo "--- error"; cat "$jd/err"; }
    return 0
}
# Continue a closed agent in THIS terminal instead of a new window.
cmd_resume() {
    local jd; jd=$(jobdir "$1") || exit 1
    alive "$(rd "$jd/status")" && die "#$1 still has a window open (agents open $1 jumps there)"
    [[ -f $jd/transcript ]] || die "#$1 never started a session"
    cd "$DIR" && exec env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID claude --resume "$(<"$jd/session")"
}

# ---------------------------------------------------------------- ui
# The app lives in nixos/pkgs/agents-ui (Rust, ratatui): the overview, the
# always-visible prompt input, and the keys that run the commands above. It is
# on PATH once the system is rebuilt with it; a plain `cargo build --release`
# in that directory works for trying it out before that.
cmd_ui() {
    [[ -t 0 && -t 1 ]] || die "ui needs a terminal"
    local bin
    for bin in "${AGENTS_UI:-}" "$(command -v agents-ui)" "$(dirname "$SELF")/../nixos/pkgs/agents-ui/target/release/agents-ui"; do
        [[ -n $bin && -x $bin ]] || continue
        AGENTS_SH=$SELF AGENTS_DIR=$DIR AGENTS_STATE_DIR=$STATE AGENTS_SLOTS=$SLOTS exec "$bin"
    done
    die "agents-ui is not built: add it to systemPackages and rebuild, or run cargo build --release in nixos/pkgs/agents-ui"
}

usage() {
    cat <<EOT
usage: agents [command] [args]      (opens agents in: $DIR)

  add [-y] [-m model] [-f file] PROMPT   queue: opens when a queue slot is free
  now [-y] [-m model] [-f file] PROMPT   parallel: opens right away
       (no PROMPT: read stdin, or open \$EDITOR when interactive)
  status               text overview       watch        overview, refreshed every 2 s
  ui | (nothing)       the app: overview + micro prompt box (Enter sends, Tab queue/parallel)
  open N               go to #N's window (opens a new one resuming #N if it was closed)
  resume N             continue closed #N in this terminal (claude --resume)
  log [-f] N           readable transcript of #N (-f follows)
  show N               prompt, last message and session id of #N
  kill N | drop N      close #N's window (stays listed) | remove #N (closes its window)
  retry N              queue #N's prompt again as a new agent
  clear                forget finished agents (closed ones, and done ones: their windows close)
  notes                show the shared notes file
  path                 print the state directory

Anything that is not a command is taken as a prompt to queue.
env: AGENTS_SLOTS=$SLOTS (working agents a queued one waits for)  AGENTS_PERMISSION=$PERM  AGENTS_TERM=$TERM_APP  AGENTS_CLAUDE_ARGS
EOT
}

init
cmd=${1:-ui}; shift || true
case $cmd in
    __term) cmd_term "$@" ;;
    __run) cmd_run "$@" ;;
    __hook) cmd_hook "$@" ;;
    __reap) locked reap ;;
    __pretty) pretty_log ;;
    add|a|append|queue|q) cmd_add add "$@" ;;
    now|n|par|parallel|p) cmd_add now "$@" ;;
    status|st|ls|list) cmd_status ;;
    watch|w) cmd_watch ;;
    ui|tui) cmd_ui ;;
    open|o|focus|go) cmd_open "$@" ;;
    resume|r) cmd_resume "$@" ;;
    log) cmd_log "$@" ;;
    show|result) cmd_show "$@" ;;
    kill|k|stop) cmd_kill "$@" ;;
    drop|rm) cmd_drop "$@" ;;
    retry) cmd_retry "$@" ;;
    clear|clean) cmd_clear ;;
    notes) cat "$NOTES" ;;
    path) echo "$STATE" ;;
    -h|--help|help) usage ;;
    -*) usage; exit 1 ;;
    *) cmd_add add "$cmd" "$@" ;;
esac
