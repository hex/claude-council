#!/bin/bash
# ABOUTME: Role management for council queries
# ABOUTME: Loads roles from config and builds role-injected prompts

set -euo pipefail

ROLES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_CONFIG="${ROLES_SCRIPT_DIR}/../../config/roles.json"

# Check if roles config exists
roles_config_exists() {
    [[ -f "$ROLES_CONFIG" ]]
}

# Expand preset to comma-separated role list
# Usage: expand_preset "balanced" -> "security,performance,maintainability"
expand_preset() {
    local preset="$1"
    if ! roles_config_exists; then
        echo ""
        return
    fi
    jq -r --arg p "$preset" '.presets[$p] // [] | join(",")' "$ROLES_CONFIG"
}

# Check if input is a preset name
is_preset() {
    local name="$1"
    if ! roles_config_exists; then
        return 1
    fi
    jq -e --arg p "$name" '.presets[$p] != null' "$ROLES_CONFIG" >/dev/null 2>&1
}

# Get role prompt by name
# Usage: get_role_prompt "security" -> "You are a security-focused..."
get_role_prompt() {
    local role="$1"
    if ! roles_config_exists; then
        echo ""
        return
    fi
    jq -r --arg r "$role" '.roles[$r].prompt // empty' "$ROLES_CONFIG"
}

# Get role display name
# Usage: get_role_name "security" -> "Security Auditor"
get_role_name() {
    local role="$1"
    if ! roles_config_exists; then
        echo ""
        return
    fi
    jq -r --arg r "$role" '.roles[$r].name // empty' "$ROLES_CONFIG"
}

# List all available role names
list_roles() {
    if ! roles_config_exists; then
        echo ""
        return
    fi
    jq -r '.roles | keys | join(", ")' "$ROLES_CONFIG"
}

# Validate that all roles in a comma-separated list exist
# Returns 0 if valid, 1 if invalid (with error message to stderr)
validate_roles() {
    local roles_str="$1"

    if ! roles_config_exists; then
        echo "Error: Roles config not found: $ROLES_CONFIG" >&2
        return 1
    fi

    # Expand preset first if applicable
    if is_preset "$roles_str"; then
        roles_str=$(expand_preset "$roles_str")
    fi

    IFS=',' read -ra role_list <<< "$roles_str"
    for role in "${role_list[@]}"; do
        local prompt
        prompt=$(get_role_prompt "$role")
        if [[ -z "$prompt" ]]; then
            echo "Error: Unknown role: $role" >&2
            echo "Available roles: $(list_roles)" >&2
            return 1
        fi
    done
    return 0
}

# Parse roles string (handles presets) and return normalized comma-separated list
# Usage: normalize_roles "balanced" -> "security,performance,maintainability"
# Usage: normalize_roles "security,performance" -> "security,performance"
normalize_roles() {
    local roles_str="$1"

    if is_preset "$roles_str"; then
        expand_preset "$roles_str"
    else
        echo "$roles_str"
    fi
}

# Build role-injected prompt for a provider
# Usage: build_prompt_with_role "user question" "security"
# Returns the modified prompt with role prefix
build_prompt_with_role() {
    local base_prompt="$1"
    local role="$2"

    if [[ -z "$role" ]]; then
        echo "$base_prompt"
        return
    fi

    local role_name
    role_name=$(get_role_name "$role")
    local role_prompt
    role_prompt=$(get_role_prompt "$role")

    if [[ -z "$role_prompt" ]]; then
        echo "$base_prompt"
        return
    fi

    cat <<EOF
[ROLE: ${role_name}]
${role_prompt}

[USER QUESTION]
${base_prompt}
EOF
}

# Assign roles to providers in order
# Usage: assign_roles "security,performance" gemini openai grok
# Output: associative-array-style "gemini:security openai:performance grok:"
assign_roles_to_providers() {
    local roles_str="$1"
    shift
    local providers=("$@")

    # Normalize roles (expand presets)
    roles_str=$(normalize_roles "$roles_str")

    IFS=',' read -ra roles <<< "$roles_str"

    local assignments=()
    for i in "${!providers[@]}"; do
        local provider="${providers[$i]}"
        local role="${roles[$i]:-}"  # Empty if no role for this provider
        assignments+=("${provider}:${role}")
    done

    echo "${assignments[*]}"
}

# Get role for a specific provider from assignments string
# Usage: get_provider_role "gemini" "gemini:security openai:performance"
get_provider_role() {
    local provider="$1"
    local assignments="$2"

    for assignment in $assignments; do
        local p="${assignment%%:*}"
        local r="${assignment#*:}"
        if [[ "$p" == "$provider" ]]; then
            echo "$r"
            return
        fi
    done
    echo ""
}
