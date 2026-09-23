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
