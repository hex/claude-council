#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/tokens.sh
# ABOUTME: Validates the reasoning-model token bump helper

load test_helper

LIB="${LIB_DIR}/tokens.sh"

setup() {
    unset BUMPED
}

@test "tokens: bump_for_reasoning bumps to 32768 for gemini-3*" {
    source "$LIB"
    bump_for_reasoning BUMPED "gemini-3.1-pro-preview" 2048 'gemini-3*' '*thinking*'
    [ "$BUMPED" = "32768" ]
}

@test "tokens: bump_for_reasoning leaves base for non-matching models" {
    source "$LIB"
    bump_for_reasoning BUMPED "gemini-1.5-pro" 2048 'gemini-3*' '*thinking*'
    [ "$BUMPED" = "2048" ]
}

@test "tokens: bump_for_reasoning matches *reasoning* glob" {
    source "$LIB"
    bump_for_reasoning BUMPED "grok-4.20-reasoning" 2048 '*reasoning*'
    [ "$BUMPED" = "32768" ]
}

@test "tokens: bump_for_reasoning matches sonar-reasoning prefix" {
    source "$LIB"
    bump_for_reasoning BUMPED "sonar-reasoning-pro" 2048 'sonar-reasoning*'
    [ "$BUMPED" = "32768" ]
}

@test "tokens: bump_for_reasoning leaves sonar (non-reasoning) alone" {
    source "$LIB"
    bump_for_reasoning BUMPED "sonar" 2048 'sonar-reasoning*'
    [ "$BUMPED" = "2048" ]
}

@test "tokens: bump_for_reasoning uses 8x base when 8x exceeds 32768" {
    source "$LIB"
    bump_for_reasoning BUMPED "gemini-3.1-pro" 8192 'gemini-3*'
    # 8192 * 8 = 65536, exceeds floor of 32768
    [ "$BUMPED" = "65536" ]
}

@test "tokens: bump_for_reasoning floors to 32768 when 8x base is below" {
    source "$LIB"
    bump_for_reasoning BUMPED "gemini-3.1-pro" 1024 'gemini-3*'
    # 1024 * 8 = 8192, below floor → bumps to 32768
    [ "$BUMPED" = "32768" ]
}

@test "tokens: bump_for_reasoning accepts multiple patterns" {
    source "$LIB"
    bump_for_reasoning BUMPED "anthropic-thinking-v1" 2048 'gemini-3*' '*thinking*' 'o3-*'
    [ "$BUMPED" = "32768" ]
}
