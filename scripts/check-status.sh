#!/bin/bash
# ABOUTME: Checks connectivity and configuration status of all council providers
# ABOUTME: Outputs status table with connection times and model info

set -euo pipefail

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

# Main output
echo ""
echo -e "${DIM}Provider Status:${RESET}"
echo ""

# Check each provider
gemini_status=$(check_provider "gemini" "GEMINI_API_KEY" "GEMINI_MODEL" "gemini-3-flash-preview")
openai_status=$(check_provider "openai" "OPENAI_API_KEY" "OPENAI_MODEL" "codex-mini-latest")
grok_status=$(check_provider "grok" "GROK_API_KEY" "GROK_MODEL" "grok-4-1-fast-reasoning")

# Format output
format_status() {
    local emoji="$1"
    local color="$2"
    local name="$3"
    local status="$4"

    local status_icon status_text model_text=""

    case "$status" in
        no_key)
            status_icon="${DIM}--${RESET}"
            status_text="${DIM}API key not set${RESET}"
            ;;
        timeout)
            status_icon="${RED}x${RESET}"
            status_text="${RED}Connection timeout${RESET}"
            ;;
        auth_error:*)
            local code="${status#auth_error:}"
            status_icon="${RED}x${RESET}"
            status_text="${RED}Auth failed (HTTP ${code})${RESET}"
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

format_status "🔵" "$BLUE" "Gemini" "$gemini_status"
format_status "⚪" "$WHITE" "OpenAI" "$openai_status"
format_status "🔴" "$RED" "Grok" "$grok_status"

echo ""

# Summary
available=0
[[ "$gemini_status" == ok:* ]] && ((available++))
[[ "$openai_status" == ok:* ]] && ((available++))
[[ "$grok_status" == ok:* ]] && ((available++))

echo -e "${DIM}${available}/3 providers available${RESET}"
echo ""
