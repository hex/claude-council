#!/usr/bin/env bats
# ABOUTME: Tests for scripts/specialist.sh against real throwaway git repositories
# ABOUTME: No mocks: every case creates a repo, runs the script, and reads git's own state back

load test_helper
bats_require_minimum_version 1.5.0

SPECIALIST="${SCRIPTS_DIR}/specialist.sh"

setup() {
    # git reports physical paths, and TMPDIR on macOS sits behind the /var -> /private/var link
    ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/My Projects"
    REPO="${ROOT}/app"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Test
    mkdir -p "$REPO/src"
    echo 'one' > "$REPO/src/a.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm init
}

field() { printf '%s\n' "$output" | sed -n "s/^$1=//p"; }

@test "start creates the worktree and branch beside the repo, even from a subdirectory and a path with spaces" {
    run "$SPECIALIST" start "$REPO/src" sec 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field repo)" = "$REPO" ]
    [ "$(field worktree)" = "${ROOT}/app.specialists/sec-20260923-151204" ]
    [ "$(field branch)" = "specialist/sec/20260923-151204" ]
    [ "$(field base)" = "$(git -C "$REPO" rev-parse HEAD)" ]
    [ "$(field short)" = "$(git -C "$REPO" rev-parse --short=7 HEAD)" ]
    [ "$(field state)" = "${ROOT}/app.specialists/.state/sec-20260923-151204" ]
    [ "$(field dirty)" = "no" ]
    [ -d "$(field state)" ]
    [ "$(git -C "$(field worktree)" rev-parse --abbrev-ref HEAD)" = "specialist/sec/20260923-151204" ]
}

@test "start rejects invalid names before creating a worktree or branch" {
    for name in ../evil -rf a/b Sec 9sec 'a b' ''; do
        run "$SPECIALIST" start "$REPO" "$name" 20260923-151204
        [ "$status" -eq 1 ] || return 1
        [ "$output" = "specialist: invalid name '${name}': must match ^[a-z][a-z0-9-]*\$" ] || return 1
        [ ! -d "${ROOT}/app.specialists" ] || return 1
        [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ] || return 1
    done
}

@test "start accepts a name with a hyphen" {
    run "$SPECIALIST" start "$REPO" sec-2 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field branch)" = "specialist/sec-2/20260923-151204" ]
    [ -d "$(field state)" ]
}

@test "start reports a dirty main tree" {
    echo 'two' >> "$REPO/src/a.txt"
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field dirty)" = "yes" ]
}

@test "start fails with git's message when the branch already exists, and creates nothing" {
    git -C "$REPO" branch specialist/sec/20260923-151204
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
    [ ! -d "${ROOT}/app.specialists/sec-20260923-151204" ]
}

@test "start outside a git repository is refused" {
    mkdir -p "${BATS_TEST_TMPDIR}/plain"
    run "$SPECIALIST" start "${BATS_TEST_TMPDIR}/plain" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: ${BATS_TEST_TMPDIR}/plain is not inside a git repository" ]
}

@test "commit records the round's changes, and says so when there are none" {
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    wt="$(field worktree)"
    run "$SPECIALIST" commit "$wt" "specialist sec: harden login"
    [ "$status" -eq 0 ]
    [ "$output" = "committed=no" ]
    echo 'new' > "$wt/src/b.txt"
    run "$SPECIALIST" commit "$wt" "specialist sec: harden login"
    [ "$output" = "committed=yes" ]
    [ "$(git -C "$wt" log -1 --format=%s)" = "specialist sec: harden login" ]
    [ -z "$(git -C "$wt" status --porcelain)" ]
}

@test "report shows the round, the total and the status" {
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    wt="$(field worktree)"; base="$(field base)"
    echo 'new' > "$wt/src/b.txt"
    "$SPECIALIST" commit "$wt" "round 1" >/dev/null
    round2="$("$SPECIALIST" head "$wt")"
    echo 'more' > "$wt/src/c.txt"
    "$SPECIALIST" commit "$wt" "round 2" >/dev/null
    run "$SPECIALIST" report "$wt" "$round2" "$base"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--- round" ]
    [[ "${lines[1]}" == *"src/c.txt"* ]]
    [[ "$output" == *"--- total"* ]]
    [[ "$output" == *"2 files changed"* ]]
}

start_run() {
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    WT="$(field worktree)"; BR="$(field branch)"; BASE="$(field base)"; STATE="$(field state)"
}

@test "counts reports commits, files and the merge target" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'c' > "$WT/src/c.txt"; "$SPECIALIST" commit "$WT" r2 >/dev/null
    run "$SPECIALIST" counts "$REPO" "$BR" "$BASE"
    [ "$output" = "$(printf 'commits=2\nfiles=2\ntarget=main')" ]
}

@test "merge brings the branch in with a merge commit, then removes worktree and branch" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 0 ]
    [ "$output" = "finished=merge" ]
    [ -f "$REPO/src/b.txt" ]
    [ "$(git -C "$REPO" rev-list --parents -1 HEAD | wc -w | tr -d ' ')" = "3" ]
    [ ! -d "$WT" ]
    run git -C "$REPO" rev-parse --verify -q "$BR"
    [ "$status" -ne 0 ]
}

@test "a conflicting merge is aborted and keeps worktree and branch" {
    start_run
    echo 'theirs' > "$WT/src/a.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'ours' > "$REPO/src/a.txt"; git -C "$REPO" commit -qam ours
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 3 ]
    [ "$output" = "conflict=src/a.txt" ]
    [ -z "$(git -C "$REPO" status --porcelain)" ]
    [ -d "$WT" ]
    git -C "$REPO" rev-parse --verify -q "$BR" >/dev/null
}

@test "merge is refused when the main tree has uncommitted changes to the branch's files" {
    start_run
    echo 'theirs' > "$WT/src/a.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'local edit' >> "$REPO/src/a.txt"
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 4 ]
    [ "$output" = "dirty=src/a.txt" ]
    [ -d "$WT" ]
}

@test "merge is refused on a detached HEAD; discard still works there" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    git -C "$REPO" checkout -q --detach
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 5 ]
    [ "$output" = "detached=yes" ]
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" discard
    [ "$status" -eq 0 ]
    [ "$output" = "finished=discard" ]
    [ ! -d "$WT" ]
}

@test "discard removes a dirty worktree and its unmerged branch" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'uncommitted' > "$WT/src/c.txt"
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" discard
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    run git -C "$REPO" rev-parse --verify -q "$BR"
    [ "$status" -ne 0 ]
}

@test "discard still deletes the branch when the worktree was removed by hand" {
    start_run
    rm -rf "$WT"
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" discard
    [ "$status" -eq 0 ]
    run git -C "$REPO" rev-parse --verify -q "$BR"
    [ "$status" -ne 0 ]
}

@test "codex refuses a missing worktree before starting anything" {
    run "$SPECIALIST" codex "${BATS_TEST_TMPDIR}/nope" "${BATS_TEST_TMPDIR}/state" gpt-6-sol < /dev/null
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: no worktree at ${BATS_TEST_TMPDIR}/nope" ]
}

@test "codex reports a codex that is not installed as exit 127, not a crash" {
    start_run
    PATH="/usr/bin:/bin" run "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol <<< "task"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=127"* ]]
}

@test "commit fails with the hook's message when the repository's pre-commit hook refuses" {
    start_run
    mkdir -p "$REPO/.git/hooks"
    printf '#!/bin/sh\necho "lint failed" >&2\nexit 1\n' > "$REPO/.git/hooks/pre-commit"
    chmod +x "$REPO/.git/hooks/pre-commit"
    echo 'b' > "$WT/src/b.txt"
    run "$SPECIALIST" commit "$WT" r1
    [ "$status" -ne 0 ]
    [[ "$output" == *"lint failed"* ]]
    [[ "$output" != *"committed="* ]]
}

@test "codex never passes a thread id that is not a UUID on to resume" {
    start_run
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\necho %s\n' "'{\"type\":\"thread.started\",\"thread_id\":\"--dangerously-bypass-approvals-and-sandbox\"}'" > "${BATS_TEST_TMPDIR}/bin/codex"
    chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
    PATH="${BATS_TEST_TMPDIR}/bin:/usr/bin:/bin" run "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol <<< "task"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'thread=\nexit=0')" ]
}

@test "a merge git refuses before it starts reports git's reason, not a missing merge" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'untracked here' > "$REPO/src/b.txt"
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 6 ]
    [[ "$output" == *"untracked working tree files would be overwritten"* ]]
    [[ "$output" != *"MERGE_HEAD"* ]]
    [ -d "$WT" ]
    git -C "$REPO" rev-parse --verify -q "$BR" >/dev/null
}

@test "discard closes a run whose branch was deleted by hand" {
    start_run
    git -C "$REPO" worktree remove --force "$WT"
    git -C "$REPO" branch -D "$BR" >/dev/null
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" discard
    [ "$status" -eq 0 ]
    [ "$output" = "finished=discard" ]
}

@test "counts fails loudly when the branch is gone" {
    start_run
    git -C "$REPO" worktree remove --force "$WT"
    git -C "$REPO" branch -D "$BR" >/dev/null
    run "$SPECIALIST" counts "$REPO" "$BR" "$BASE"
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: no branch ${BR}" ]
}

@test "codex clears the previous round's files and records the codex pid" {
    start_run
    mkdir -p "$STATE"
    echo 'round 1 summary' > "$STATE/last-message.md"
    echo 'round 1 noise' > "$STATE/stderr.txt"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\necho $$ > "%s/seen-pid"\nexit 2\n' "$BATS_TEST_TMPDIR" > "${BATS_TEST_TMPDIR}/bin/codex"
    chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
    PATH="${BATS_TEST_TMPDIR}/bin:/usr/bin:/bin" run "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol <<< "task"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=2"* ]]
    [ ! -e "$STATE/last-message.md" ]
    [ ! -s "$STATE/stderr.txt" ]
    [ "$(cat "$STATE/pid")" = "$(cat "${BATS_TEST_TMPDIR}/seen-pid")" ]
}

@test "codex receives the prompt on stdin" {
    start_run
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\ncat > "%s/seen-prompt"\n' "$BATS_TEST_TMPDIR" > "${BATS_TEST_TMPDIR}/bin/codex"
    chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
    printf 'line one\nline two' | PATH="${BATS_TEST_TMPDIR}/bin:/usr/bin:/bin" "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol >/dev/null
    [ "$(cat "${BATS_TEST_TMPDIR}/seen-prompt")" = "$(printf 'line one\nline two')" ]
}
