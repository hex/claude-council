#!/usr/bin/env bats
# ABOUTME: Tests for session-transcript.sh, which resolves a session id to its file
# ABOUTME: Resolution is separate from digesting so the privacy gate has a seam

load test_helper

SCRIPT="${SCRIPTS_DIR}/session-transcript.sh"

UUID="8a8907bc-ee8c-46ee-ac12-dbeb35057a10"

@test "resolve: a session id maps to its transcript under any project dir" {
    local root="${BATS_TEST_TMPDIR}/projects"
    mkdir -p "$root/-Users-someone-repo"
    echo '{}' > "$root/-Users-someone-repo/${UUID}.jsonl"

    run "$HOST_BASH" "$SCRIPT" --projects-dir "$root" "$UUID"
    [ "$status" -eq 0 ]
    [[ "$output" == "$root/-Users-someone-repo/${UUID}.jsonl" ]]
}

@test "resolve: an unknown session id fails loudly rather than printing nothing" {
    local root="${BATS_TEST_TMPDIR}/projects"
    mkdir -p "$root/-Users-someone-repo"

    run "$HOST_BASH" "$SCRIPT" --projects-dir "$root" "$UUID"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$UUID"* ]]
}

@test "resolve: the same id in two project dirs is refused, not guessed" {
    local root="${BATS_TEST_TMPDIR}/projects"
    mkdir -p "$root/-Users-someone-repo" "$root/-private-tmp-repo"
    echo '{}' > "$root/-Users-someone-repo/${UUID}.jsonl"
    echo '{}' > "$root/-private-tmp-repo/${UUID}.jsonl"

    # Measured unambiguous across the reference corpus, but the digest is sent
    # to third parties: picking one of two candidates is not a call to make.
    run "$HOST_BASH" "$SCRIPT" --projects-dir "$root" "$UUID"
    [ "$status" -ne 0 ]
    [[ "$output" == *"more than one"* ]]
}

@test "resolve: something that is not a session id is refused" {
    run "$HOST_BASH" "$SCRIPT" --projects-dir "${BATS_TEST_TMPDIR}" "../../etc/passwd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"session id"* ]]
}
