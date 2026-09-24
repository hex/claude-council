#!/usr/bin/env bash
# ABOUTME: Git side of the specialist tool: worktree per run, one commit per round, merge or discard
# ABOUTME: Called by the council-pane mod with argument arrays; prints key=value lines, errors on stderr

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
            includes[$count]="$entry"
            count=$((count + 1))
        done < "$root/.worktreeinclude"
    fi
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

cmd_commit() {
    local worktree="$1" message="$2"
    if [[ -z "$(git -C "$worktree" status --porcelain)" ]]; then echo "committed=no"; return; fi
    git -C "$worktree" add -A
    git -C "$worktree" commit -q -m "$message"
    echo "committed=yes"
}

cmd_head() { git -C "$1" rev-parse HEAD; }

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
    local root="$1" worktree="$2" branch="$3" how="$4" touched dirty conflicts refusal
    [[ "$worktree" == /* && "${worktree##*/}" =~ ^[a-z][a-z0-9-]*-[0-9]{8}-[0-9]{6}$ ]] || die "invalid worktree path '${worktree}': expected an absolute path ending in a run id"
    root="$(repo_root "$root")"
    if [[ "$how" == discard ]]; then
        remove_run "$root" "$worktree" "$branch"
        echo "finished=discard"; return 0
    fi
    [[ "$how" == merge ]] || die "finish takes merge or discard, not '${how}'"
    if ! git -C "$root" symbolic-ref --quiet HEAD >/dev/null; then echo "detached=yes"; exit 5; fi
    touched="$(git -C "$root" diff --name-only "$(git -C "$root" merge-base HEAD "$branch")" "$branch")"
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
    local worktree="$1" state="$2" model="$3" effort="$4" thread="${5:-}"
    # The effort goes into a -c value, so only a bare lowercase word gets through;
    # which efforts a model offers is checked when the row is saved.
    [[ -z "$effort" || "$effort" =~ ^[a-z]+$ ]] || die "invalid effort '${effort}': must be lowercase letters"
    [[ -d "$worktree" ]] || die "no worktree at ${worktree}"
    mkdir -p "$state"
    # Each round's files describe that round only.
    rm -f "${state}/last-message.md" "${state}/stderr.txt" "${state}/events.jsonl" "${state}/pid" "${state}/start" "${state}/start.tmp" "${state}/codex-pid" "${state}/exit" "${state}/thread"
    cat > "${state}/prompt.txt"
    local flags=(--json -m "$model" -c 'sandbox_mode="workspace-write"' -c 'sandbox_workspace_write.network_access=true' -c 'model_reasoning_summary="concise"' --output-schema "${SCRIPT_DIR}/specialist-report.schema.json" -o "${state}/last-message.md")
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
            echo "$!" > "${state}/codex-pid"
            wait "$!" || code=$?
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
        && LC_ALL=C ps -o lstart= -p "$round_pid" > "${state}/start.tmp" 2>/dev/null \
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
        report) [[ $# -eq 3 ]] || die "usage: report <worktree> <round-base> <run-base>"; cmd_report "$@" ;;
        counts) [[ $# -eq 3 ]] || die "usage: counts <repo> <branch> <run-base>"; cmd_counts "$@" ;;
        finish) [[ $# -eq 4 ]] || die "usage: finish <repo> <worktree> <branch> merge|discard"; cmd_finish "$@" ;;
        codex)  [[ $# -eq 4 || $# -eq 5 ]] || die "usage: codex <worktree> <state> <model> <effort|''> [thread]"; cmd_codex "$@" ;;
        *) die "unknown subcommand '${sub}'" ;;
    esac
}

main "$@"
