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
    # Git for Windows turns autocrlf on system-wide, and its line-ending warning
    # on stderr would land in every captured $output.
    git -C "$REPO" config core.autocrlf false
    mkdir -p "$REPO/src"
    echo 'one' > "$REPO/src/a.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm init
}

teardown() {
    if [ -d "${BATS_TEST_TMPDIR}/bin" ]; then touch "${BATS_TEST_TMPDIR}/go"; fi
    # A fake codex that ignores go would outlive a failed test and hold bats open.
    if [ -n "${STATE:-}" ] && [ -f "$STATE/codex-pid" ]; then kill -9 "$(cat "$STATE/codex-pid")" 2>/dev/null || true; fi
    if [ -f "${BATS_TEST_TMPDIR}/child" ]; then kill -9 "$(cat "${BATS_TEST_TMPDIR}/child")" 2>/dev/null || true; fi
}

field() { printf '%s\n' "$output" | sed -n "s/^$1=//p"; }

# git reports a path as C:/... under Git Bash, where the shell's own paths look
# POSIX; elsewhere the two are the same.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# Git Bash without developer mode copies instead of linking.
requires_symlinks() {
    ln -s target "${BATS_TEST_TMPDIR}/symlink-probe" 2>/dev/null || true
    [ -L "${BATS_TEST_TMPDIR}/symlink-probe" ] || skip "this filesystem makes no symlinks"
    rm -f "${BATS_TEST_TMPDIR}/symlink-probe"
}

@test "start creates the worktree and branch beside the repo, even from a subdirectory and a path with spaces" {
    requires_symlinks
    printf 'ignored.txt\r\n# comment\n\nmissing.txt\nignored-dir' > "$REPO/.worktreeinclude"
    printf 'file contents\n' > "$REPO/ignored.txt"
    mkdir -p "$REPO/ignored-dir/nested"
    printf 'directory contents\n' > "$REPO/ignored-dir/nested/file.txt"
    ln -s nested/file.txt "$REPO/ignored-dir/link"
    printf 'ignored.txt\nignored-dir/\n' > "$REPO/.gitignore"
    git -C "$REPO" add .worktreeinclude .gitignore
    git -C "$REPO" commit -qm includes
    run "$SPECIALIST" start "$REPO/src" sec 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field repo)" = "$(native_path "$REPO")" ]
    [ "$(field worktree)" = "$(native_path "${ROOT}/app.specialists/sec-20260923-151204")" ]
    [ "$(field branch)" = "specialist/sec/20260923-151204" ]
    [ "$(field base)" = "$(git -C "$REPO" rev-parse HEAD)" ]
    [ "$(field short)" = "$(git -C "$REPO" rev-parse --short=7 HEAD)" ]
    [ "$(field state)" = "$(native_path "${ROOT}/app.specialists/.state/sec-20260923-151204")" ]
    [ "$(field dirty)" = "no" ]
    [ -d "$(field state)" ]
    [ "$(git -C "$(field worktree)" rev-parse --abbrev-ref HEAD)" = "specialist/sec/20260923-151204" ]
    [ "$(cat "$(field worktree)/ignored.txt")" = 'file contents' ]
    [ "$(cat "$(field worktree)/ignored-dir/nested/file.txt")" = 'directory contents' ]
    [ -L "$(field worktree)/ignored-dir/link" ]
    [ "$(readlink "$(field worktree)/ignored-dir/link")" = 'nested/file.txt' ]
    [ ! -e "$(field worktree)/missing.txt" ]
}

@test "start rejects unsafe include entries before creating a worktree or branch" {
    for entry in '/tmp/secret' 'src/../secret'; do
        printf 'src/a.txt\n%s\n' "$entry" > "$REPO/.worktreeinclude"
        run "$SPECIALIST" start "$REPO" sec 20260923-151204
        [ "$status" -eq 1 ] || return 1
        [ "$output" = "specialist: invalid .worktreeinclude path '${entry}': must be relative and contain no '..' component" ] || return 1
        [ ! -e "${ROOT}/app.specialists" ] || return 1
        [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ] || return 1
    done
}

@test "start refuses an include entry git does not ignore, before creating a worktree or branch" {
    printf 'secret.env\n' > "$REPO/.worktreeinclude"
    printf 'TOKEN=x\n' > "$REPO/secret.env"
    git -C "$REPO" add .worktreeinclude && git -C "$REPO" commit -qm includes
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: .worktreeinclude entry 'secret.env' is not ignored by git: the round would commit it" ]
    [ ! -e "${ROOT}/app.specialists/sec-20260923-151204" ]
    run ! git -C "$REPO" show-ref --verify --quiet refs/heads/specialist/sec/20260923-151204
}

@test "start refuses a tracked file named in .worktreeinclude" {
    printf 'src/a.txt\n' > "$REPO/.worktreeinclude"
    git -C "$REPO" add .worktreeinclude && git -C "$REPO" commit -qm includes
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: .worktreeinclude entry 'src/a.txt' is not ignored by git: the round would commit it" ]
    [ ! -e "${ROOT}/app.specialists/sec-20260923-151204" ]
}

@test "start refuses a tracked symlink in an include destination parent" {
    requires_symlinks
    mkdir "$ROOT/outside"
    ln -s "$ROOT/outside" "$REPO/cfg"
    git -C "$REPO" add cfg
    git -C "$REPO" commit -qm link
    # The base commit keeps the link while the main tree holds an ignored,
    # untracked directory there, so only the symlink check stands between
    # the copy and $ROOT/outside.
    git -C "$REPO" rm -q --cached cfg
    printf 'cfg/\n' >> "$REPO/.git/info/exclude"
    rm "$REPO/cfg"
    mkdir "$REPO/cfg"
    printf 'private\n' > "$REPO/cfg/secret"
    printf 'cfg/secret\n' > "$REPO/.worktreeinclude"
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: symlink in worktree destination for 'cfg/secret': cfg" ]
    [ ! -e "$ROOT/outside/secret" ]
    [ ! -e "${ROOT}/app.specialists/sec-20260923-151204" ]
    [ ! -e "${ROOT}/app.specialists" ]
    [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ]
    printf 'cfg\n' > "$REPO/.worktreeinclude"
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: symlink in worktree destination for 'cfg': cfg" ]
    [ ! -e "${ROOT}/app.specialists" ]
    [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ]
}

@test "start refuses a tracked symlink within an included directory" {
    requires_symlinks
    # GNU cp writes through a destination link to an existing target; BSD cp
    # refuses, so only a GNU runner shows the escape without the guard.
    printf 'original\n' > "$ROOT/outside.txt"
    mkdir "$REPO/shared"
    ln -s "$ROOT/outside.txt" "$REPO/shared/file.txt"
    git -C "$REPO" add shared
    git -C "$REPO" commit -qm link
    git -C "$REPO" rm -q --cached shared/file.txt
    printf 'shared/\n' >> "$REPO/.git/info/exclude"
    rm "$REPO/shared/file.txt"
    printf 'private\n' > "$REPO/shared/file.txt"
    printf 'shared\n' > "$REPO/.worktreeinclude"
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: symlink in worktree destination for 'shared': shared/file.txt" ]
    [ "$(cat "$ROOT/outside.txt")" = original ]
    [ ! -e "${ROOT}/app.specialists" ]
    [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ]
}

@test "start does not follow a symlink in an include source parent" {
    requires_symlinks
    mkdir "$ROOT/external"
    printf 'private\n' > "$ROOT/external/file.txt"
    ln -s "$ROOT/external" "$REPO/shared"
    printf 'shared/file.txt\n' > "$REPO/.worktreeinclude"
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: symlink in .worktreeinclude source for 'shared/file.txt': shared" ]
    [ ! -e "${ROOT}/app.specialists" ]
    [ -z "$(git -C "$REPO" branch --list 'specialist/*')" ]
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
    [ ! -e "$REPO/.worktreeinclude" ]
    run /bin/bash "$SPECIALIST" start "$REPO" sec-2 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field repo)" = "$(native_path "$REPO")" ]
    [ "$(field worktree)" = "$(native_path "${ROOT}/app.specialists/sec-2-20260923-151204")" ]
    [ "$(field branch)" = "specialist/sec-2/20260923-151204" ]
    [ "$(field base)" = "$(git -C "$REPO" rev-parse HEAD)" ]
    [ "$(field short)" = "$(git -C "$REPO" rev-parse --short=7 HEAD)" ]
    [ "$(field state)" = "$(native_path "${ROOT}/app.specialists/.state/sec-2-20260923-151204")" ]
    [ "$(field dirty)" = "no" ]
    [ -d "$(field state)" ]
}

@test "start reports a dirty main tree" {
    printf '# comment\n\n# another comment\n' > "$REPO/.worktreeinclude"
    git -C "$REPO" add .worktreeinclude
    git -C "$REPO" commit -qm includes
    echo 'two' >> "$REPO/src/a.txt"
    run /bin/bash "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 0 ]
    [ "$(field repo)" = "$(native_path "$REPO")" ]
    [ "$(field worktree)" = "$(native_path "${ROOT}/app.specialists/sec-20260923-151204")" ]
    [ "$(field branch)" = "specialist/sec/20260923-151204" ]
    [ "$(field base)" = "$(git -C "$REPO" rev-parse HEAD)" ]
    [ "$(field short)" = "$(git -C "$REPO" rev-parse --short=7 HEAD)" ]
    [ "$(field state)" = "$(native_path "${ROOT}/app.specialists/.state/sec-20260923-151204")" ]
    [ "$(field dirty)" = "yes" ]
    [ -d "$(field state)" ]
}

@test "start fails with git's message when the branch already exists, and creates nothing" {
    git -C "$REPO" branch specialist/sec/20260923-151204
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
    [ ! -e "${ROOT}/app.specialists" ]
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

@test "commit refuses a round that wrote into the hooks directory, before any hook runs" {
    git -C "$REPO" config core.hooksPath .husky/_
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    wt="$(field worktree)"
    mkdir -p "$wt/.husky/_"
    printf '*\n' > "$wt/.husky/_/.gitignore"
    printf '#!/bin/sh\ntouch "%s"\n' "${BATS_TEST_TMPDIR}/hook-ran" > "$wt/.husky/_/pre-commit"
    chmod +x "$wt/.husky/_/pre-commit"
    echo 'new' > "$wt/src/b.txt"
    run "$SPECIALIST" commit "$wt" "specialist sec: harden login"
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: refusing to commit: the round changed files git runs as hooks here: .husky/_/.gitignore .husky/_/pre-commit" ]
    [ ! -e "${BATS_TEST_TMPDIR}/hook-ran" ]
    [ "$(git -C "$wt" rev-list --count HEAD)" = "1" ]
}

@test "report shows the round, the total and the status" {
    run "$SPECIALIST" start "$REPO" sec 20260923-151204
    wt="$(field worktree)"; base="$(field base)"
    echo 'new' > "$wt/src/b.txt"
    "$SPECIALIST" commit "$wt" "round 1" >/dev/null
    round2="$("$SPECIALIST" head "$wt")"
    echo 'more' > "$wt/src/c.txt"
    "$SPECIALIST" commit "$wt" "round 2" >/dev/null
    echo 'dirty' >> "$wt/src/a.txt"
    run env COLUMNS=80 "$SPECIALIST" report "$wt" "$round2" "$base"
    [ "$status" -eq 0 ]
    expected="$(cat <<'EOF'
--- round
 src/c.txt | 1 +
 1 file changed, 1 insertion(+)
--- total
 src/b.txt | 1 +
 src/c.txt | 1 +
 2 files changed, 2 insertions(+)
--- status
 M src/a.txt
EOF
)"
    [ "$output" = "$expected" ]
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
    [ ! -e "$STATE" ]
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

@test "merge is refused while the worktree holds changes no round committed" {
    start_run
    echo 'b' > "$WT/src/b.txt"; "$SPECIALIST" commit "$WT" r1 >/dev/null
    echo 'edited' >> "$WT/src/a.txt"
    echo 'new' > "$WT/src/c.txt"
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 7 ]
    [ "$output" = "$(printf 'uncommitted=src/a.txt\nuncommitted=src/c.txt')" ]
    [ "$(cat "$WT/src/c.txt")" = "new" ]
    [ ! -f "$REPO/src/b.txt" ]
    git -C "$REPO" rev-parse --verify -q "$BR" >/dev/null
}

@test "merge is refused when the branch changes files git runs as hooks" {
    git -C "$REPO" config core.hooksPath .githooks
    start_run
    mkdir -p "$WT/.githooks"
    printf '#!/bin/sh\ntouch "%s"\n' "${BATS_TEST_TMPDIR}/hook-ran" > "$WT/.githooks/pre-merge-commit"
    chmod +x "$WT/.githooks/pre-merge-commit"
    git -C "$WT" add -A && git -C "$WT" -c core.hooksPath=/dev/null commit -qm hooks
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" merge
    [ "$status" -eq 8 ]
    [ "$output" = "hook=.githooks/pre-merge-commit" ]
    [ ! -e "${BATS_TEST_TMPDIR}/hook-ran" ]
    [ ! -e "$REPO/.githooks/pre-merge-commit" ]
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
    run "$SPECIALIST" finish "$REPO" "" "$BR" discard
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: invalid worktree path '': expected an absolute path ending in a run id" ]
    [ -d "$WT" ]
    [ -d "$STATE" ]
    git -C "$REPO" show-ref --verify --quiet "refs/heads/${BR}"
    run "$SPECIALIST" finish "$REPO" "relative/sec-20260923-151204" "$BR" merge
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: invalid worktree path 'relative/sec-20260923-151204': expected an absolute path ending in a run id" ]
    [ -d "$WT" ]
    [ -d "$STATE" ]
    git -C "$REPO" show-ref --verify --quiet "refs/heads/${BR}"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ]
    run "$SPECIALIST" finish "$REPO" "$WT" "$BR" discard
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
    [ ! -e "$STATE" ]
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

@test "claim lets exactly one caller close a round" {
    STATE="${ROOT}/app.specialists/.state/sec-20260923-151204"
    mkdir -p "$STATE"
    run "$SPECIALIST" claim "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "claimed=yes" ]
    run "$SPECIALIST" claim "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "claimed=no" ]
}

@test "claim takes over a claim left more than a minute ago by a closer that died" {
    STATE="${ROOT}/app.specialists/.state/sec-20260923-151204"
    mkdir -p "$STATE/closing"
    touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)" "$STATE/closing"
    run "$SPECIALIST" claim "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "claimed=yes" ]
    run "$SPECIALIST" claim "$STATE"
    [ "$output" = "claimed=no" ]
}

@test "claim closes a round whose state dir was removed by hand" {
    STATE="${ROOT}/app.specialists/.state/sec-20260923-151204"
    run "$SPECIALIST" claim "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "claimed=yes" ]
}

@test "identity prints a live process's start time and refuses a finished one" {
    run "$SPECIALIST" identity "$$"
    [ "$status" -eq 0 ]
    assert_not_blank "$output"
    sleep 0 &
    local gone=$!
    wait "$gone"
    run "$SPECIALIST" identity "$gone"
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: no start time for pid ${gone}" ]
    run "$SPECIALIST" identity 12x
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: invalid pid '12x'" ]
}

@test "codex refuses a missing worktree before starting anything" {
    run "$SPECIALIST" codex "${BATS_TEST_TMPDIR}/nope" "${BATS_TEST_TMPDIR}/state" gpt-6-sol '' 0 < /dev/null
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: no worktree at ${BATS_TEST_TMPDIR}/nope" ]
    # The effort goes into a -c value, so only Codex's own words get through.
    run "$SPECIALIST" codex "${BATS_TEST_TMPDIR}/nope" "${BATS_TEST_TMPDIR}/state" gpt-6-sol 'high" -c x="y' 0 < /dev/null
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: invalid effort 'high\" -c x=\"y': must be lowercase letters" ]
    [ ! -e "${BATS_TEST_TMPDIR}/state" ]
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

# A fake codex on PATH. Its body runs under /bin/sh with the round's argv.
fake_codex() {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\n%s\n' "$1" > "${BATS_TEST_TMPDIR}/bin/codex"
    chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
}

# Waits for the detached round to write its exit file: 100 ticks of 0.1 s.
wait_round() {
    local tick=0
    while [ ! -f "$STATE/exit" ] && [ "$tick" -lt 100 ]; do sleep 0.1; tick=$((tick + 1)); done
    [ -f "$STATE/exit" ]
}

launch() {
    PATH="${BATS_TEST_TMPDIR}/bin:/usr/bin:/bin" run "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol "${EFFORT:-}" "${LIMIT:-0}" "$@" <<< "the task"
}

@test "codex returns at once with the round's pid, and the round writes its exit code when codex ends" {
    start_run
    fake_codex "while [ ! -f '${BATS_TEST_TMPDIR}/go' ]; do sleep 0.1; done"
    launch
    [ "$status" -eq 0 ]
    local round_pid recorded_start observed_start
    round_pid="$(cat "$STATE/pid")"
    recorded_start="$(cat "$STATE/start")"
    observed_start="$("$SPECIALIST" identity "$round_pid")"
    [ "$output" = "pid=$round_pid" ]
    kill -0 "$round_pid"
    [ ! -e "$STATE/exit" ]
    [ -n "$recorded_start" ]
    [ "$recorded_start" = "$observed_start" ]
    touch "${BATS_TEST_TMPDIR}/go"
    wait_round
    [ "$(cat "$STATE/exit")" = "0" ]
}

@test "codex launch stops the round when its start time cannot be recorded" {
    [ ! -r /proc/self/stat ] || skip "procfs gives the start time, which a fake ps cannot hide"
    start_run
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    for code in 42 0; do
        printf '#!/bin/sh\nexit %s\n' "$code" > "${BATS_TEST_TMPDIR}/bin/ps"
        chmod +x "${BATS_TEST_TMPDIR}/bin/ps"
        launch
        local launch_status="$status" launch_output="$output" round_pid
        round_pid="$(cat "$STATE/pid")"
        [ "$launch_status" -ne 0 ]
        [ "$launch_output" = "specialist: could not record start time for round pid ${round_pid}" ]
        run kill -0 "$round_pid"
        [ "$status" -ne 0 ]
        [ ! -e "$STATE/codex-pid" ]
        [ ! -e "$STATE/start" ]
    done
}

@test "a codex that is not installed ends the round with exit 127" {
    start_run
    launch
    [ "$status" -eq 0 ]
    wait_round
    [ "$(cat "$STATE/exit")" = "127" ]
}

@test "the round keeps the thread id only when it is a UUID" {
    start_run
    fake_codex "echo '{\"type\":\"thread.started\",\"thread_id\":\"--dangerously-bypass-approvals-and-sandbox\"}'"
    launch
    wait_round
    [ "$(cat "$STATE/thread")" = "" ]
    rm -f "$STATE/exit"
    fake_codex "echo '{\"type\":\"thread.started\",\"thread_id\":\"01a0ce2a-1d08-76c0-a6ef-8340b581212d\"}'"
    launch
    wait_round
    [ "$(cat "$STATE/thread")" = "01a0ce2a-1d08-76c0-a6ef-8340b581212d" ]
}

@test "a follow-up round resumes the thread it is given" {
    start_run
    fake_codex "echo \"\$@\" > '${BATS_TEST_TMPDIR}/argv'"
    launch 01a0ce2a-1d08-76c0-a6ef-8340b581212d
    wait_round
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == "exec resume --json -m gpt-6-sol "*" 01a0ce2a-1d08-76c0-a6ef-8340b581212d -" ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" != *model_reasoning_effort* ]]
    # Short reasoning summaries give the pane something to show between commands.
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == *' -c model_reasoning_summary="concise" '* ]]
    # Commands Codex runs get only the core variables, none of the user's secrets.
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == *' -c shell_environment_policy.inherit="core" '* ]]
    # The last message is the report in the shape the pane parses. Codex runs in
    # the worktree, so the schema path must be absolute.
    schema="$(cd "$SCRIPTS_DIR" && pwd)/specialist-report.schema.json"
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == *" --output-schema ${schema} "* ]]
    [ "$(cat "$STATE/thread")" = "01a0ce2a-1d08-76c0-a6ef-8340b581212d" ]
    # A row's effort reaches Codex as its reasoning effort.
    rm -f "$STATE/exit"
    EFFORT=high launch
    wait_round
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == "exec --json -m gpt-6-sol "*" -c model_reasoning_effort=\"high\" "*"-" ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == *" --output-schema ${schema} "* ]]
    # Efforts outside the old fixed list reach Codex too.
    rm -f "$STATE/exit"
    EFFORT=ultra launch
    wait_round
    [[ "$(cat "${BATS_TEST_TMPDIR}/argv")" == *' -c model_reasoning_effort="ultra" '* ]]
}

@test "codex clears the previous round's files before it starts" {
    start_run
    mkdir -p "$STATE"
    for f in last-message.md stderr.txt exit thread reason; do echo 'round 1' > "$STATE/$f"; done
    mkdir "$STATE/closing"
    fake_codex "while [ ! -f '${BATS_TEST_TMPDIR}/go' ]; do sleep 0.1; done"
    launch
    for f in last-message.md exit thread reason closing; do [ ! -e "$STATE/$f" ] || return 1; done
    [ ! -s "$STATE/stderr.txt" ]
    touch "${BATS_TEST_TMPDIR}/go"
    wait_round
}

# Codex answers SIGTERM by exiting 0, which would pass for a finished round.
@test "a round past its time limit is ended, and says so whatever codex exits with" {
    start_run
    fake_codex "trap 'exit 0' TERM; while :; do sleep 0.1; done"
    LIMIT=1 launch
    [ "$status" -eq 0 ]
    wait_round
    [ "$(cat "$STATE/exit")" = "143" ]
    [ "$(cat "$STATE/reason")" = "timeout" ]
}

@test "stop ends a running round and records that it was asked to" {
    start_run
    fake_codex "trap 'exit 0' TERM; while :; do sleep 0.1; done"
    launch
    run "$SPECIALIST" stop "$STATE" "$(cat "$STATE/pid")" "$(cat "$STATE/start")"
    echo "stop said: $output"
    [ "$status" -eq 0 ]
    [ "$output" = "stopped=yes" ]
    wait_round
    [ "$(cat "$STATE/exit")" = "143" ]
    [ "$(cat "$STATE/reason")" = "stopped" ]
    run "$SPECIALIST" stop "$STATE" "$(cat "$STATE/pid")" "$(cat "$STATE/start")"
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: the round in ${STATE} has already ended" ]
}

# A stop confirmed for one round must not land on the next round in the same
# state dir, which a follow-up can start while the dialog is open.
@test "stop refuses when the running round is not the one it was asked to stop" {
    start_run
    fake_codex "exit 0"
    launch
    wait_round
    local first_pid first_start
    first_pid="$(cat "$STATE/pid")"; first_start="$(cat "$STATE/start")"
    fake_codex "trap 'exit 0' TERM; while :; do sleep 0.1; done"
    launch
    [ "$(cat "$STATE/pid")" != "$first_pid" ]
    run "$SPECIALIST" stop "$STATE" "$first_pid" "$first_start"
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: the round in ${STATE} is not the one asked to stop" ]
    [ ! -e "$STATE/reason" ]
    kill -0 "$(cat "$STATE/codex-pid")"
}

# A command Codex runs can ignore SIGTERM and outlive it; the round is over
# only once nothing it started is left writing to the worktree.
@test "an ended round's exit is written only after every process it started is gone" {
    start_run
    fake_codex "sh -c 'trap \"\" TERM; while :; do sleep 0.1; done' & echo \$! > '${BATS_TEST_TMPDIR}/child'; trap 'exit 0' TERM; while :; do sleep 0.1; done"
    LIMIT=1 launch
    wait_round
    [ "$(cat "$STATE/reason")" = "timeout" ]
    run kill -0 "$(cat "${BATS_TEST_TMPDIR}/child")"
    [ "$status" -ne 0 ]
}

@test "a round that ends inside its limit records no reason" {
    start_run
    fake_codex "exit 0"
    LIMIT=60 launch
    wait_round
    [ "$(cat "$STATE/exit")" = "0" ]
    [ ! -e "$STATE/reason" ]
}

@test "codex refuses a time limit that is not whole seconds" {
    start_run
    LIMIT=1m launch
    [ "$status" -eq 1 ]
    [ "$output" = "specialist: invalid time limit '1m': must be whole seconds, 0 for none" ]
}

@test "killing the codex pid ends the round with codex's exit code" {
    start_run
    fake_codex "echo \$\$ > '${BATS_TEST_TMPDIR}/seen-pid'; n=0; while [ \$n -lt 100 ]; do sleep 0.1; n=\$((n + 1)); done"
    launch
    local tick=0
    while [ ! -s "${BATS_TEST_TMPDIR}/seen-pid" ] && [ "$tick" -lt 100 ]; do sleep 0.1; tick=$((tick + 1)); done
    [ "$(cat "$STATE/codex-pid")" = "$(cat "${BATS_TEST_TMPDIR}/seen-pid")" ]
    kill "$(cat "$STATE/codex-pid")"
    wait_round
    [ "$(cat "$STATE/exit")" = "143" ]
}

@test "a round whose events repeat thread.started still ends with its thread and exit code" {
    start_run
    fake_codex "i=0; while [ \$i -lt 20000 ]; do echo '{\"type\":\"thread.started\",\"thread_id\":\"01a0ce2a-1d08-76c0-a6ef-8340b581212d\"}'; i=\$((i + 1)); done"
    launch
    wait_round
    [ "$(cat "$STATE/exit")" = "0" ]
    [ "$(cat "$STATE/thread")" = "01a0ce2a-1d08-76c0-a6ef-8340b581212d" ]
}

@test "codex receives the prompt on stdin" {
    start_run
    fake_codex "cat > '${BATS_TEST_TMPDIR}/seen-prompt'"
    printf 'line one\nline two' | PATH="${BATS_TEST_TMPDIR}/bin:/usr/bin:/bin" "$SPECIALIST" codex "$WT" "$STATE" gpt-6-sol '' 0 >/dev/null
    wait_round
    [ "$(cat "${BATS_TEST_TMPDIR}/seen-prompt")" = "$(printf 'line one\nline two')" ]
}
