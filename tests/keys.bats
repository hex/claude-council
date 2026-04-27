#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/keys.sh
# ABOUTME: Validates XAI_API_KEY / GROK_API_KEY resolution and precedence

load test_helper

LIB="${LIB_DIR}/keys.sh"

setup() {
    unset GROK_API_KEY XAI_API_KEY
}

@test "keys: resolve_grok_key is a no-op when neither var is set" {
    source "$LIB"
    resolve_grok_key
    [ -z "${GROK_API_KEY:-}" ]
}

@test "keys: GROK_API_KEY alone is preserved" {
    export GROK_API_KEY="grok-only"
    source "$LIB"
    resolve_grok_key
    [ "$GROK_API_KEY" = "grok-only" ]
}

@test "keys: XAI_API_KEY alone populates GROK_API_KEY" {
    export XAI_API_KEY="xai-only"
    source "$LIB"
    resolve_grok_key
    [ "$GROK_API_KEY" = "xai-only" ]
}

@test "keys: XAI_API_KEY wins when both are set" {
    export GROK_API_KEY="legacy-grok"
    export XAI_API_KEY="canonical-xai"
    source "$LIB"
    resolve_grok_key
    [ "$GROK_API_KEY" = "canonical-xai" ]
}

@test "keys: matching values are silently coalesced" {
    export GROK_API_KEY="same"
    export XAI_API_KEY="same"
    source "$LIB"
    run resolve_grok_key
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "keys: differing values do not warn (silent policy)" {
    export GROK_API_KEY="grok"
    export XAI_API_KEY="xai"
    source "$LIB"
    run resolve_grok_key
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "keys: GROK_API_KEY is exported (visible to subprocesses)" {
    export XAI_API_KEY="from-xai"
    source "$LIB"
    resolve_grok_key
    run bash -c 'echo "$GROK_API_KEY"'
    [ "$output" = "from-xai" ]
}
