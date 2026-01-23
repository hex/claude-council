#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/cache.sh
# ABOUTME: Validates caching, TTL, key generation, and cache operations

load test_helper

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    source "${LIB_DIR}/cache.sh"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# ============================================================================
# cache_key tests
# ============================================================================

@test "cache_key: generates consistent hash for same inputs" {
    local key1=$(cache_key "gemini" "gemini-3-flash" "test prompt")
    local key2=$(cache_key "gemini" "gemini-3-flash" "test prompt")

    [ "$key1" = "$key2" ]
}

@test "cache_key: generates different hash for different providers" {
    local key1=$(cache_key "gemini" "model" "prompt")
    local key2=$(cache_key "openai" "model" "prompt")

    [ "$key1" != "$key2" ]
}

@test "cache_key: generates different hash for different models" {
    local key1=$(cache_key "gemini" "model-a" "prompt")
    local key2=$(cache_key "gemini" "model-b" "prompt")

    [ "$key1" != "$key2" ]
}

@test "cache_key: generates different hash for different prompts" {
    local key1=$(cache_key "gemini" "model" "prompt 1")
    local key2=$(cache_key "gemini" "model" "prompt 2")

    [ "$key1" != "$key2" ]
}

@test "cache_key: returns 64-character SHA256 hash" {
    local key=$(cache_key "provider" "model" "prompt")

    [ ${#key} -eq 64 ]
}

# ============================================================================
# cache_set / cache_get tests
# ============================================================================

@test "cache_set: stores response in cache directory" {
    local key=$(cache_key "gemini" "model" "prompt")
    cache_set "$key" "gemini" "model" "prompt" "test response"

    [ -f "${TEST_CACHE_DIR}/${key}.json" ]
}

@test "cache_get: retrieves stored response" {
    local key=$(cache_key "gemini" "model" "prompt")
    cache_set "$key" "gemini" "model" "prompt" "test response"

    local result=$(cache_get "$key")
    [ "$result" = "test response" ]
}

@test "cache_get: returns empty for missing key" {
    local result=$(cache_get "nonexistent_key")

    [ -z "$result" ]
}

@test "cache_set: stores metadata with response" {
    local key=$(cache_key "gemini" "model" "prompt")
    cache_set "$key" "gemini" "model" "prompt" "response"

    local cache_file="${TEST_CACHE_DIR}/${key}.json"
    local provider=$(jq -r '.provider' "$cache_file")
    local model=$(jq -r '.model' "$cache_file")

    [ "$provider" = "gemini" ]
    [ "$model" = "model" ]
}

@test "cache_set: stores timestamp" {
    local key=$(cache_key "gemini" "model" "prompt")
    local before=$(date +%s)
    cache_set "$key" "gemini" "model" "prompt" "response"
    local after=$(date +%s)

    local cache_file="${TEST_CACHE_DIR}/${key}.json"
    local timestamp=$(jq -r '.timestamp' "$cache_file")

    [ "$timestamp" -ge "$before" ]
    [ "$timestamp" -le "$after" ]
}

# ============================================================================
# cache_valid tests
# ============================================================================

@test "cache_valid: returns 0 for fresh cache entry" {
    local key=$(cache_key "gemini" "model" "prompt")
    cache_set "$key" "gemini" "model" "prompt" "response"

    cache_valid "$key"
}

@test "cache_valid: returns 1 for missing entry" {
    run cache_valid "nonexistent_key"
    [ "$status" -eq 1 ]
}

@test "cache_valid: returns 1 for expired entry" {
    export COUNCIL_CACHE_TTL=1
    local key=$(cache_key "gemini" "model" "prompt")
    cache_set "$key" "gemini" "model" "prompt" "response"

    # Backdate the timestamp
    local cache_file="${TEST_CACHE_DIR}/${key}.json"
    local old_ts=$(($(date +%s) - 10))
    local content=$(cat "$cache_file")
    echo "$content" | jq --argjson ts "$old_ts" '.timestamp = $ts' > "$cache_file"

    run cache_valid "$key"
    [ "$status" -eq 1 ]
}

# ============================================================================
# cache_clear tests
# ============================================================================

@test "cache_clear: removes all cache entries" {
    local key1=$(cache_key "gemini" "model" "prompt1")
    local key2=$(cache_key "openai" "model" "prompt2")
    cache_set "$key1" "gemini" "model" "prompt1" "response1"
    cache_set "$key2" "openai" "model" "prompt2" "response2"

    cache_clear

    local count=$(ls -1 "${TEST_CACHE_DIR}"/*.json 2>/dev/null | wc -l)
    [ "$count" -eq 0 ]
}

@test "cache_clear: handles empty cache gracefully" {
    cache_clear
    # Should not error
    [ $? -eq 0 ]
}

# ============================================================================
# ensure_cache_dir tests
# ============================================================================

@test "ensure_cache_dir: creates directory if missing" {
    rm -rf "$TEST_CACHE_DIR"
    ensure_cache_dir

    [ -d "$TEST_CACHE_DIR" ]
}

@test "ensure_cache_dir: succeeds if directory exists" {
    mkdir -p "$TEST_CACHE_DIR"
    ensure_cache_dir

    [ -d "$TEST_CACHE_DIR" ]
}
