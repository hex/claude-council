#!/bin/bash
# ABOUTME: Shared system-prompt + verbosity directive for all providers
# ABOUTME: Single source of truth for both the base prompt and verbosity levels

# Base system prompt — used by all four providers. Edit here to change
# the persona globally. Perplexity appends an additional citation clause.
BASE_SYSTEM_PROMPT="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance."

# Writes a verbosity directive into the named variable based on the level.
# Levels: brief, standard (no prefix), detailed.
#
# Usage:
#   verbosity_prefix OUT_VAR <level>
#   SYSTEM="${OUT_VAR:+$OUT_VAR }$BASE_SYSTEM_PROMPT"
verbosity_prefix() {
    local __out="$1"
    local level="${2:-standard}"
    case "$level" in
        brief)
            printf -v "$__out" '%s' "Keep responses to 3-5 sentences max. Use bullet points where possible. Skip code blocks unless explicitly asked. No edge cases."
            ;;
        detailed)
            printf -v "$__out" '%s' "Be thorough. Include code examples, edge cases, and trade-offs. Provide context and rationale for recommendations."
            ;;
        standard|*)
            printf -v "$__out" '%s' ""
            ;;
    esac
}

# Validates a verbosity level. Prints error to stderr and returns 1 on failure.
# Usage: validate_verbosity "$LEVEL" || exit 1
validate_verbosity() {
    case "$1" in
        brief|standard|detailed) return 0 ;;
        *)
            echo "Error: verbosity must be one of: brief, standard, detailed (got '$1')" >&2
            return 1
            ;;
    esac
}
