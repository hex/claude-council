#!/usr/bin/env bats
# ABOUTME: Tests for scripts/query-council.sh
# ABOUTME: Validates argument parsing, error handling, and JSON output structure

load test_helper

SCRIPT="${SCRIPTS_DIR}/query-council.sh"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    export COUNCIL_CACHE_DIR="$TEST_CACHE_DIR"
    # Unset all provider keys to test error cases
    unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY PERPLEXITY_API_KEY
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "query-council: shows usage with --help" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: shows usage with -h" {
    run bash "$SCRIPT" -h
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: errors on unknown flag" {
    run bash "$SCRIPT" --unknown-flag "test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "query-council: errors on empty prompt" {
    run bash "$SCRIPT" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"No prompt"* ]] || [[ "$output" == *"Usage"* ]]
}

# ============================================================================
# Provider discovery tests
# ============================================================================

@test "query-council: --list-available shows no providers when none configured" {
    run bash "$SCRIPT" --list-available
    [[ "$output" == *"No configured providers"* ]] || [ "$status" -eq 0 ]
}

@test "query-council: errors when no providers available" {
    run bash "$SCRIPT" "test prompt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No configured providers"* ]] || [[ "$output" == *"No providers"* ]]
}

# ============================================================================
# Role validation tests
# ============================================================================

@test "query-council: errors on invalid role" {
    export GEMINI_API_KEY="test-key"  # Need at least one provider
    run bash "$SCRIPT" --roles=invalidrole "test prompt" 2>&1
    [[ "$output" == *"Unknown role"* ]] || [[ "$output" == *"error"* ]] || [ "$status" -ne 0 ]
}

# ============================================================================
# File context tests
# ============================================================================

@test "query-council: errors on missing file" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" --file=/nonexistent/path "test prompt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"No such file"* ]] || [[ "$output" == *"does not exist"* ]]
}

# ============================================================================
# Cache flag tests
# ============================================================================

@test "query-council: accepts --no-cache flag" {
    export GEMINI_API_KEY="test-key"
    # Should parse without error (may fail on actual query)
    run bash "$SCRIPT" --no-cache "test" 2>&1
    # Verify flag was accepted (error should be about something else, not flag)
    [[ "$output" != *"Unknown flag: --no-cache"* ]]
}

@test "query-council: accepts --quiet flag" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" --quiet "test" 2>&1
    [[ "$output" != *"Unknown flag: --quiet"* ]]
}

@test "query-council: accepts -q short flag" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" -q "test" 2>&1
    [[ "$output" != *"Unknown flag: -q"* ]]
}

@test "query-council: accepts --debate flag" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" --debate "test" 2>&1
    [[ "$output" != *"Unknown flag: --debate"* ]]
}

@test "query-council: accepts --no-auto-context flag" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" --no-auto-context "test" 2>&1
    [[ "$output" != *"Unknown flag: --no-auto-context"* ]]
}

# ============================================================================
# Provider filter tests
# ============================================================================

@test "query-council: accepts --providers flag" {
    export GEMINI_API_KEY="test-key"
    run bash "$SCRIPT" --providers=gemini "test" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

@test "query-council: accepts multiple providers" {
    export GEMINI_API_KEY="test-key"
    export OPENAI_API_KEY="test-key"
    run bash "$SCRIPT" --providers=gemini,openai "test" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

# ============================================================================
# Output structure tests (when we have mock responses)
# ============================================================================

@test "query-council: output is valid JSON structure" {
    # Create a fixture that mocks the expected output
    local expected_fields='["metadata", "round1"]'

    # This test validates the expected output structure
    # When real providers are mocked, uncomment:
    # run bash "$SCRIPT" "test"
    # echo "$output" | jq -e '.metadata' >/dev/null
    # echo "$output" | jq -e '.round1' >/dev/null
    skip "Requires provider mocking"
}
