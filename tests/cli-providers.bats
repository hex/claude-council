#!/usr/bin/env bats
# ABOUTME: Tests for codex/gemini-cli provider integration and CLI-prefers-API policy
# ABOUTME: Covers lib/providers.sh discovery + filter, plus query-council.sh wiring

load test_helper

SCRIPT="${SCRIPTS_DIR}/query-council.sh"
PROVIDERS_LIB="${LIB_DIR}/providers.sh"
PROVIDERS_DIR_REAL="${SCRIPTS_DIR}/providers"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY PERPLEXITY_API_KEY
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# Source the lib in a subshell with PROVIDERS_DIR pointing at the real
# providers directory. Returns the function output to the bats `run` capture.
source_lib_and_call() {
    bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        $*
    "
}

# ============================================================================
# discover_providers — binary-gated CLI providers
# ============================================================================

@test "discover_providers: includes codex when binary is on PATH" {
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
}

@test "discover_providers: includes gemini-cli when gemini binary is on PATH" {
    if ! command_exists gemini; then skip "gemini CLI not installed"; fi
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"gemini-cli"* ]]
}

@test "discover_providers: excludes codex when binary is missing" {
    # Strip codex from PATH by running with a minimal PATH
    run bash -c "
        set -euo pipefail
        export PATH=/usr/bin:/bin
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        discover_providers
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"codex"* ]]
    [[ "$output" != *"gemini-cli"* ]]
}

@test "discover_providers: excludes API providers when keys unset" {
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" != *"openai"* ]]
    [[ "$output" != *"perplexity"* ]]
}

@test "discover_providers: includes openai when OPENAI_API_KEY is set" {
    export OPENAI_API_KEY="test-key"
    run bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        export OPENAI_API_KEY='test-key'
        source '${PROVIDERS_LIB}'
        discover_providers
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai"* ]]
}

# ============================================================================
# prefer_cli_over_api — CLI-prefers-API policy
#
# These tests intentionally fail against the identity stub at lib/providers.sh.
# Alex's implementation of the policy turns them green. Per TDD: write the
# spec first, then the code.
# ============================================================================

@test "prefer_cli_over_api: identity when input is empty" {
    run source_lib_and_call 'prefer_cli_over_api'
    [ "$status" -eq 0 ]
    [[ -z "$(echo -n "$output" | tr -d '[:space:]')" ]]
}

@test "prefer_cli_over_api: identity when neither CLI is in input" {
    run source_lib_and_call 'prefer_cli_over_api openai gemini perplexity'
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai"* ]]
    [[ "$output" == *"gemini"* ]]
    [[ "$output" == *"perplexity"* ]]
}

@test "prefer_cli_over_api: drops openai when codex is present" {
    run source_lib_and_call 'prefer_cli_over_api codex openai grok'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"grok"* ]]
    [[ "$output" != *"openai"* ]]
}

@test "prefer_cli_over_api: drops gemini when gemini-cli is present" {
    run source_lib_and_call 'prefer_cli_over_api gemini-cli gemini perplexity'
    [ "$status" -eq 0 ]
    [[ "$output" == *"gemini-cli"* ]]
    [[ "$output" == *"perplexity"* ]]
    # The policy drops the API "gemini" but keeps "gemini-cli". A loose
    # substring match would falsely succeed (gemini-cli contains "gemini"),
    # so check word boundaries.
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}

@test "prefer_cli_over_api: drops both API siblings when both CLIs present" {
    run source_lib_and_call 'prefer_cli_over_api codex gemini-cli openai gemini grok'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"gemini-cli"* ]]
    [[ "$output" == *"grok"* ]]
    [[ "$output" != *"openai"* ]]
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}

@test "prefer_cli_over_api: preserves input order" {
    run source_lib_and_call 'prefer_cli_over_api perplexity codex grok'
    [ "$status" -eq 0 ]
    # Expect "perplexity codex grok" — order preserved, nothing dropped
    [[ "$output" =~ perplexity[[:space:]]+codex[[:space:]]+grok ]]
}

# ============================================================================
# query-council.sh integration
# ============================================================================

@test "query-council: --list-available shows CLI providers when binaries present" {
    if ! command_exists codex && ! command_exists gemini; then
        skip "no CLI providers installed on this machine"
    fi
    run bash "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    if command_exists codex; then
        [[ "$output" == *"codex"* ]]
    fi
    if command_exists gemini; then
        [[ "$output" == *"gemini-cli"* ]]
    fi
}

@test "query-council: --providers codex flag is accepted" {
    run bash "$SCRIPT" --providers=codex "test prompt" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

@test "query-council: --providers gemini-cli flag is accepted" {
    run bash "$SCRIPT" --providers=gemini-cli "test prompt" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

# ============================================================================
# End-to-end CLI provider invocation (gated — set COUNCIL_E2E=1 to run)
# ============================================================================

@test "codex.sh: returns response for trivial prompt (E2E)" {
    [[ "${COUNCIL_E2E:-}" == "1" ]] || skip "set COUNCIL_E2E=1 to run real CLI calls"
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/codex.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "gemini-cli.sh: returns response for trivial prompt (E2E)" {
    [[ "${COUNCIL_E2E:-}" == "1" ]] || skip "set COUNCIL_E2E=1 to run real CLI calls"
    if ! command_exists gemini; then skip "gemini CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/gemini-cli.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
