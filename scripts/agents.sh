#!/usr/bin/env bash
# agents.sh -- Claude Code agents in their own terminal windows, one launcher per
# directory (agents help for the commands).
# State: ~/.local/state/claude-agents/<dir>/jobs/<id>/{prompt,mode,status,...}
# Tunables (env): AGENTS_SLOTS=1  AGENTS_PERMISSION=auto  AGENTS_TERM=kitty
#                 AGENTS_CLAUDE_ARGS=""  AGENTS_KEEP=3600 (closed agents are
#                 forgotten after this many seconds)
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
STATE_ROOT=${AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-agents}
SLOTS=${AGENTS_SLOTS:-1}
KEEP=${AGENTS_KEEP:-3600}
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
    if (( s >= 86400 )); then printf '%dd%dh' $((s/86400)) $((s%86400/3600))
    elif (( s >= 3600 )); then printf '%dh%02dm' $((s/3600)) $((s%3600/60))
    elif (( s >= 60 )); then printf '%dm%02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}
init() {
    mkdir -p "$JOBS"
    echo "$DIR" > "$STATE/dir"
    [[ -f $NOTES ]] || printf '# Notes between agents working in %s\n' "$DIR" > "$NOTES"
}
# fd 9 must not leak into the detached terminals (start_job), or they hold the lock forever.
locked() { ( flock -w 30 9 || die "could not take lock"; "$@" ) 9>>"$LOCK"; }

jobdir() {
    local id; printf -v id '%03d' "$((10#$1))" 2>/dev/null || die "bad id: $1"
    [[ -d $JOBS/$id ]] || die "no job #$((10#$id))"
    echo "$JOBS/$id"
}
all_jobs() { ls -d "$JOBS"/[0-9]* 2>/dev/null | sort -V; }
job_id() { echo $((10#$(basename "$1"))); }
first_line() { local l; IFS= read -r l < "$1"; printf '%s' "$l"; }
# claude writes no transcript for a child session (see the env scrub in cmd_run): no resume then.
has_transcript() { [[ -f $1/transcript && -f $(<"$1/transcript") ]]; }
# Statuses: queued -> running (working on a turn) -> done | asks (turn
# finished, the window waits for you) -> exited (window closed; open again to
# resume) | failed | killed. Only "running" agents hold a queue slot.
alive() { [[ $1 == running || $1 == done || $1 == asks ]]; }

# ---------------------------------------------------------------- scheduling
# Under lock. Gone without reporting = exited; terminal never came up = failed;
# closed ones are forgotten $KEEP s after they ended.
reap() {
    local jd pid st
    for jd in $(all_jobs); do
        st=$(rd "$jd/status")
        if [[ $st == exited || $st == failed || $st == killed ]]; then
            (( $(now) - $(rd "$jd/ended" || now) >= KEEP )) && rm -rf "$jd"
            continue
        fi
        alive "$st" || continue
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
# Under lock.
start_job() {
    local jd=$1
    echo running > "$jd/status"; now > "$jd/started"; rm -f "$jd/pid" "$jd/ended" "$jd/exit" "$jd/turn"
    setsid -f "$SELF" __term "$jd" 9>&- </dev/null >/dev/null 2>&1
}
# #N has been started at some point (or is gone): what a "with #N" job waits for.
has_started() {
    local id; printf -v id '%03d' "$((10#$1))" 2>/dev/null || return 0
    [[ ! -d $JOBS/$id || -f $JOBS/$id/started ]]
}
# Under lock. Queued: opens when fewer than $SLOTS are running (any mode counts),
# in order: a held one stops the queue behind it. Parallel: regardless. "with
# #N": once #N has started. Held: never.
fill_slots() {
    reap
    local jd running=0 with mode started=1 blocked
    for jd in $(all_jobs); do
        [[ $(rd "$jd/status") == running ]] && ((running++))
    done
    # Repeat while something opened: a job may wait for one that just did.
    while (( started )); do
        started=0 blocked=0
        for jd in $(all_jobs); do
            [[ $(rd "$jd/status") == queued ]] || continue
            with=$(rd "$jd/with"); mode=$(rd "$jd/mode")
            # A held queue job stops the queue behind it; held parallel ones are not in it.
            if [[ -f $jd/hold ]]; then [[ -z $with && $mode != now ]] && blocked=1; continue; fi
            if [[ -n $with ]]; then has_started "$with" || continue
            elif [[ $mode == now ]]; then :    # a released parallel prompt
            else (( ! blocked && running < SLOTS )) || continue; fi
            start_job "$jd"; ((running++)); started=1
        done
    done
}
# Under lock. Prints the new id.
new_job() {
    local mode=$1 perm=$2 model=$3 prompt=$4 with=${5:-} hold=${6:-}
    [[ -z $with ]] || jobdir "$with" >/dev/null || exit 1
    # Numbers start over at #1 whenever the list is empty (after a clear).
    [[ -n $(all_jobs) ]] || rm -f "$STATE/counter"
    local n=$(( $(rd "$STATE/counter" || echo 0) + 1 )) id jd
    echo "$n" > "$STATE/counter"
    printf -v id '%03d' "$n"; jd="$JOBS/$id"; mkdir -p "$jd"
    printf '%s\n' "$prompt" > "$jd/prompt"
    echo "$mode" > "$jd/mode"; echo "$perm" > "$jd/perm"
    [[ -n $model ]] && echo "$model" > "$jd/model"
    [[ -n $with ]] && echo "$((10#$with))" > "$jd/with"
    # Session id up front (--session-id) so the window can be reopened with --resume.
    cat /proc/sys/kernel/random/uuid > "$jd/session"
    echo "claude-agent-$(printf '%s' "$DIR" | cksum | cut -d' ' -f1)-$id" > "$jd/class"
    echo queued > "$jd/status"; now > "$jd/created"
    if [[ -n $hold ]]; then touch "$jd/hold"
    elif [[ $mode == now && -z $with ]]; then reap; start_job "$jd"
    else fill_slots; fi
    echo "$n"
}

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
hooks_json() {
    local cmd="'$SELF' __hook '$1'" ev out="{\"hooks\":{" sep=""
    cmd=${cmd//\\/\\\\}; cmd=${cmd//\"/\\\"}
    for ev in SessionStart UserPromptSubmit Stop; do
        out+="$sep\"$ev\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd $ev\",\"timeout\":10}]}]"; sep=","
    done
    echo "$out}}"
}

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
cmd_run() {
    local jd=$1 rc perm args=()
    echo $$ > "$jd/pid"
    cd "$DIR" || { echo failed > "$jd/status"; exit 1; }
    perm=$(rd "$jd/perm"); perm=${perm:-$PERM}
    if [[ $perm == bypassPermissions || $perm == yolo ]]; then args+=(--dangerously-skip-permissions)
    else args+=(--permission-mode "$perm"); fi
    [[ -f $jd/model ]] && args+=(--model "$(<"$jd/model")")
    args+=(${AGENTS_CLAUDE_ARGS:-})
    build_sysprompt "$jd" > "$jd/sysprompt"
    args+=(--settings "$(hooks_json "$jd")" --append-system-prompt "$(<"$jd/sysprompt")")
    if has_transcript "$jd"; then
        args+=(--resume "$(<"$jd/session")")
    else
        args+=(--session-id "$(<"$jd/session")" "$(<"$jd/prompt")")
    fi
    # Started from inside a claude session (the app, or another agent's Stop
    # hook): with these inherited, claude treats the agent as a child session
    # and writes no transcript. No compgen: the nix dev shell's bash lacks it.
    unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT "${!CLAUDE_CODE_MESSAGING_@}"
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
# Hook inside the session (stdin: its JSON). The session id changes on /clear and /resume.
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
            # Background tasks still running: the agent gets woken again when they finish.
            (( busy )) && return
            if [[ $(rd "$jd/status") == running ]]; then
                if (( asks )); then echo asks > "$jd/status"; else echo done > "$jd/status"; fi
                now > "$jd/turn"    # when the turn ended: the time shown stops here
            fi
            locked fill_slots ;;    # a turn ended: the queue may move on
    esac
}

# ---------------------------------------------------------------- transcript
# "? question" while an AskUserQuestion waits: that blocks the turn, so no Stop hook.
activity() {
    [[ -s ${1:-} ]] || { echo "(starting)"; return; }
    tail -n 40 "$1" | perl -MJSON::PP -e '
        binmode STDOUT, ":utf8"; my ($last, $q) = ("", "");
        while (<>) {
            my $j = eval { decode_json($_) } or next; $j->{type} //= "";
            next if $j->{isSidechain};
            $q = "" if $j->{type} eq "user";
            if ($j->{type} eq "assistant") {
                for my $c (@{ $j->{message}{content} || [] }) {
                    if ($c->{type} eq "tool_use") {
                        my $i = $c->{input};
                        $q = join " ", map { $_->{question} // "" } @{ $i->{questions} || [] } if $c->{name} eq "AskUserQuestion";
                        my $s = $i->{command} // $i->{file_path} // $i->{pattern} // $i->{description} // $i->{prompt} // $i->{query} // "";
                        $s =~ s/\s+/ /g; $last = "$c->{name}: $s";
                    } elsif ($c->{type} eq "text" && length $c->{text}) {
                        (my $t = $c->{text}) =~ s/\s+/ /g; $last = "\"$t\"";
                    }
                }
            }
        }
        print $q ne "" ? "? $q" : $last;'
}
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

# ---------------------------------------------------------------- usage
# Same endpoint and token as claude's /usage. Lines: "five_hour|seven_day PERCENT RESETS_AT_EPOCH".
usage_limits() {
    local creds=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json tok
    tok=$(perl -MJSON::PP -e 'local $/; print eval { decode_json(<STDIN>) }->{claudeAiOauth}{accessToken} // ""' < "$creds" 2>/dev/null)
    [[ -n $tok ]] || { echo "not logged in ($creds)" >&2; return 1; }
    curl -sf -m 10 -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
        https://api.anthropic.com/api/oauth/usage | perl -MJSON::PP -MTime::Piece -e '
        local $/; my $j = eval { decode_json(<STDIN>) } or exit 1;
        for my $k (qw(five_hour seven_day)) {
            my $w = $j->{$k} or next;
            (my $r = $w->{resets_at} // "") =~ s/\..*//;    # 2026-09-21T18:40:00.560+00:00
            my $t = eval { Time::Piece->strptime($r, "%Y-%m-%dT%H:%M:%S")->epoch } // 0;
            printf "%s %d %d\n", $k, $w->{utilization} // 0, $t;
        }'
}
cmd_usage() {
    local k pct at
    while read -r k pct at; do
        printf '%-7s %3d%% used, resets in %s\n' "${k/five_hour/5-hour}" "$pct" "$(fmt_dur $(( at - $(now) )))"
    done < <(usage_limits) | sed 's/^seven_day/weekly /'
}

# ---------------------------------------------------------------- windows
# Agent windows live on Hyprland's special:agents workspace (rule in configs/hyprland.lua).
focus_window() {
    local class; class=$(rd "$1/class"); [[ -n $class ]] || return 1
    command -v hyprctl >/dev/null || return 1
    hyprctl repl "
        local w
        for _, x in ipairs(hl.get_windows()) do if tostring(x.class) == '${class}' then w = x end end
        if not w then return 'not found' end
        local ws = hl.get_active_workspace()
        if ws then hl.dispatch(hl.dsp.window.move({ window = w, workspace = ws.id })) end
        hl.dispatch(hl.dsp.focus({ window = w }))
        return 'ok'" 2>&1 | grep -q '^ok'
}
hide_window() {
    local class; class=$(rd "$1/class"); [[ -n $class ]] || return 1
    command -v hyprctl >/dev/null || return 1
    hyprctl dispatch "hl.dsp.window.move({ window = \"class:^${class}\$\", workspace = \"special:agents\", follow = false })" >/dev/null 2>&1
}
show_when_up() {
    local i
    for i in $(seq 1 40); do
        focus_window "$1" && return 0
        sleep 0.2
    done
    return 1
}
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
            has_transcript "$jd" && { echo done > "$jd/status"; now > "$jd/turn"; }    # resumed: waits for you
            show_when_up "$jd" >/dev/null 2>&1 &
            echo "#$1 opened again" ;;
    esac
}
cmd_hide() {
    local jd; jd=$(jobdir "$1") || exit 1
    alive "$(rd "$jd/status")" || die "#$1 has no open window"
    hide_window "$jd" && echo "#$1 hidden"
}

# ---------------------------------------------------------------- commands
# Groups, top to bottom: closed, finished (done/asks), working+queued; a rule between.
render_status() {
    local jd id st mode with dur line width=${1:-$(tput cols 2>/dev/null || echo 120)}
    local nrun=0 nwait=0 nq=0 nask=0 prefix='                                  > '
    local closed=() finished=() rest=() group printed=0
    locked reap
    for jd in $(all_jobs); do
        case $(rd "$jd/status") in
            done|asks) finished+=("$jd") ;;
            exited|failed|killed) closed+=("$jd") ;;
            *) rest+=("$jd") ;;
        esac
    done
    for group in closed finished rest; do
        local -n jds=$group
        (( ${#jds[@]} )) || continue
        (( printed++ )) && printf -- '-%.0s' $(seq 1 "$width") && echo
        for jd in "${jds[@]}"; do status_line "$jd"; done
    done
    echo "$DIR: $nrun working, $nwait done, $nq queued$( (( nask )) && echo ", $nask ASKING YOU" ), $SLOTS queue slot(s)$( [[ $(wc -l < "$NOTES") -gt 1 ]] && echo ", notes in $NOTES" )"
}
# Counts into render_status's locals.
status_line() {
    local jd=$1
    id=$(job_id "$jd"); st=$(rd "$jd/status"); mode=$(rd "$jd/mode")
    with=$(rd "$jd/with"); [[ -n $with ]] && mode="with #$with"
    [[ $st == queued && -f $jd/hold ]] && st=held
    case $st in
        queued|held) dur=-; ((nq++)) ;;
        running) dur=$(fmt_dur $(( $(now) - $(rd "$jd/started") ))); ((nrun++)) ;;
        done|asks)  # the time stops when the turn ended
            dur=$(fmt_dur $(( $(rd "$jd/turn" || now) - $(rd "$jd/started") )))
            case $st in asks) ((nask++)) ;; *) ((nwait++)) ;; esac ;;
        *)       dur=$(fmt_dur $(( $(rd "$jd/ended" || now) - $(rd "$jd/started" || rd "$jd/created") ))) ;;
    esac
    printf -v line ' #%-3s %-8s %-8s %7s  %s' "$id" "$st" "$mode" "$dur" "$(first_line "$jd/prompt")"
    echo "${line:0:width}"
    case $st in
        running) line="$prefix$(activity "$(rd "$jd/transcript")")"; echo "${line:0:width}" ;;
        asks)    line="$prefix$(rd "$jd/last")"; echo "${line:0:width}" ;;
        failed)  [[ -s $jd/err ]] && { line="$prefix$(first_line "$jd/err")"; echo "${line:0:width}"; } ;;
    esac
}
cmd_status() { render_status; }
cmd_watch()  { while :; do clear; render_status; sleep 2; done; }

cmd_add() {
    local mode=$1 perm=$PERM model="" with="" hold="" prompt="" args=(); shift
    while (($#)); do
        case $1 in
            -y|--yolo) perm=bypassPermissions ;;
            -H|--hold) hold=1 ;;
            -m|--model) model=$2; shift ;;
            -w|--with) with=${2#\#}; shift; [[ $with == - ]] && with="" ;;
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
    [[ -n $with && $mode != now ]] && die "-w only makes sense for parallel (now) prompts"
    local id; id=$(locked new_job "$mode" "$perm" "$model" "$prompt" "$with" "$hold") || exit 1
    echo "#$id $mode${with:+ with #$with}${hold:+ (held)}: $(first_line <(printf '%s\n' "$prompt"))"
}
cmd_hold() {
    local jd; jd=$(jobdir "$1") || exit 1
    [[ $(rd "$jd/status") == queued ]] || die "#$1 is not queued"
    touch "$jd/hold"; echo "#$1 held"
}
cmd_release() {
    local jd; jd=$(jobdir "$1") || exit 1
    [[ -f $jd/hold ]] || die "#$1 is not held"
    rm -f "$jd/hold"; locked fill_slots; echo "#$1 released"
}
cmd_edit() {
    local jd; jd=$(jobdir "$1") || exit 1; shift
    local prompt=""
    case ${1:-} in -f|--file) prompt=$(<"$2") ;; ?*) prompt=$* ;; *) prompt=$(cat) ;; esac
    [[ -n ${prompt//[[:space:]]/} ]] || die "empty prompt"
    locked set_prompt "$jd" "$prompt" && echo "#$(job_id "$jd") prompt changed: $(first_line <(printf '%s\n' "$prompt"))"
}
# Under lock.
set_prompt() {
    [[ $(rd "$1/status") == queued ]] || die "#$(job_id "$1") is not queued any more"
    printf '%s\n' "$2" > "$1/prompt"
}
cmd_kill() {
    local jd; jd=$(jobdir "$1") || exit 1
    alive "$(rd "$jd/status")" || die "#$1 has no open window"
    echo killed > "$jd/status"; close_window "$jd"
    now > "$jd/ended"; locked fill_slots; echo "#$1 killed"
}
# The terminal gave the window its own process group: claude, hooks and worker go down together.
close_window() {
    local pid pg; pid=$(rd "$1/pid"); pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $pg ]] && kill -- -"$pg" 2>/dev/null; [[ -n $pid ]] && kill "$pid" 2>/dev/null
    return 0
}
cmd_drop() {
    local jd; jd=$(jobdir "$1") || exit 1
    local st; st=$(rd "$jd/status")
    if alive "$st"; then echo killed > "$jd/status"; close_window "$jd"; fi
    rm -rf "$jd"; alive "$st" && locked fill_slots
    echo "#$1 removed"
}
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
    local with; with=$(rd "$jd/with"); [[ -n $with && -d $JOBS/$(printf '%03d' "$with") ]] || with=""
    local id; id=$(locked new_job "$(rd "$jd/mode")" "$(rd "$jd/perm")" "$(rd "$jd/model")" "$(<"$jd/prompt")" "$with")
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
    echo "#$1  $(rd "$jd/status")  mode=$(rd "$jd/mode")$( [[ -s $jd/with ]] && echo " with=#$(<"$jd/with")")  perm=$(rd "$jd/perm")  session=$(rd "$jd/session")  window=$(rd "$jd/class")"
    echo "--- prompt"; cat "$jd/prompt"
    [[ -s $jd/last ]] && { echo "--- last message"; cat "$jd/last"; }
    [[ -s $jd/err ]] && { echo "--- error"; cat "$jd/err"; }
    return 0
}
cmd_resume() {
    local jd; jd=$(jobdir "$1") || exit 1
    alive "$(rd "$jd/status")" && die "#$1 still has a window open (agents open $1 jumps there)"
    has_transcript "$jd" || die "#$1 never started a session"
    cd "$DIR" && exec env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID claude --resume "$(<"$jd/session")"
}

# ---------------------------------------------------------------- app
# nixos/pkgs/agents-ui (Rust); cargo build --release there for trying it before a rebuild.
cmd_ui() {
    [[ -t 0 && -t 1 ]] || die "the app needs a terminal"
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
       -w N   parallel with #N: waits until #N has started, then opens next to it
       -H     held: does not open until released (agents release N)
       (no PROMPT: read stdin, or open \$EDITOR when interactive)
  hold N | release N   keep queued #N (and the queue behind it) from starting | let it go again
  edit N [PROMPT]      replace the prompt of queued #N (argument, -f file, or stdin)
  status               text overview       watch        overview, refreshed every 2 s
  (nothing)            the app: overview + micro prompt box (Enter sends, Tab queue/parallel, Shift+Tab with #N,
                       Ctrl+V puts a screenshot from the clipboard in the box beside it)
  open N | hide N      bring #N's window here (reopens it if closed) | send it back out of sight
  resume N             continue closed #N in this terminal (claude --resume)
  log [-f] N           readable transcript of #N (-f follows)
  show N               prompt, last message and session id of #N
  kill N | drop N      close #N's window (stays listed) | remove #N (closes its window)
  retry N              queue #N's prompt again as a new agent
  clear                forget finished agents (closed ones, and done ones: their windows close)
  notes                show the shared notes file
  usage                the account's 5-hour and weekly usage limits (as claude's /usage)
  path                 print the state directory

Anything that is not a command is taken as a prompt to queue.
env: AGENTS_SLOTS=$SLOTS (working agents a queued one waits for)  AGENTS_PERMISSION=$PERM  AGENTS_TERM=$TERM_APP  AGENTS_CLAUDE_ARGS
EOT
}

init
cmd=${1:-}; shift || true
case $cmd in
    "") cmd_ui ;;
    __term) cmd_term "$@" ;;
    __run) cmd_run "$@" ;;
    __hook) cmd_hook "$@" ;;
    __reap) locked fill_slots ;;   # reaps, and moves the queue on if that freed a slot
    __usage) usage_limits ;;
    __pretty) pretty_log ;;
    add|a|append|queue|q) cmd_add add "$@" ;;
    now|n|par|parallel|p) cmd_add now "$@" ;;
    status|st|ls|list) cmd_status ;;
    watch|w) cmd_watch ;;
    open|o|focus|go) cmd_open "$@" ;;
    hide|h) cmd_hide "$@" ;;
    resume|r) cmd_resume "$@" ;;
    log) cmd_log "$@" ;;
    show|result) cmd_show "$@" ;;
    kill|k|stop) cmd_kill "$@" ;;
    drop|rm) cmd_drop "$@" ;;
    retry) cmd_retry "$@" ;;
    hold|pause) cmd_hold "$@" ;;
    release|unhold) cmd_release "$@" ;;
    edit) cmd_edit "$@" ;;
    clear|clean) cmd_clear ;;
    notes) cat "$NOTES" ;;
    usage) cmd_usage ;;
    path) echo "$STATE" ;;
    -h|--help|help) usage ;;
    -*) usage; exit 1 ;;
    *) cmd_add add "$cmd" "$@" ;;
esac
