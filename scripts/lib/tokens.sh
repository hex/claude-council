#!/bin/bash
# ABOUTME: Token-limit helper that bumps the cap for reasoning models
# ABOUTME: Source from provider scripts and call bump_for_reasoning before API request

# Reasoning models share the maxOutputTokens cap between internal "thinking"
# and visible output. A 2048 cap can leave only a few hundred tokens for the
# actual response after the model burns most on chain-of-thought, producing
# silent mid-sentence truncation. This helper bumps the cap to 8x base
# (minimum 32768, matching OpenAI's recommendation) when the model name
# matches one of the caller-supplied glob patterns.
#
# Usage: bump_for_reasoning OUT_VAR <model> <base_tokens> <pattern> [<pattern>...]
#
# Example:
#   bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" 'gemini-3*' '*thinking*'
bump_for_reasoning() {
    local __out="$1"
    local model="$2"
    local base="$3"
    shift 3
    local pattern
    for pattern in "$@"; do
        # shellcheck disable=SC2053
        if [[ "$model" == $pattern ]]; then
            local bumped=$(( base * 8 ))
            (( bumped < 32768 )) && bumped=32768
            printf -v "$__out" '%s' "$bumped"
            return 0
        fi
    done
    printf -v "$__out" '%s' "$base"
}
