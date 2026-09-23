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

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        start)  [[ $# -eq 3 ]] || die "usage: start <dir> <name> <ts>"; cmd_start "$@" ;;
        commit) [[ $# -eq 2 ]] || die "usage: commit <worktree> <message>"; cmd_commit "$@" ;;
        head)   [[ $# -eq 1 ]] || die "usage: head <worktree>"; cmd_head "$@" ;;
        report) [[ $# -eq 3 ]] || die "usage: report <worktree> <round-base> <run-base>"; cmd_report "$@" ;;
        *) die "unknown subcommand '${sub}'" ;;
    esac
}

main "$@"
