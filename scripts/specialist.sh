#!/usr/bin/env bash
# ABOUTME: Git side of the specialist tool: worktree per run, one commit per round, merge or discard
# ABOUTME: Called by the council-pane mod with argument arrays; prints key=value lines, errors on stderr

set -euo pipefail

die() { echo "specialist: $*" >&2; exit 1; }

repo_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "$1 is not inside a git repository"
}

cmd_start() {
    local dir="$1" name="$2" ts="$3" root parent base short home worktree branch state dirty
    root="$(repo_root "$dir")"
    parent="$(dirname "$root")"
    home="${parent}/$(basename "$root").specialists"
    worktree="${home}/${name}-${ts}"
    branch="specialist/${name}/${ts}"
    state="${home}/.state/${name}-${ts}"
    base="$(git -C "$root" rev-parse HEAD)"
    short="$(git -C "$root" rev-parse --short=7 HEAD)"
    if [[ -n "$(git -C "$root" status --porcelain)" ]]; then dirty=yes; else dirty=no; fi
    mkdir -p "$home"
    git -C "$root" worktree add -q -b "$branch" "$worktree" "$base" >&2 || exit 1
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
    printf 'commits=%s\nfiles=%s\ntarget=%s\n' \
        "$(git -C "$root" rev-list --count "${base}..${branch}")" \
        "$(git -C "$root" diff --name-only "$base" "$branch" | grep -c . || true)" \
        "$(git -C "$root" symbolic-ref --quiet --short HEAD || true)"
}

remove_run() {
    local root="$1" worktree="$2" branch="$3"
    if [[ -d "$worktree" ]]; then git -C "$root" worktree remove --force "$worktree"; fi
    git -C "$root" worktree prune
    git -C "$root" branch -D "$branch" >/dev/null
}

cmd_finish() {
    local root="$1" worktree="$2" branch="$3" how="$4" touched dirty conflicts
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
    if ! git -C "$root" merge -q --no-ff --no-edit "$branch" >/dev/null 2>&1; then
        conflicts="$(git -C "$root" diff --name-only --diff-filter=U)"
        git -C "$root" merge --abort
        while IFS= read -r f; do [[ -n "$f" ]] && echo "conflict=$f"; done <<< "$conflicts"
        exit 3
    fi
    remove_run "$root" "$worktree" "$branch"
    echo "finished=merge"
}

cmd_codex() {
    local worktree="$1" state="$2" model="$3" thread="${4:-}" code=0 found
    [[ -d "$worktree" ]] || die "no worktree at ${worktree}"
    mkdir -p "$state"
    local flags=(--json -m "$model" -c 'sandbox_mode="workspace-write"' -c 'sandbox_workspace_write.network_access=true' -o "${state}/last-message.md")
    if [[ -n "$thread" ]]; then
        (cd "$worktree" && codex exec resume "${flags[@]}" "$thread" -) > "${state}/events.jsonl" 2> "${state}/stderr.txt" || code=$?
    else
        (cd "$worktree" && codex exec "${flags[@]}" -) > "${state}/events.jsonl" 2> "${state}/stderr.txt" || code=$?
    fi
    found="$(sed -n 's/.*"type":"thread.started","thread_id":"\([^"]*\)".*/\1/p' "${state}/events.jsonl" | head -1)"
    printf 'thread=%s\nexit=%s\n' "${found:-$thread}" "$code"
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
        codex)  [[ $# -eq 3 || $# -eq 4 ]] || die "usage: codex <worktree> <state> <model> [thread]"; cmd_codex "$@" ;;
        *) die "unknown subcommand '${sub}'" ;;
    esac
}

main "$@"
