#!/usr/bin/env bats
# ABOUTME: Hermetic CLI-provider tests driven by fake codex/gemini binaries on PATH
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

@test "fixture: fake gemini shadows any real gemini on PATH" {
    run command -v gemini
    [ "$status" -eq 0 ]
    [[ "$output" == "$FAKE_BIN_DIR/gemini" ]]
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
# gemini-cli.sh against the fake binary
# ============================================================================

@test "gemini-cli.sh: returns fake response on valid behavior" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run "${PROVIDERS_DIR_REAL}/gemini-cli.sh" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAKE-GEMINI-RESPONSE"* ]]
}

@test "gemini-cli.sh: sends --skip-trust, model flag, and -p prompt to the CLI" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    export GEMINI_CLI_MODEL="test-model-y"
    run "${PROVIDERS_DIR_REAL}/gemini-cli.sh" "another question"
    [ "$status" -eq 0 ]
    local call
    call=$(tail -1 "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    assert_json_eq "$call" '.bin' "gemini"
    [[ "$(echo "$call" | jq -r '.args | index("--skip-trust")')" != "null" ]]
    [[ "$(echo "$call" | jq -r '.args | index("-m") as $i | .[$i+1]')" == "test-model-y" ]]
    [[ "$(echo "$call" | jq -r '.args | index("-p") as $i | .[$i+1]')" == *"another question"* ]]
}

@test "gemini-cli.sh: surfaces stderr and exits 1 on auth-failure behavior" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run "${PROVIDERS_DIR_REAL}/gemini-cli.sh" "test prompt"
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
    [[ "$output" == *"gemini-cli"* ]]
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
