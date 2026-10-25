#!/usr/bin/env bats
# ABOUTME: Tests for seat-info.sh, the pane mod's three seat questions
# ABOUTME: Runs the real script with no provider keys or CLIs, so only the keys a test sets count

load test_helper

SCRIPT="${SCRIPTS_DIR}/seat-info.sh"

setup() {
    unset_provider_keys
    PATH="$(path_without_clis)"
    export PATH
    export HOME="$BATS_TEST_TMPDIR"
}

seat_info() {
    env "$@"
}

@test "discover: lists the provider whose key is set, and nothing else" {
    run seat_info GEMINI_API_KEY=k "$HOST_BASH" "$SCRIPT" discover
    [ "$status" -eq 0 ]
    [ "$output" = "gemini" ]
}

@test "discover: an XAI key alone seats grok, as a council run resolves it" {
    run seat_info XAI_API_KEY=k "$HOST_BASH" "$SCRIPT" discover
    [ "$status" -eq 0 ]
    [ "$output" = "grok" ]
}

@test "discover: no keys and no CLIs prints nothing and still succeeds" {
    run seat_info "$HOST_BASH" "$SCRIPT" discover
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "model: prints the seat's model as the runner resolves it, override included" {
    run seat_info "$HOST_BASH" "$SCRIPT" model gemini
    [ "$status" -eq 0 ]
    [ "$output" = "gemini-flash-latest" ]

    run seat_info OPENAI_MODEL=gpt-test "$HOST_BASH" "$SCRIPT" model openai
    [ "$status" -eq 0 ]
    [ "$output" = "gpt-test" ]
}

@test "allowlisted: exit 0 for a council provider" {
    run seat_info "$HOST_BASH" "$SCRIPT" allowlisted codex
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "allowlisted: exit 1 for an unknown name, a path and a name with a space" {
    for name in nosuchseat ../codex 'co dex'; do
        run seat_info "$HOST_BASH" "$SCRIPT" allowlisted "$name"
        [ "$status" -eq 1 ] || { echo "allowlisted '$name' exited $status"; return 1; }
    done
}

@test "usage: a missing, unknown or extra argument exits 2 with the usage line" {
    local expected="Usage: seat-info.sh discover | model SEAT | allowlisted SEAT"
    run seat_info "$HOST_BASH" "$SCRIPT"
    [ "$status" -eq 2 ]
    [ "$output" = "$expected" ]

    run seat_info "$HOST_BASH" "$SCRIPT" list
    [ "$status" -eq 2 ]
    [ "$output" = "$expected" ]

    run seat_info "$HOST_BASH" "$SCRIPT" model
    [ "$status" -eq 2 ]
    [ "$output" = "$expected" ]

    run seat_info "$HOST_BASH" "$SCRIPT" discover extra
    [ "$status" -eq 2 ]
    [ "$output" = "$expected" ]
}
