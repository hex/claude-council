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
