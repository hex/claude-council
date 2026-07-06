#!/usr/bin/env bats
# ABOUTME: Tests for lib/export.sh — ANSI stripping and the --output export path
# ABOUTME: Covers both stdin and body-file forms plus the metadata header

load test_helper
bats_require_minimum_version 1.5.0

EXPORT="${LIB_DIR}/export.sh"

@test "export --strip: removes ANSI color codes from stdin" {
    run bash -c "printf '\033[36mcyan\033[0m plain' | bash '$EXPORT' --strip"
    [ "$status" -eq 0 ]
    [ "$output" = "cyan plain" ]
}

@test "export --write: emits a metadata header with query and providers" {
    local out="${BATS_TEST_TMPDIR}/out.md"
    printf 'body line' | bash "$EXPORT" --write "$out" "my question" "gemini openai"
    [ -f "$out" ]
    grep -qF "# Council Response" "$out"
    grep -qF "my question" "$out"
    grep -qF "gemini openai" "$out"
}

@test "export --write: reads the body from stdin when no body file is given" {
    local out="${BATS_TEST_TMPDIR}/out.md"
    printf 'STDIN_BODY_MARKER' | bash "$EXPORT" --write "$out" "q" "gemini"
    grep -qF "STDIN_BODY_MARKER" "$out"
}

@test "export --write: reads the body from a file when the 5th arg is given" {
    local body="${BATS_TEST_TMPDIR}/transcript.md" out="${BATS_TEST_TMPDIR}/out.md"
    printf '\033[36mProvider answer\033[0m\nFILE_BODY_MARKER' > "$body"
    run bash "$EXPORT" --write "$out" "q" "gemini" "$body"
    [ "$status" -eq 0 ]
    grep -qF "FILE_BODY_MARKER" "$out"
    # the transcript's ANSI is stripped in the export
    ! grep -q $'\033' "$out"
}

@test "export --write: errors clearly when the body file is missing" {
    local out="${BATS_TEST_TMPDIR}/out.md"
    run bash "$EXPORT" --write "$out" "q" "gemini" "/no/such/file.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"body file not found"* ]]
}
