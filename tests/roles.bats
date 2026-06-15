#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/roles.sh
# ABOUTME: Validates role loading, presets, validation, and prompt injection

load test_helper

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    source "${LIB_DIR}/roles.sh"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# ============================================================================
# roles_config_exists tests
# ============================================================================

@test "roles_config_exists: returns 0 when config exists" {
    roles_config_exists
}

# ============================================================================
# is_preset tests
# ============================================================================

@test "is_preset: returns 0 for valid preset 'balanced'" {
    is_preset "balanced"
}

@test "is_preset: returns 0 for valid preset 'security-focused'" {
    is_preset "security-focused"
}

@test "is_preset: returns 0 for valid preset 'architecture'" {
    is_preset "architecture"
}

@test "is_preset: returns 0 for valid preset 'review'" {
    is_preset "review"
}

@test "is_preset: returns 1 for non-preset role name" {
    run is_preset "security"
    [ "$status" -eq 1 ]
}

@test "is_preset: returns 1 for unknown name" {
    run is_preset "nonexistent"
    [ "$status" -eq 1 ]
}

# ============================================================================
# expand_preset tests
# ============================================================================

@test "expand_preset: expands balanced to security,performance,maintainability" {
    local result=$(expand_preset "balanced")
    [ "$result" = "security,performance,maintainability" ]
}

@test "expand_preset: expands security-focused correctly" {
    local result=$(expand_preset "security-focused")
    [ "$result" = "security,devil,compliance" ]
}

@test "expand_preset: expands architecture correctly" {
    local result=$(expand_preset "architecture")
    [ "$result" = "scalability,maintainability,simplicity" ]
}

@test "expand_preset: expands review correctly" {
    local result=$(expand_preset "review")
    [ "$result" = "security,maintainability,dx" ]
}

@test "expand_preset: returns empty for unknown preset" {
    local result=$(expand_preset "nonexistent")
    [ -z "$result" ]
}

# ============================================================================
# get_role_prompt tests
# ============================================================================

@test "get_role_prompt: returns prompt for security role" {
    local result=$(get_role_prompt "security")
    [[ "$result" == *"security-focused"* ]]
}

@test "get_role_prompt: returns prompt for performance role" {
    local result=$(get_role_prompt "performance")
    [[ "$result" == *"performance-focused"* ]]
}

@test "get_role_prompt: returns empty for unknown role" {
    local result=$(get_role_prompt "nonexistent")
    [ -z "$result" ]
}

# ============================================================================
# get_role_name tests
# ============================================================================

@test "get_role_name: returns 'Security Auditor' for security role" {
    local result=$(get_role_name "security")
    [ "$result" = "Security Auditor" ]
}

@test "get_role_name: returns 'Performance Optimizer' for performance role" {
    local result=$(get_role_name "performance")
    [ "$result" = "Performance Optimizer" ]
}

@test "get_role_name: returns 'Devil's Advocate' for devil role" {
    local result=$(get_role_name "devil")
    [ "$result" = "Devil's Advocate" ]
}

@test "get_role_name: returns empty for unknown role" {
    local result=$(get_role_name "nonexistent")
    [ -z "$result" ]
}

# ============================================================================
# list_roles tests
# ============================================================================

@test "list_roles: includes security role" {
    local result=$(list_roles)
    [[ "$result" == *"security"* ]]
}

@test "list_roles: includes performance role" {
    local result=$(list_roles)
    [[ "$result" == *"performance"* ]]
}

@test "list_roles: includes all 8 roles" {
    local result=$(list_roles)
    [[ "$result" == *"security"* ]]
    [[ "$result" == *"performance"* ]]
    [[ "$result" == *"maintainability"* ]]
    [[ "$result" == *"devil"* ]]
    [[ "$result" == *"simplicity"* ]]
    [[ "$result" == *"scalability"* ]]
    [[ "$result" == *"dx"* ]]
    [[ "$result" == *"compliance"* ]]
}

# ============================================================================
# validate_roles tests
# ============================================================================

@test "validate_roles: accepts valid single role" {
    validate_roles "security"
}

@test "validate_roles: accepts valid multiple roles" {
    validate_roles "security,performance"
}

@test "validate_roles: accepts valid preset" {
    validate_roles "balanced"
}

@test "validate_roles: rejects unknown role" {
    run validate_roles "fakrole"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown role"* ]]
}

@test "validate_roles: rejects mixed valid and invalid roles" {
    run validate_roles "security,fakrole"
    [ "$status" -eq 1 ]
}

# ============================================================================
# normalize_roles tests
# ============================================================================

@test "normalize_roles: expands preset" {
    local result=$(normalize_roles "balanced")
    [ "$result" = "security,performance,maintainability" ]
}

@test "normalize_roles: passes through non-preset" {
    local result=$(normalize_roles "security,performance")
    [ "$result" = "security,performance" ]
}

# ============================================================================
# build_prompt_with_role tests
# ============================================================================

@test "build_prompt_with_role: injects role prefix" {
    local result=$(build_prompt_with_role "user question" "security")
    [[ "$result" == *"[ROLE: Security Auditor]"* ]]
    [[ "$result" == *"user question"* ]]
}

@test "build_prompt_with_role: returns original prompt for empty role" {
    local result=$(build_prompt_with_role "user question" "")
    [ "$result" = "user question" ]
}

@test "build_prompt_with_role: includes role prompt instructions" {
    local result=$(build_prompt_with_role "user question" "security")
    [[ "$result" == *"security-focused"* ]]
}

# ============================================================================
# local_council_roles tests (issue #1 — local Claude-subagent fallback)
#
# Resolves the role set for a local (provider-less) council: honor an explicit
# --roles value (expanding presets), else default to a diverse trio chosen to
# pull in different directions for solo brainstorming.
# ============================================================================

@test "local_council_roles: defaults to a diverse set when no roles given" {
    local result=$(local_council_roles "")
    [ "$result" = "devil,simplicity,security,scalability" ]
}

@test "local_council_roles: honors an explicit role list verbatim" {
    local result=$(local_council_roles "security,performance")
    [ "$result" = "security,performance" ]
}

@test "local_council_roles: expands a preset" {
    local result=$(local_council_roles "balanced")
    [ "$result" = "security,performance,maintainability" ]
}

@test "local_council_roles: default set is all valid, known roles" {
    validate_roles "$(local_council_roles "")"
}

@test "local_council_roles: count selects that many lenses from the diverse order" {
    local result=$(local_council_roles "" 5)
    [ "$result" = "devil,simplicity,security,scalability,maintainability" ]
}

@test "local_council_roles: count of 1 yields a single lens" {
    local result=$(local_council_roles "" 1)
    [ "$result" = "devil" ]
}

@test "local_council_roles: count above the pool size is clamped to all roles" {
    local result=$(local_council_roles "" 99)
    validate_roles "$result"
    # 8 roles exist; expect all of them
    [ "$(echo "$result" | tr ',' '\n' | wc -l | tr -d ' ')" = "8" ]
}

@test "local_council_roles: explicit roles ignore the count" {
    local result=$(local_council_roles "balanced" 5)
    [ "$result" = "security,performance,maintainability" ]
}

@test "local_council_roles: non-numeric count falls back to the default set" {
    local result=$(local_council_roles "" "abc")
    [ "$result" = "devil,simplicity,security,scalability" ]
}

@test "local_council_roles: every count from 1..8 resolves to valid roles" {
    local n
    for n in 1 2 3 4 5 6 7 8; do
        validate_roles "$(local_council_roles "" "$n")"
    done
}

# ============================================================================
# assign_roles_to_providers tests
# ============================================================================

@test "assign_roles_to_providers: assigns roles in order" {
    local result=$(assign_roles_to_providers "security,performance" gemini openai grok)
    [[ "$result" == *"gemini:security"* ]]
    [[ "$result" == *"openai:performance"* ]]
    [[ "$result" == *"grok:"* ]]  # Empty role for third provider
}

@test "assign_roles_to_providers: expands preset before assigning" {
    local result=$(assign_roles_to_providers "balanced" gemini openai grok)
    [[ "$result" == *"gemini:security"* ]]
    [[ "$result" == *"openai:performance"* ]]
    [[ "$result" == *"grok:maintainability"* ]]
}

# ============================================================================
# get_provider_role tests
# ============================================================================

@test "get_provider_role: extracts correct role for provider" {
    local assignments="gemini:security openai:performance grok:"
    local result=$(get_provider_role "gemini" "$assignments")
    [ "$result" = "security" ]
}

@test "get_provider_role: returns empty for unassigned provider" {
    local assignments="gemini:security openai:performance grok:"
    local result=$(get_provider_role "grok" "$assignments")
    [ -z "$result" ]
}

@test "get_provider_role: returns empty for unknown provider" {
    local assignments="gemini:security openai:performance"
    local result=$(get_provider_role "perplexity" "$assignments")
    [ -z "$result" ]
}
