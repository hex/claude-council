#!/bin/bash
# ABOUTME: Resolves provider API keys with vendor-name fallbacks
# ABOUTME: Source before any consumer reads a *_API_KEY variable

# Populates GROK_API_KEY from XAI_API_KEY when present.
# XAI_API_KEY (vendor-canonical) wins over GROK_API_KEY (legacy) when both are set,
# and conflicts are coalesced silently — see provider-integration SKILL for rationale.
resolve_grok_key() {
    if [[ -n "${XAI_API_KEY:-}" ]]; then
        export GROK_API_KEY="$XAI_API_KEY"
    fi
}
