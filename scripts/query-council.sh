#!/bin/bash
# ABOUTME: Queries multiple AI providers and collects their responses
# ABOUTME: Supports filtering by provider and outputs JSON results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"

usage() {
    echo "Usage: $0 [--providers=provider1,provider2] <prompt>"
    echo ""
    echo "Options:"
    echo "  --providers=LIST  Comma-separated list of providers to query"
    echo "                    Available: gemini, openai, grok"
    echo "                    Default: all configured providers"
    echo ""
    echo "Output: JSON object with provider responses"
    exit 1
}

# Parse arguments
FILTER_PROVIDERS=""
PROMPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --providers=*)
            FILTER_PROVIDERS="${1#*=}"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            PROMPT="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    usage
fi

# Discover available providers
discover_providers() {
    local available=()

    for script in "${PROVIDERS_DIR}"/*.sh; do
        [[ -f "$script" ]] || continue
        local name=$(basename "$script" .sh)

        # Check if provider has API key configured
        local key_var=""
        case "$name" in
            gemini) key_var="GEMINI_API_KEY" ;;
            openai) key_var="OPENAI_API_KEY" ;;
            grok)   key_var="GROK_API_KEY" ;;
            *)      key_var="${name^^}_API_KEY" ;;
        esac

        if [[ -n "${!key_var:-}" ]]; then
            available+=("$name")
        fi
    done

    echo "${available[@]}"
}

# Get list of providers to query
if [[ -n "$FILTER_PROVIDERS" ]]; then
    IFS=',' read -ra PROVIDERS <<< "$FILTER_PROVIDERS"
else
    read -ra PROVIDERS <<< "$(discover_providers)"
fi

if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
    echo "Error: No providers configured. Set API keys for at least one provider." >&2
    echo "  GEMINI_API_KEY, OPENAI_API_KEY, or GROK_API_KEY" >&2
    exit 1
fi

# Query each provider and collect results
RESULTS="{}"
ERRORS=()

for provider in "${PROVIDERS[@]}"; do
    script="${PROVIDERS_DIR}/${provider}.sh"

    if [[ ! -x "$script" ]]; then
        ERRORS+=("$provider: Script not found or not executable")
        continue
    fi

    echo "Querying $provider..." >&2

    if response=$("$script" "$PROMPT" 2>&1); then
        RESULTS=$(echo "$RESULTS" | jq --arg p "$provider" --arg r "$response" '.[$p] = {status: "success", response: $r}')
    else
        ERRORS+=("$provider: $response")
        RESULTS=$(echo "$RESULTS" | jq --arg p "$provider" --arg e "$response" '.[$p] = {status: "error", error: $e}')
    fi
done

# Output results
echo "$RESULTS" | jq .

# Report errors to stderr
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Errors:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  - $err" >&2
    done
fi
