#!/usr/bin/env bash
# ABOUTME: Git side of the specialist tool: worktree per run, one commit per round, merge or discard
# ABOUTME: Called by the council-pane mod with argument arrays; prints key=value lines, errors on stderr

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deadline.sh
source "${SCRIPT_DIR}/lib/deadline.sh"

die() { echo "specialist: $*" >&2; exit 1; }

repo_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "$1 is not inside a git repository"
}

parse_include_path() {
    local root="$1" raw="$2" remaining="$2" part path=""
    [[ "$raw" != /* && "/$raw/" != */../* ]] || die "invalid .worktreeinclude path '${raw}': must be relative and contain no '..' component"
    while [[ -n "$remaining" ]]; do
        part="${remaining%%/*}"
        if [[ "$remaining" == */* ]]; then remaining="${remaining#*/}"; else remaining=""; fi
        if [[ -n "$part" && "$part" != . ]]; then
            [[ -z "$path" || ! -L "$root/$path" ]] || die "symlink in .worktreeinclude source for '${raw}': ${path}"
            path="${path:+$path/}$part"
        fi
    done
    [[ -n "$path" ]] || die "invalid .worktreeinclude path '${raw}': must name a file or directory"
    REPLY="$path"
}

cmd_start() {
    local dir="$1" name="$2" ts="$3" root parent base short home worktree branch state dirty entry source destination tree_entry link i count=0
    local -a includes
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid name '${name}': must match ^[a-z][a-z0-9-]*\$"
    root="$(repo_root "$dir")"
    parent="$(dirname "$root")"
    home="${parent}/$(basename "$root").specialists"
    worktree="${home}/${name}-${ts}"
    branch="specialist/${name}/${ts}"
    state="${home}/.state/${name}-${ts}"
    base="$(git -C "$root" rev-parse HEAD)"
    short="$(git -C "$root" rev-parse --short=7 HEAD)"
    if [[ -n "$(git -C "$root" status --porcelain)" ]]; then dirty=yes; else dirty=no; fi
    if [[ -f "$root/.worktreeinclude" ]]; then
        while IFS= read -r entry || [[ -n "$entry" ]]; do
            entry="${entry%$'\r'}"
            [[ -z "$entry" || "$entry" == \#* ]] && continue
            parse_include_path "$root" "$entry"
            entry="$REPLY"
            git -C "$root" ls-tree -r -z "$base" | while IFS= read -r -d '' tree_entry; do
                [[ "${tree_entry%% *}" == 120000 ]] || continue
                link="${tree_entry#*$'\t'}"
                if [[ "$entry" == "$link" || "$entry" == "$link/"* || "$link" == "$entry/"* ]]; then
                    die "symlink in worktree destination for '${entry}': ${link}"
                fi
            done || exit 1
            includes[count]="$entry"
            count=$((count + 1))
        done < "$root/.worktreeinclude"
    fi
    # The worktree gets tracked files from git; a copied file git does not
    # ignore would ride the round's commit into the merge.
    i=0
    while (( i < count )); do
        entry="${includes[$i]}"
        if [[ -e "$root/$entry" || -L "$root/$entry" ]] && ! git -C "$root" check-ignore -q -- "$entry"; then
            die ".worktreeinclude entry '${entry}' is not ignored by git: the round would commit it"
        fi
        i=$((i + 1))
    done
    git -C "$root" worktree add -q -b "$branch" "$worktree" "$base" >&2 || exit 1
    i=0
    while (( i < count )); do
        entry="${includes[$i]}"
        source="$root/$entry"
        if [[ -e "$source" || -L "$source" ]]; then
            destination="$worktree/$entry"
            mkdir -p "$(dirname "$destination")"
            if [[ -d "$source" && ! -L "$source" ]]; then
                mkdir -p "$destination"
                cp -R -P "$source/." "$destination"
            else
                cp -R -P "$source" "$destination"
            fi
        fi
        i=$((i + 1))
    done
    mkdir -p "$state"
    printf 'repo=%s\nworktree=%s\nbranch=%s\nbase=%s\nshort=%s\nstate=%s\ndirty=%s\n' \
        "$root" "$worktree" "$branch" "$base" "$short" "$state" "$dirty"
}

# The hooks directory as a path inside the tree, or nothing when git keeps
# the hooks outside it (the default .git/hooks). A relative core.hooksPath
# such as .husky/_ puts them in the tree, where a round can write them.
hooks_in_tree() {
    local tree="$1" top hooks
    top="$(git -C "$tree" rev-parse --show-toplevel)"
    hooks="$(git -C "$tree" rev-parse --path-format=absolute --git-path hooks)"
    if [[ "$hooks" == "$top" ]]; then echo "."; return; fi
    case "$hooks" in
        "${top}/"*) printf '%s\n' "${hooks#"$top"/}" ;;
    esac
}

# The commit runs on this machine, outside Codex's sandbox, and git runs the
# hooks it finds at commit time. Files in the hooks directory are checked
# ignored or not: husky's .husky/_ ignores itself.
cmd_commit() {
    local worktree="$1" message="$2" hooks edited
    hooks="$(hooks_in_tree "$worktree")"
    if [[ -n "$hooks" ]]; then
        edited="$( { git -C "$worktree" diff --name-only HEAD -- "$hooks"; git -C "$worktree" ls-files --others -- "$hooks"; } | sort -u)"
        [[ -z "$edited" ]] || die "refusing to commit: the round changed files git runs as hooks here: $(printf '%s' "$edited" | tr '\n' ' ')"
    fi
    if [[ -z "$(git -C "$worktree" status --porcelain)" ]]; then echo "committed=no"; return; fi
    git -C "$worktree" add -A
    git -C "$worktree" commit -q -m "$message"
    echo "committed=yes"
}

cmd_head() { git -C "$1" rev-parse HEAD; }

# A process's start time, which tells the round's own process apart from a
# later one that reused its pid. Git Bash's ps has no -o; its procfs keeps
# the start time in field 22 of /proc/<pid>/stat, after a name that may
# hold spaces.
cmd_identity() {
    local pid="$1" stat
    local -a fields
    [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid pid '${pid}'"
    if LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null; then return 0; fi
    if [[ ! -r "/proc/${pid}/stat" ]] || ! IFS= read -r stat < "/proc/${pid}/stat"; then
        die "no start time for pid ${pid}"
    fi
    read -ra fields <<< "${stat##*) }"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || die "no start time for pid ${pid}"
    printf 'proc:%s\n' "${fields[19]}"
}

# A process and everything under it.
process_tree() {
    local child
    echo "$1"
    for child in $(children_of "$1"); do process_tree "$child"; done
}

any_alive() {
    local p
    for p in "$@"; do if kill -0 "$p" 2>/dev/null; then return 0; fi; done
    return 1
}

# Ends a round's Codex and every process under it, and records why: timeout
# or stopped. The reason is written first, so the round reads it once Codex
# exits; the round then waits for the ended file, written only once nothing
# it started is left, because a command that ignores SIGTERM can outlive
# Codex and keep writing to the worktree. The tree is taken before the
# signal: a child left behind is reparented and no longer found under Codex.
# Five seconds after SIGTERM, whatever remains is killed.
end_round() {
    local state="$1" pid="$2" reason="$3" ticks=50 p
    local -a tree
    echo "$reason" > "${state}/reason.tmp" && mv "${state}/reason.tmp" "${state}/reason"
    # shellcheck disable=SC2207 # pids hold no spaces or globs
    tree=($(process_tree "$pid"))
    for p in "${tree[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    while (( ticks-- > 0 )) && any_alive "${tree[@]}"; do sleep 0.1; done
    for p in "${tree[@]}"; do if kill -0 "$p" 2>/dev/null; then signal_tree KILL "$p"; fi; done
    touch "${state}/ended"
}

# The round's pid and start time name the round the caller confirmed
# stopping: a follow-up can start another in the same state dir meanwhile.
# Both are needed, since ps gives start times to the second.
cmd_stop() {
    local state="$1" round_pid="$2" start="$3" pid ticks=50
    [[ ! -f "${state}/exit" ]] || die "the round in ${state} has already ended"
    # The round records its start before it launches Codex, so a stop can
    # arrive in between.
    while (( ticks-- > 0 )) && [[ ! -f "${state}/codex-pid" ]]; do sleep 0.1; done
    [[ -f "${state}/codex-pid" ]] || die "no round has started in ${state}"
    [[ "$(cat "${state}/pid" 2>/dev/null)" == "$round_pid" && "$(cat "${state}/start" 2>/dev/null)" == "$start" ]] \
        || die "the round in ${state} is not the one asked to stop"
    pid="$(cat "${state}/codex-pid")"
    end_round "$state" "$pid" stopped
    echo "stopped=yes"
}

# Every session follows a live round, so each may see it end: mkdir is atomic,
# and only the session that creates the claim closes the round. A claim older
# than a minute belongs to a closer that died midway and is taken over.
cmd_claim() {
    local state="$1"
    mkdir -p "$state"
    if mkdir "$state/closing" 2>/dev/null; then echo "claimed=yes"; return; fi
    if [[ -n "$(find "$state/closing" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        rmdir "$state/closing" 2>/dev/null || true
        if mkdir "$state/closing" 2>/dev/null; then echo "claimed=yes"; return; fi
    fi
    echo "claimed=no"
}

cmd_report() {
    local worktree="$1" round_base="$2" run_base="$3"
    echo "--- round"; git -C "$worktree" diff --stat "$round_base" HEAD
    echo "--- total"; git -C "$worktree" diff --stat "$run_base" HEAD
    echo "--- status"; git -C "$worktree" status --short
}

cmd_counts() {
    local root="$1" branch="$2" base="$3"
    git -C "$root" show-ref --verify --quiet "refs/heads/${branch}" || die "no branch ${branch}"
    printf 'commits=%s\nfiles=%s\ntarget=%s\n' \
        "$(git -C "$root" rev-list --count "${base}..${branch}")" \
        "$(git -C "$root" diff --name-only "$base" "$branch" | grep -c . || true)" \
        "$(git -C "$root" symbolic-ref --quiet --short HEAD || true)"
}

remove_run() {
    local root="$1" worktree="$2" branch="$3"
    if [[ -d "$worktree" ]]; then git -C "$root" worktree remove --force "$worktree"; fi
    git -C "$root" worktree prune
    if git -C "$root" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "$root" branch -D "$branch" >/dev/null
    fi
    rm -rf "$(dirname "$worktree")/.state/$(basename "$worktree")"
}

cmd_finish() {
    local root="$1" worktree="$2" branch="$3" how="$4" touched dirty conflicts refusal uncommitted hooks fork
    [[ ( "$worktree" == /* || "$worktree" =~ ^[A-Za-z]:/ ) && "${worktree##*/}" =~ ^[a-z][a-z0-9-]*-[0-9]{8}-[0-9]{6}$ ]] || die "invalid worktree path '${worktree}': expected an absolute path ending in a run id"
    root="$(repo_root "$root")"
    if [[ "$how" == discard ]]; then
        remove_run "$root" "$worktree" "$branch"
        echo "finished=discard"; return 0
    fi
    [[ "$how" == merge ]] || die "finish takes merge or discard, not '${how}'"
    # A round that failed, or whose commit was refused, leaves its edits
    # uncommitted; merging would delete them with the worktree.
    if [[ -d "$worktree" ]]; then
        uncommitted="$(git -C "$worktree" status --porcelain -uall | cut -c4-)"
        if [[ -n "$uncommitted" ]]; then while IFS= read -r f; do echo "uncommitted=$f"; done <<< "$uncommitted"; exit 7; fi
    fi
    if ! git -C "$root" symbolic-ref --quiet HEAD >/dev/null; then echo "detached=yes"; exit 5; fi
    fork="$(git -C "$root" merge-base HEAD "$branch")"
    # git runs the merge's hooks from the files the merge has just brought in.
    hooks="$(hooks_in_tree "$root")"
    if [[ -n "$hooks" ]]; then
        hooks="$(git -C "$root" diff --name-only "$fork" "$branch" -- "$hooks")"
        if [[ -n "$hooks" ]]; then while IFS= read -r f; do echo "hook=$f"; done <<< "$hooks"; exit 8; fi
    fi
    touched="$(git -C "$root" diff --name-only "$fork" "$branch")"
    dirty="$( { git -C "$root" diff --name-only; git -C "$root" diff --name-only --cached; } | sort -u | grep -Fxf <(printf '%s\n' "$touched") || true)"
    if [[ -n "$dirty" ]]; then while IFS= read -r f; do echo "dirty=$f"; done <<< "$dirty"; exit 4; fi
    if ! refusal="$(git -C "$root" merge -q --no-ff --no-edit "$branch" 2>&1)"; then
        # git can refuse before it starts (an untracked file in the way): then
        # there is no merge to abort, and its own message is the reason.
        if ! git -C "$root" rev-parse -q --verify MERGE_HEAD >/dev/null; then
            printf '%s\n' "$refusal" >&2
            exit 6
        fi
        conflicts="$(git -C "$root" diff --name-only --diff-filter=U)"
        git -C "$root" merge --abort
        while IFS= read -r f; do [[ -n "$f" ]] && echo "conflict=$f"; done <<< "$conflicts"
        exit 3
    fi
    remove_run "$root" "$worktree" "$branch"
    echo "finished=merge"
}

cmd_codex() {
    local worktree="$1" state="$2" model="$3" effort="$4" limit="$5" thread="${6:-}"
    # The effort goes into a -c value, so only a bare lowercase word gets through;
    # which efforts a model offers is checked when the row is saved.
    [[ -z "$effort" || "$effort" =~ ^[a-z]+$ ]] || die "invalid effort '${effort}': must be lowercase letters"
    [[ "$limit" =~ ^[0-9]+$ ]] || die "invalid time limit '${limit}': must be whole seconds, 0 for none"
    [[ -d "$worktree" ]] || die "no worktree at ${worktree}"
    mkdir -p "$state"
    # Each round's files describe that round only.
    rm -f "${state}/last-message.md" "${state}/stderr.txt" "${state}/events.jsonl" "${state}/pid" "${state}/start" "${state}/start.tmp" "${state}/codex-pid" "${state}/exit" "${state}/thread" "${state}/reason" "${state}/reason.tmp" "${state}/ended"
    rmdir "${state}/closing" 2>/dev/null || true
    cat > "${state}/prompt.txt"
    local flags=(--json -m "$model" -c 'sandbox_mode="workspace-write"' -c 'sandbox_workspace_write.network_access=true' -c 'model_reasoning_summary="concise"' -c 'shell_environment_policy.inherit="core"' --output-schema "${SCRIPT_DIR}/specialist-report.schema.json" -o "${state}/last-message.md")
    if [[ -n "$effort" ]]; then flags+=(-c "model_reasoning_effort=\"${effort}\""); fi
    local args=(exec "${flags[@]}" -)
    if [[ -n "$thread" ]]; then args=(exec resume "${flags[@]}" "$thread" -); fi
    # The round runs detached and this call returns at once: the caller follows
    # it through the state dir. It holds none of this script's pipes, or a
    # caller reading our output would wait for the whole round. The exit file
    # is written last; its presence is what says the round is over.
    (
        while [[ ! -f "${state}/start" ]]; do sleep 0.01; done
        code=0
        # Codex's own pid is the one to kill to stop a round: this subshell
        # then still writes the exit file, so the round reports how it ended.
        if cd "$worktree"; then
            codex "${args[@]}" < "${state}/prompt.txt" > "${state}/events.jsonl" 2> "${state}/stderr.txt" &
            codex_pid="$!"
            echo "$codex_pid" > "${state}/codex-pid"
            watchdog=""
            # Ticks, not a SECONDS deadline, which can come due early.
            if (( limit > 0 )); then
                (
                    ticks="$limit"
                    while (( ticks-- > 0 )); do
                        sleep 1
                        kill -0 "$codex_pid" 2>/dev/null || exit 0
                    done
                    end_round "$state" "$codex_pid" timeout
                ) &
                watchdog="$!"
            fi
            wait "$codex_pid" || code=$?
            # An ended round closes only once end_round has cleared what Codex left.
            if [[ -f "${state}/reason" ]]; then
                ticks=150
                while (( ticks-- > 0 )) && [[ ! -f "${state}/ended" ]]; do sleep 0.1; done
            fi
            if [[ -n "$watchdog" ]]; then kill "$watchdog" 2>/dev/null || true; fi
            # Codex answers SIGTERM by exiting 0, which would pass for a
            # finished round: an ended round reports 143 whatever it exited with.
            if [[ -f "${state}/reason" ]]; then code=143; fi
        else
            code=1
        fi
        # Only a UUID is kept: the id goes back to codex as an argument, where a
        # value starting with a dash would read as a flag.
        found="$(sed -n 's/.*"type":"thread.started","thread_id":"\([0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}\)".*/\1/p' "${state}/events.jsonl" 2>/dev/null | head -1)" || true
        printf '%s' "${found:-$thread}" > "${state}/thread"
        echo "$code" > "${state}/exit.tmp" && mv "${state}/exit.tmp" "${state}/exit"
    ) < /dev/null > /dev/null 2>&1 &
    local round_pid="$!"
    if echo "$round_pid" > "${state}/pid" \
        && ( cmd_identity "$round_pid" ) > "${state}/start.tmp" 2>/dev/null \
        && grep -q '[^[:space:]]' "${state}/start.tmp" \
        && mv "${state}/start.tmp" "${state}/start"; then
        echo "pid=$round_pid"
    else
        kill "$round_pid" 2>/dev/null || true
        wait "$round_pid" 2>/dev/null || true
        rm -f "${state}/start.tmp"
        die "could not record start time for round pid ${round_pid}"
    fi
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        start)  [[ $# -eq 3 ]] || die "usage: start <dir> <name> <ts>"; cmd_start "$@" ;;
        commit) [[ $# -eq 2 ]] || die "usage: commit <worktree> <message>"; cmd_commit "$@" ;;
        head)   [[ $# -eq 1 ]] || die "usage: head <worktree>"; cmd_head "$@" ;;
        identity) [[ $# -eq 1 ]] || die "usage: identity <pid>"; cmd_identity "$@" ;;
        claim)  [[ $# -eq 1 ]] || die "usage: claim <state>"; cmd_claim "$@" ;;
        report) [[ $# -eq 3 ]] || die "usage: report <worktree> <round-base> <run-base>"; cmd_report "$@" ;;
        counts) [[ $# -eq 3 ]] || die "usage: counts <repo> <branch> <run-base>"; cmd_counts "$@" ;;
        finish) [[ $# -eq 4 ]] || die "usage: finish <repo> <worktree> <branch> merge|discard"; cmd_finish "$@" ;;
        codex)  [[ $# -eq 5 || $# -eq 6 ]] || die "usage: codex <worktree> <state> <model> <effort|''> <limit-seconds> [thread]"; cmd_codex "$@" ;;
        stop)   [[ $# -eq 3 ]] || die "usage: stop <state> <round-pid> <start>"; cmd_stop "$@" ;;
        *) die "unknown subcommand '${sub}'" ;;
    esac
}

main "$@"
