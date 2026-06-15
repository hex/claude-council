#!/usr/bin/env bats
# ABOUTME: Tests for codex/gemini-cli provider integration and CLI-prefers-API policy
# ABOUTME: Covers lib/providers.sh discovery + filter, plus query-council.sh wiring

load test_helper

SCRIPT="${SCRIPTS_DIR}/query-council.sh"
PROVIDERS_LIB="${LIB_DIR}/providers.sh"
PROVIDERS_DIR_REAL="${SCRIPTS_DIR}/providers"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset_provider_keys
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
    assert_blank "$output"
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
# coerce_result_json — collection-loop JSON guard (issue #3)
#
# The result-collection loop reads provider output files and feeds them to
# `jq --argjson`. Under `set -e`, a single invalid-JSON file aborts the whole
# council run. coerce_result_json guarantees valid JSON (merging .model) so one
# misbehaving provider can no longer take down every other provider's result.
# ============================================================================

@test "coerce_result_json: valid JSON passes through with model merged" {
    run source_lib_and_call $'coerce_result_json \'{"status":"success","response":"hi"}\' gpt-5'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.response')" == "hi" ]]
    [[ "$(echo "$output" | jq -r '.model')" == "gpt-5" ]]
}

@test "coerce_result_json: invalid JSON is coerced to an error result, not a crash" {
    # ANSI-coloured plain text — exactly the agy-provider repro from issue #3.
    run source_lib_and_call $'coerce_result_json "$(printf \'\\033[33mconnection refused\\033[0m\')" gemini-2.5-flash'
    [ "$status" -eq 0 ]
    # Output is itself valid JSON (so --argjson downstream cannot crash)
    echo "$output" | jq empty
    [[ "$(echo "$output" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$output" | jq -r '.error')" == *"invalid JSON"* ]]
    [[ "$(echo "$output" | jq -r '.model')" == "gemini-2.5-flash" ]]
}

@test "coerce_result_json: empty input is coerced to an error result" {
    run source_lib_and_call 'coerce_result_json "" some-model'
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
    [[ "$(echo "$output" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$output" | jq -r '.model')" == "some-model" ]]
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

@test "query-council: --list-available annotates shadowed API providers" {
    # When both OPENAI_API_KEY and codex are present, the human-readable
    # listing must show codex in the default set AND openai in the shadowed
    # section so the user can see both exist.
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    export OPENAI_API_KEY="test-key"
    run bash "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    [[ "$output" == *"Default query set"* ]]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"Shadowed"* ]]
    [[ "$output" == *"openai"* ]]
}

@test "query-council: --list-default returns post-policy set, machine-readable" {
    # Single space-separated line; CLI siblings drop their API counterparts.
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    export OPENAI_API_KEY="test-key"
    run bash "$SCRIPT" --list-default
    [ "$status" -eq 0 ]
    # Exactly one line of output
    [[ $(echo "$output" | wc -l | tr -d ' ') == "1" ]]
    [[ "$output" == *"codex"* ]]
    # openai is shadowed, must not appear
    [[ ! "$output" =~ (^|[[:space:]])openai([[:space:]]|$) ]]
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

# ============================================================================
# Real-CLI guard validation — runs whenever the real gemini is present.
# Exercises the --skip-trust version guard against the actual installed CLI:
# a wrong decision surfaces as an "Unknown argument: skip-trust" abort. Gated
# on presence (not COUNCIL_E2E) so the guard is checked against the real CLI
# on any machine that has it.
# ============================================================================

@test "gemini-cli.sh: real gemini accepts the args we send (skip-trust guard)" {
    if ! command_exists gemini; then skip "gemini CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/gemini-cli.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Unknown argument"* ]]
    [[ "$output" == *"OK"* ]]
}
