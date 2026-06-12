#!/usr/bin/env bats
# ABOUTME: Tests for check-status.sh two-tier availability and remediation output
# ABOUTME: Hermetic via fake CLIs; API providers exercised only in keyless states

load test_helper
load fixtures/fake-clis

SCRIPT="${SCRIPTS_DIR}/check-status.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    unset_provider_keys
}

@test "fixture: --version succeeds even under auth-failure behavior" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run codex --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"fake-codex"* ]]
}

@test "check-status: authed CLI provider shows Connected" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex CLI"* ]]
    [[ "$output" == *"Connected"* ]]
}

@test "check-status: codex installed but unauthenticated is its own state" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed, not authenticated"* ]]
    [[ "$output" == *"codex login"* ]]
}

@test "check-status: unauthenticated codex is not counted available" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # gemini-cli (no auth probe) is the only available provider
    [[ "$output" == *"1/6 providers available"* ]]
}

@test "check-status: missing API key shows exact export remediation" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"export OPENAI_API_KEY="* ]]
    [[ "$output" == *"export PERPLEXITY_API_KEY="* ]]
}

@test "check-status: missing CLI binary shows install remediation" {
    # Drop the fakes (and any real CLIs) from PATH
    export PATH="/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm install -g @openai/codex"* ]]
    [[ "$output" == *"npm install -g @google/gemini-cli"* ]]
}
