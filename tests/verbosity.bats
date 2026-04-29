#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/verbosity.sh
# ABOUTME: Validates the verbosity prefix helper

load test_helper

LIB="${LIB_DIR}/verbosity.sh"

setup() {
    unset PREFIX
}

@test "verbosity: standard returns empty prefix" {
    source "$LIB"
    verbosity_prefix PREFIX standard
    [ -z "$PREFIX" ]
}

@test "verbosity: missing level defaults to standard (empty)" {
    source "$LIB"
    verbosity_prefix PREFIX
    [ -z "$PREFIX" ]
}

@test "verbosity: brief returns concise directive" {
    source "$LIB"
    verbosity_prefix PREFIX brief
    [ -n "$PREFIX" ]
    [[ "$PREFIX" == *"3-5 sentences"* ]]
}

@test "verbosity: detailed returns thorough directive" {
    source "$LIB"
    verbosity_prefix PREFIX detailed
    [ -n "$PREFIX" ]
    [[ "$PREFIX" == *"thorough"* ]]
    [[ "$PREFIX" == *"trade-offs"* ]]
}

@test "verbosity: unknown level falls back to standard (empty)" {
    source "$LIB"
    verbosity_prefix PREFIX zealous
    [ -z "$PREFIX" ]
}

@test "verbosity: brief and detailed differ" {
    source "$LIB"
    verbosity_prefix BRIEF brief
    verbosity_prefix DETAILED detailed
    [ "$BRIEF" != "$DETAILED" ]
    [ -n "$BRIEF" ]
    [ -n "$DETAILED" ]
}
