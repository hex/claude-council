#!/bin/bash
# ABOUTME: Provider discovery + selection policy shared by query-council.sh
# ABOUTME: Caller must export PROVIDERS_DIR before sourcing for discover_providers

# Discover which provider scripts are available to query.
# API providers are gated on their <NAME>_API_KEY env var; subscription-auth
# CLI providers (codex, gemini-cli) are gated on their binary being on PATH.
discover_providers() {
    local available=()

    for script in "${PROVIDERS_DIR}"/*.sh; do
        [[ -f "$script" ]] || continue
        local name
        name=$(basename "$script" .sh)
        local is_available=false

        case "$name" in
            codex)
                command -v codex >/dev/null 2>&1 && is_available=true
                ;;
            gemini-cli)
                command -v gemini >/dev/null 2>&1 && is_available=true
                ;;
            gemini)     [[ -n "${GEMINI_API_KEY:-}" ]] && is_available=true ;;
            openai)     [[ -n "${OPENAI_API_KEY:-}" ]] && is_available=true ;;
            grok)       [[ -n "${GROK_API_KEY:-}" ]] && is_available=true ;;
            *)
                local up_var
                up_var=$(echo "$name" | tr '[:lower:]' '[:upper:]')_API_KEY
                [[ -n "${!up_var:-}" ]] && is_available=true
                ;;
        esac

        if [[ "$is_available" == true ]]; then
            available+=("$name")
        fi
    done

    echo "${available[@]+"${available[@]}"}"
}

# Single source of truth for the API↔CLI shadowing pairs. Returns the name
# of the CLI provider that shadows the given API provider (or empty if the
# provider has no CLI sibling). Adding a new pair is a one-line change here
# that automatically propagates to prefer_cli_over_api and to the human
# display in query-council.sh's --list-available output.
shadow_origin() {
    case "$1" in
        openai) echo "codex" ;;
        gemini) echo "gemini-cli" ;;
        *)      echo "" ;;
    esac
}

# Apply the CLI-prefers-API policy to a list of provider names.
# When a provider's CLI shadow (per shadow_origin) is also in the input,
# drop that API provider. Explicit --providers always wins over this policy.
#
# Args: provider names (one per arg)
# Stdout: filtered names, space-separated, original order preserved
prefer_cli_over_api() {
    # Space-padded set string for bash 3.2 compat (no associative arrays).
    # Padding ensures word-boundary matches (e.g., "ai" won't match in "openai").
    local available=" $* "
    local p out=() shadow_cli
    for p in "$@"; do
        shadow_cli=$(shadow_origin "$p")
        if [[ -n "$shadow_cli" && "$available" == *" $shadow_cli "* ]]; then
            continue
        fi
        out+=("$p")
    done
    echo "${out[@]+"${out[@]}"}"
}

# Discovery + policy in one step: the providers a default query would run.
default_provider_set() {
    local discovered
    read -ra discovered <<< "$(discover_providers)"
    prefer_cli_over_api "${discovered[@]+"${discovered[@]}"}"
}

# Default model per provider. CLI defaults mirror what the CLI itself picks
# when invoked without -m, so the cache key and pane header match what's
# actually run. Bump when the CLI ships a new default we want to track.
get_model() {
    case "$1" in
        gemini)     echo "${GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
        openai)     echo "${OPENAI_MODEL:-gpt-5.5-pro}" ;;
        grok)       echo "${GROK_MODEL:-grok-4.20-reasoning}" ;;
        perplexity) echo "${PERPLEXITY_MODEL:-sonar-reasoning-pro}" ;;
        codex)      echo "${CODEX_MODEL:-gpt-5.5}" ;;
        gemini-cli) echo "${GEMINI_CLI_MODEL:-gemini-3-flash-preview}" ;;
        *)          echo "unknown" ;;
    esac
}

# Vendor color for a provider name. CLI variants share their vendor's color
# (codex with openai, gemini-cli with gemini) since they speak for the same vendor.
# Caller is responsible for defining BLUE/WHITE/RED/GREEN/CYAN globals.
provider_color() {
    case "$1" in
        gemini|gemini-cli) echo -e "${BLUE}" ;;
        openai|codex)      echo -e "${WHITE}" ;;
        grok)              echo -e "${RED}" ;;
        perplexity)        echo -e "${GREEN}" ;;
        *)                 echo -e "${CYAN}" ;;
    esac
}

# Vendor emoji for a provider name. Same grouping as provider_color.
provider_emoji() {
    case "$1" in
        gemini|gemini-cli) echo "🟦" ;;
        openai|codex)      echo "🔳" ;;
        grok)              echo "🟥" ;;
        perplexity)        echo "🟩" ;;
        *)                 echo "⬛" ;;
    esac
}
