#!/bin/bash
# ABOUTME: Fallback model per provider, plus a TTL cache of "unavailable" verdicts
# ABOUTME: A verdict is recorded only once the fallback model has actually answered

LIB_MODEL_FALLBACK_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${LIB_MODEL_FALLBACK_DIR}/cache.sh"

# One source of truth for the fallback map, as "provider:fallback" tokens; the
# preferred model is whatever get_model returns, so it is not repeated here.
# Mirrors the SHADOW_PAIRS idiom in providers.sh. Adding a provider is one token.
# Every id below was confirmed with a real completion on 2026-07-10.
MODEL_FALLBACKS="openai:gpt-5.5-pro grok:grok-4.20-reasoning perplexity:sonar-pro gemini:gemini-pro-latest"

# The model a provider degrades to when its preferred model is unavailable.
# Empty for CLI providers, which degrade to their API sibling instead.
model_fallback_for() {
    local token
    for token in $MODEL_FALLBACKS; do
        [[ "${token%%:*}" == "$1" ]] && { echo "${token#*:}"; return; }
    done
    echo ""
}
