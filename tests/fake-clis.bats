#!/usr/bin/env bats
# ABOUTME: Hermetic CLI-provider tests driven by fake codex/agy binaries on PATH
# ABOUTME: Fixture installs real executables; behavior switches via COUNCIL_FAKE_BEHAVIOR

load test_helper
load fixtures/fake-clis

PROVIDERS_DIR_REAL="${SCRIPTS_DIR}/providers"
PROVIDERS_LIB="${LIB_DIR}/providers.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# ============================================================================
# Fixture self-checks
# ============================================================================

@test "fixture: fake codex shadows any real codex on PATH" {
    run command -v codex
    [ "$status" -eq 0 ]
    [[ "$output" == "$FAKE_BIN_DIR/codex" ]]
}

@test "fixture: fake agy shadows any real agy on PATH" {
    run command -v agy
    [ "$status" -eq 0 ]
    [[ "$output" == "$FAKE_BIN_DIR/agy" ]]
}

# ============================================================================
# codex.sh against the fake binary
# ============================================================================

@test "codex.sh: returns fake response on valid behavior" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run "${PROVIDERS_DIR_REAL}/codex.sh" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAKE-CODEX-RESPONSE"* ]]
}

@test "codex.sh: sends exec subcommand, model flag, and user prompt to the CLI" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    export CODEX_MODEL="test-model-x"
    run "${PROVIDERS_DIR_REAL}/codex.sh" "the user question"
    [ "$status" -eq 0 ]
    local call
    call=$(tail -1 "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    assert_json_eq "$call" '.bin' "codex"
    assert_json_eq "$call" '.args[0]' "exec"
    [[ "$(echo "$call" | jq -r '.args | index("-m") as $i | .[$i+1]')" == "test-model-x" ]]
    # The prompt is the final argument and embeds the user question
    [[ "$(echo "$call" | jq -r '.args[-1]')" == *"the user question"* ]]
}

@test "codex.sh: pins a read-only sandbox so a permissive user config can't grant write access" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run "${PROVIDERS_DIR_REAL}/codex.sh" "the user question"
    [ "$status" -eq 0 ]
    local call
    call=$(tail -1 "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    [[ "$(echo "$call" | jq -r '.args | index("-s") as $i | .[$i+1]')" == "read-only" ]]
}

@test "codex.sh: a hung CLI is bounded by COUNCIL_TIMEOUT and reports a timeout" {
    export COUNCIL_FAKE_BEHAVIOR=hang COUNCIL_FAKE_SLEEP=30 COUNCIL_TIMEOUT=1
    local start end
    start=$SECONDS
    run --separate-stderr "${PROVIDERS_DIR_REAL}/codex.sh" "test prompt"
    end=$SECONDS
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"timed out"* ]]
    [ $((end - start)) -lt 10 ]
}

@test "codex.sh: surfaces stderr and exits 1 on rate-limit behavior" {
    export COUNCIL_FAKE_BEHAVIOR=rate-limit
    run "${PROVIDERS_DIR_REAL}/codex.sh" "test prompt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"429"* ]]
}

@test "codex.sh: empty response passes through with exit 0" {
    export COUNCIL_FAKE_BEHAVIOR=empty
    run "${PROVIDERS_DIR_REAL}/codex.sh" "test prompt"
    [ "$status" -eq 0 ]
    assert_blank "$output"
}

# ============================================================================
# antigravity.sh against the fake binary
# ============================================================================

@test "antigravity.sh: returns fake response on valid behavior" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAKE-AGY-RESPONSE"* ]]
}

@test "antigravity.sh: sends --sandbox, model flag, and -p prompt with guard, flags before prompt" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    export ANTIGRAVITY_MODEL="test-model-z"
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "another question"
    [ "$status" -eq 0 ]
    local call
    call=$(tail -1 "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    assert_json_eq "$call" '.bin' "agy"
    [[ "$(echo "$call" | jq -r '.args[0]')" == "--sandbox" ]]
    [[ "$(echo "$call" | jq -r '.args | index("--model") as $i | .[$i+1]')" == "test-model-z" ]]
    # -p is the last flag; the prompt is the final positional arg and carries the guard
    [[ "$(echo "$call" | jq -r '.args[-2]')" == "-p" ]]
    [[ "$(echo "$call" | jq -r '.args[-1]')" == *"another question"* ]]
    [[ "$(echo "$call" | jq -r '.args[-1]')" == *"Do NOT use any tools"* ]]
}

@test "antigravity.sh: a hung CLI is bounded by COUNCIL_TIMEOUT and reports a timeout" {
    export COUNCIL_FAKE_BEHAVIOR=hang COUNCIL_FAKE_SLEEP=30 COUNCIL_TIMEOUT=1
    local start end
    start=$SECONDS
    run --separate-stderr "${PROVIDERS_DIR_REAL}/antigravity.sh" "test prompt"
    end=$SECONDS
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"timed out"* ]]
    [ $((end - start)) -lt 10 ]
}

@test "antigravity.sh: surfaces stderr and exits 1 on auth-failure behavior" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "test prompt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not logged in"* ]]
}

# ============================================================================
# Discovery with fakes — replaces skip-gated coverage
# ============================================================================

@test "discover_providers: includes both CLI providers with fakes on PATH" {
    run bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        discover_providers
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"antigravity"* ]]
}

@test "fixture: slow behavior delays the response" {
    export COUNCIL_FAKE_BEHAVIOR=slow
    export COUNCIL_FAKE_SLEEP=1
    local start end
    start=$SECONDS
    run "${PROVIDERS_DIR_REAL}/codex.sh" "test prompt"
    end=$SECONDS
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAKE-CODEX-RESPONSE"* ]]
    [ $((end - start)) -ge 1 ]
}
