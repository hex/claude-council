#!/bin/bash
# ABOUTME: Checks connectivity and configuration status of all council providers
# ABOUTME: Outputs status table with connection times and model info

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/keys.sh"
source "$SCRIPT_DIR/lib/providers.sh"
resolve_grok_key

# Colors
BLUE='\033[34m'
WHITE='\033[37m'
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# Check a single provider
# Usage: check_provider <name> <api_key_var> <model_var> <default_model> <test_endpoint> <test_payload>
check_provider() {
    local name="$1"
    local api_key="${!2:-}"
    local model_var="$3"
    local default_model="$4"
    local model="${!model_var:-$default_model}"

    if [[ -z "$api_key" ]]; then
        echo "no_key"
        return
    fi

    # Measure response time with a minimal request
    local start_time end_time duration
    start_time=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)

    local http_code
    case "$name" in
        gemini)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                "https://generativelanguage.googleapis.com/v1beta/models/${model}?key=${api_key}" 2>/dev/null || echo "000")
            ;;
        openai)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                -H "Authorization: Bearer ${api_key}" \
                "https://api.openai.com/v1/models" 2>/dev/null || echo "000")
            ;;
        grok)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                -H "Authorization: Bearer ${api_key}" \
                "https://api.x.ai/v1/models" 2>/dev/null || echo "000")
            ;;
        perplexity)
            # Perplexity has no /models endpoint; use minimal chat request
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                -X POST \
                -H "Authorization: Bearer ${api_key}" \
                -H "Content-Type: application/json" \
                -d '{"model":"sonar","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
                "https://api.perplexity.ai/chat/completions" 2>/dev/null || echo "000")
            ;;
    esac

    end_time=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)

    # Calculate duration
    duration=$((end_time - start_time))

    if [[ "$http_code" == "200" ]]; then
        echo "ok:${duration}:${model}"
    elif [[ "$http_code" == "000" ]]; then
        echo "timeout"
    elif [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]; then
        echo "auth_error:${http_code}"
    else
        echo "error:${http_code}"
    fi
}

# Check a CLI-based provider in two tiers: binary present (--version), then
# authenticated (optional auth probe command). A binary that exists but fails
# its auth probe reports "unauthed" so the fix is obvious from the listing.
# Usage: check_cli_provider <name> <binary> [auth_probe_args...]
check_cli_provider() {
    local name="$1"
    local binary="$2"
    shift 2

    if ! command -v "$binary" >/dev/null 2>&1; then
        echo "no_binary"
        return
    fi

    local start_time end_time duration version
    start_time=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)

    if ! version=$("$binary" --version 2>/dev/null | head -1); then
        echo "error:exec_failed"
        return
    fi

    if [[ $# -gt 0 ]] && ! "$binary" "$@" >/dev/null 2>&1; then
        echo "unauthed"
        return
    fi

    end_time=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)
    duration=$((end_time - start_time))
    echo "ok:${duration}:${version:-cli}"
}

# Exact next action for a provider in a failure state, shown in the listing.
# Usage: remediation_for <provider_id> <state>
remediation_for() {
    case "$1:$2" in
        gemini:no_key)        echo "export GEMINI_API_KEY=<key>" ;;
        openai:no_key)        echo "export OPENAI_API_KEY=<key>" ;;
        grok:no_key)          echo "export XAI_API_KEY=<key>" ;;
        perplexity:no_key)    echo "export PERPLEXITY_API_KEY=<key>" ;;
        codex:no_binary)      echo "npm install -g @openai/codex" ;;
        codex:unauthed)       echo "codex login" ;;
        gemini-cli:no_binary) echo "npm install -g @google/gemini-cli" ;;
        *:auth_error)         echo "key rejected - regenerate it" ;;
        *)                    echo "" ;;
    esac
}

# Main output
echo ""
echo -e "${DIM}Provider Status:${RESET}"
echo ""

# Check each provider
gemini_status=$(check_provider "gemini" "GEMINI_API_KEY" "GEMINI_MODEL" "gemini-3.1-pro-preview")
openai_status=$(check_provider "openai" "OPENAI_API_KEY" "OPENAI_MODEL" "gpt-5.5-pro")
grok_status=$(check_provider "grok" "GROK_API_KEY" "GROK_MODEL" "grok-4.20-reasoning")
perplexity_status=$(check_provider "perplexity" "PERPLEXITY_API_KEY" "PERPLEXITY_MODEL" "sonar-reasoning-pro")
# codex login status exits non-zero when logged out; gemini has no
# equivalent offline auth probe, so it stays a single-tier check
codex_status=$(check_cli_provider "codex" "codex" login status)
gemini_cli_status=$(check_cli_provider "gemini-cli" "gemini")

# Format output
format_status() {
    local emoji="$1"
    local color="$2"
    local name="$3"
    local provider_id="$4"
    local status="$5"

    local status_icon status_text model_text=""
    local state="$status"
    [[ "$status" == auth_error:* ]] && state="auth_error"
    local fix
    fix=$(remediation_for "$provider_id" "$state")
    [[ -n "$fix" ]] && fix="  ${DIM}fix: ${fix}${RESET}"

    case "$status" in
        no_key)
            status_icon="${DIM}--${RESET}"
            status_text="${DIM}API key not set${RESET}${fix}"
            ;;
        no_binary)
            status_icon="${DIM}--${RESET}"
            status_text="${DIM}CLI not installed${RESET}${fix}"
            ;;
        unauthed)
            status_icon="${RED}x${RESET}"
            status_text="${RED}Installed, not authenticated${RESET}${fix}"
            ;;
        timeout)
            status_icon="${RED}x${RESET}"
            status_text="${RED}Connection timeout${RESET}"
            ;;
        auth_error:*)
            local code="${status#auth_error:}"
            status_icon="${RED}x${RESET}"
            status_text="${RED}Auth failed (HTTP ${code})${RESET}${fix}"
            ;;
        error:*)
            local code="${status#error:}"
            status_icon="${RED}x${RESET}"
            status_text="${RED}Error (HTTP ${code})${RESET}"
            ;;
        ok:*)
            local rest="${status#ok:}"
            local duration="${rest%%:*}"
            local model="${rest#*:}"
            status_icon="${GREEN}✓${RESET}"
            status_text="${GREEN}Connected${RESET} ${DIM}(${duration}ms)${RESET}"
            model_text="${DIM}${model}${RESET}"
            ;;
    esac

    echo -e "  ${emoji} ${color}${name}${RESET}\t${status_icon} ${status_text}  ${model_text}"
}

format_status "$(provider_emoji gemini)"     "$(provider_color gemini)"     "Gemini"     "gemini"     "$gemini_status"
format_status "$(provider_emoji openai)"     "$(provider_color openai)"     "OpenAI"     "openai"     "$openai_status"
format_status "$(provider_emoji grok)"       "$(provider_color grok)"       "Grok"       "grok"       "$grok_status"
format_status "$(provider_emoji perplexity)" "$(provider_color perplexity)" "Perplexity" "perplexity" "$perplexity_status"
format_status "$(provider_emoji codex)"      "$(provider_color codex)"      "Codex CLI"  "codex"      "$codex_status"
format_status "$(provider_emoji gemini-cli)" "$(provider_color gemini-cli)" "Gemini CLI" "gemini-cli" "$gemini_cli_status"

echo ""

# Summary. available=$((...)) rather than ((available++)): under set -e a
# post-increment returning 0 would abort the script on the first hit.
available=0
[[ "$gemini_status" == ok:* ]] && available=$((available + 1))
[[ "$openai_status" == ok:* ]] && available=$((available + 1))
[[ "$grok_status" == ok:* ]] && available=$((available + 1))
[[ "$perplexity_status" == ok:* ]] && available=$((available + 1))
[[ "$codex_status" == ok:* ]] && available=$((available + 1))
[[ "$gemini_cli_status" == ok:* ]] && available=$((available + 1))

echo -e "${DIM}${available}/6 providers available${RESET}"
echo ""
