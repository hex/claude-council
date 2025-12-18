#!/bin/bash
# ABOUTME: Queries multiple AI providers in parallel and collects responses
# ABOUTME: Supports filtering by provider and outputs JSON results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"

# Source cache library
source "${SCRIPT_DIR}/lib/cache.sh"

usage() {
    echo "Usage: $0 [--providers=provider1,provider2] [--no-cache] <prompt>"
    echo ""
    echo "Options:"
    echo "  --providers=LIST  Comma-separated list of providers to query"
    echo "                    Available: gemini, openai, grok"
    echo "                    Default: all configured providers"
    echo "  --no-cache        Skip cache and force fresh queries"
    echo ""
    echo "Output: JSON object with provider responses"
    exit 1
}

# Parse arguments
FILTER_PROVIDERS=""
PROMPT=""
LIST_AVAILABLE=false
USE_CACHE=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --providers=*)
            FILTER_PROVIDERS="${1#*=}"
            shift
            ;;
        --list-available)
            LIST_AVAILABLE=true
            shift
            ;;
        --no-cache)
            USE_CACHE=false
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

# Handle --list-available flag
if [[ "$LIST_AVAILABLE" == true ]]; then
    available=()
    [[ -n "${GEMINI_API_KEY:-}" ]] && available+=("gemini")
    [[ -n "${OPENAI_API_KEY:-}" ]] && available+=("openai")
    [[ -n "${GROK_API_KEY:-}" ]] && available+=("grok")
    echo "${available[*]}"
    exit 0
fi

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

# Create temp directory for parallel results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Query provider and save result to temp file
# Uses cache if available and USE_CACHE=true
query_provider() {
    local provider="$1"
    local prompt="$2"
    local output_file="$3"
    local script="${PROVIDERS_DIR}/${provider}.sh"
    local model
    model=$(get_model "$provider")

    if [[ ! -x "$script" ]]; then
        echo '{"status": "error", "error": "Script not found or not executable"}' > "$output_file"
        return
    fi

    # Check cache if enabled
    if [[ "$USE_CACHE" == true ]]; then
        local key
        key=$(cache_key "$provider" "$model" "$prompt")
        local cached_response
        cached_response=$(cache_get "$key")
        if [[ -n "$cached_response" ]]; then
            jq -n --arg r "$cached_response" '{status: "success", response: $r, cached: true}' > "$output_file"
            return
        fi
    fi

    # Query provider
    if response=$("$script" "$prompt" 2>&1); then
        jq -n --arg r "$response" '{status: "success", response: $r}' > "$output_file"
        # Store in cache on success
        if [[ "$USE_CACHE" == true ]]; then
            local key
            key=$(cache_key "$provider" "$model" "$prompt")
            cache_set "$key" "$provider" "$model" "$prompt" "$response"
        fi
    else
        jq -n --arg e "$response" '{status: "error", error: $e}' > "$output_file"
    fi
}

# Colors for terminal output
BLUE='\033[34m'
WHITE='\033[37m'
RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
LIGHT_YELLOW='\033[93m'
ITALIC='\033[3m'
RESET='\033[0m'

provider_color() {
    case "$1" in
        gemini)  echo -e "${BLUE}" ;;
        openai)  echo -e "${WHITE}" ;;
        grok)    echo -e "${RED}" ;;
        *)       echo -e "${CYAN}" ;;
    esac
}

# Get model name for provider (mirrors logic in provider scripts)
get_model() {
    case "$1" in
        gemini)  echo "${GEMINI_MODEL:-gemini-3-flash-preview}" ;;
        openai)  echo "${OPENAI_MODEL:-codex-mini-latest}" ;;
        grok)    echo "${GROK_MODEL:-grok-4-1-fast-reasoning}" ;;
        *)       echo "unknown" ;;
    esac
}

# Get emoji for provider
provider_emoji() {
    case "$1" in
        gemini)  echo "🔵" ;;
        openai)  echo "⚪" ;;
        grok)    echo "🔴" ;;
        *)       echo "⚫" ;;
    esac
}

# Format provider list with colors and emojis
format_providers() {
    local formatted=""
    for p in "$@"; do
        local color=$(provider_color "$p")
        local emoji=$(provider_emoji "$p")
        formatted+="${emoji} ${color}${p}${RESET} "
    done
    echo "$formatted"
}

# Launch all queries in parallel
FORMATTED_PROVIDERS=$(format_providers "${PROVIDERS[@]}")
echo -e "🚀 Querying ${#PROVIDERS[@]} providers in parallel: ${FORMATTED_PROVIDERS}..." >&2

PIDS=()
for provider in "${PROVIDERS[@]}"; do
    query_provider "$provider" "$PROMPT" "${TEMP_DIR}/${provider}.json" &
    PIDS+=($!)
done

# Wait for all to complete
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Collect results
RESULTS="{}"
ERRORS=()

for provider in "${PROVIDERS[@]}"; do
    result_file="${TEMP_DIR}/${provider}.json"
    color=$(provider_color "$provider")
    model=$(get_model "$provider")

    if [[ -f "$result_file" ]]; then
        result=$(cat "$result_file")
        # Add model to result
        result=$(echo "$result" | jq --arg m "$model" '. + {model: $m}')
        RESULTS=$(echo "$RESULTS" | jq --arg p "$provider" --argjson r "$result" '.[$p] = $r')

        # Track errors and show status
        local status
        status=$(echo "$result" | jq -r '.status')
        local cached
        cached=$(echo "$result" | jq -r '.cached // false')

        if [[ "$status" == "error" ]]; then
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${RED}error${RESET}" >&2
            ERRORS+=("$provider: $(echo "$result" | jq -r '.error')")
        elif [[ "$cached" == "true" ]]; then
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${CYAN}cached${RESET}" >&2
        else
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${GREEN}success${RESET}" >&2
        fi
    else
        echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${RED}no response${RESET}" >&2
        ERRORS+=("$provider: No response received")
        RESULTS=$(echo "$RESULTS" | jq --arg p "$provider" --arg m "$model" '.[$p] = {status: "error", error: "No response received", model: $m}')
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
