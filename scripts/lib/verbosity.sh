#!/bin/bash
# ABOUTME: Verbosity directives prepended to provider system prompts
# ABOUTME: Source from provider scripts and call verbosity_prefix to get the directive

# Writes a verbosity directive into the named variable based on the level.
# Levels: brief, standard (no prefix), detailed.
#
# Usage:
#   verbosity_prefix OUT_VAR <level>
#   SYSTEM="${OUT_VAR:+$OUT_VAR }<existing system prompt>"
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
