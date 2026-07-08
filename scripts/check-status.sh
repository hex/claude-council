#!/bin/bash
# ABOUTME: Checks connectivity and configuration status of all council providers
# ABOUTME: Outputs status table with connection times and model info

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/keys.sh"
source "$SCRIPT_DIR/lib/providers.sh"
source "$SCRIPT_DIR/lib/retry.sh"
resolve_grok_key

# Colors
BLUE='\033[34m'
WHITE='\033[37m'
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# Millisecond timestamp. Without python3, scale whole seconds to ms so callers
# that render "(${duration}ms)" don't show durations ~1000x too small.
now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

# Does a 400 from this provider mean the key was rejected?
# Usage: rejected_key <provider> <body_file>
#
# Vendors disagree on how a rejected key comes back. Most answer 401, which the
# status code alone classifies. Gemini answers 400 with status INVALID_ARGUMENT
# and xAI answers 400 with code invalid-argument; for those two the response
# body, not the status alone, separates a rejected key from a malformed request.
#
# Each probe below is a request with no caller-supplied parameters beyond the
# Gemini model in its path, and an unknown model answers 404, so on these
# endpoints a 400 carrying the vendor's marker can only be the key. A probe that
# grows query parameters would need a narrower test than the status alone.
rejected_key() {
    local provider="$1" body_file="$2"
    case "$provider" in
        gemini) jq -e '.error.status == "INVALID_ARGUMENT"' "$body_file" >/dev/null 2>&1 ;;
        grok)   jq -e '.code == "invalid-argument"' "$body_file" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Check a single provider
# Usage: check_provider <name> <api_key_var> <model_var> <default_model>
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
    start_time=$(now_ms)

    # Keys travel via a mode-600 curl --config file, never the argv (ps-visible)
    # or the URL. Mirrors the provider scripts' curl_secret_config hardening.
    # The response body is captured because some vendors only reveal a rejected
    # key there. It can carry a redacted copy of the key, so it lives in a temp
    # file that mktemp creates mode-600: inspected via jq, never printed, and
    # unlinked before this function returns.
    local http_code cfg body_file rejected
    body_file=$(mktemp)
    case "$name" in
        gemini)
            cfg=$(curl_secret_config "x-goog-api-key: ${api_key}")
            http_code=$(curl -s -o "$body_file" -w "%{http_code}" --max-time 10 \
                --config "$cfg" \
                "https://generativelanguage.googleapis.com/v1beta/models/${model}" 2>/dev/null || true)
            rm -f "$cfg"
            ;;
        openai)
            cfg=$(curl_secret_config "Authorization: Bearer ${api_key}")
            http_code=$(curl -s -o "$body_file" -w "%{http_code}" --max-time 10 \
                --config "$cfg" \
                "https://api.openai.com/v1/models" 2>/dev/null || true)
            rm -f "$cfg"
            ;;
        grok)
            cfg=$(curl_secret_config "Authorization: Bearer ${api_key}")
            http_code=$(curl -s -o "$body_file" -w "%{http_code}" --max-time 10 \
                --config "$cfg" \
                "https://api.x.ai/v1/models" 2>/dev/null || true)
            rm -f "$cfg"
            ;;
        perplexity)
            # Perplexity has no /models endpoint, so auth can only be probed with
            # a (billable) chat request. The API rejects anything under 16 output
            # tokens, so 16 is as close to free as the status check can get.
            cfg=$(curl_secret_config "Authorization: Bearer ${api_key}")
            http_code=$(curl -s -o "$body_file" -w "%{http_code}" --max-time 10 \
                -X POST \
                --config "$cfg" \
                -H "Content-Type: application/json" \
                -d '{"model":"sonar","messages":[{"role":"user","content":"hi"}],"max_tokens":16}' \
                "https://api.perplexity.ai/chat/completions" 2>/dev/null || true)
            rm -f "$cfg"
            ;;
    esac

    # curl exits non-zero when a transfer fails, so the `|| true` above keeps
    # set -e from aborting. When no response status was received it also reports
    # the code as 000 through -w. An empty code means curl wrote nothing to
    # stdout.
    http_code="${http_code:-000}"

    rejected=0
    if [[ "$http_code" == "400" ]] && rejected_key "$name" "$body_file"; then
        rejected=1
    fi
    rm -f "$body_file"
    if (( rejected )); then
        # This branch only runs on 400, so report it under the code the vendor sent
        echo "auth_error:400"
        return
    fi

    end_time=$(now_ms)

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
    start_time=$(now_ms)

    if ! version=$("$binary" --version 2>/dev/null | head -1); then
        echo "error:exec_failed"
        return
    fi

    if [[ $# -gt 0 ]] && ! "$binary" "$@" >/dev/null 2>&1; then
        echo "unauthed"
        return
    fi

    end_time=$(now_ms)
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
        antigravity:no_binary) echo "install the Antigravity CLI (agy)" ;;
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
# codex login status exits non-zero when logged out; agy has no
# equivalent offline auth probe, so it stays a single-tier check
codex_status=$(check_cli_provider "codex" "codex" login status)
antigravity_status=$(check_cli_provider "antigravity" "agy")

# Format output
# Usage: format_status <display_name> <provider_id> <status>
format_status() {
    local name="$1"
    local provider_id="$2"
    local status="$3"

    local emoji color
    emoji=$(provider_emoji "$provider_id")
    color=$(provider_color "$provider_id")
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

format_status "Gemini"     "gemini"     "$gemini_status"
format_status "OpenAI"     "openai"     "$openai_status"
format_status "Grok"       "grok"       "$grok_status"
format_status "Perplexity" "perplexity" "$perplexity_status"
format_status "Codex CLI"  "codex"      "$codex_status"
format_status "Antigravity" "antigravity" "$antigravity_status"

echo ""

# Summary. available=$((...)) rather than ((available++)): under set -e a
# post-increment returning 0 would abort the script on the first hit.
available=0
[[ "$gemini_status" == ok:* ]] && available=$((available + 1))
[[ "$openai_status" == ok:* ]] && available=$((available + 1))
[[ "$grok_status" == ok:* ]] && available=$((available + 1))
[[ "$perplexity_status" == ok:* ]] && available=$((available + 1))
[[ "$codex_status" == ok:* ]] && available=$((available + 1))
[[ "$antigravity_status" == ok:* ]] && available=$((available + 1))

echo -e "${DIM}${available}/6 providers available${RESET}"
echo ""
