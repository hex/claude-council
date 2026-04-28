#!/bin/bash
# ABOUTME: Queries multiple AI providers in parallel and collects responses
# ABOUTME: Supports filtering by provider and outputs JSON results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"

# Source libraries
source "${SCRIPT_DIR}/lib/cache.sh"
source "${SCRIPT_DIR}/lib/roles.sh"
source "${SCRIPT_DIR}/lib/keys.sh"
source "${SCRIPT_DIR}/lib/display.sh"
resolve_grok_key

# Helper: current time in milliseconds (falls back to seconds if python3 missing)
now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s
}

usage() {
    cat >&2 << 'EOF'
Usage: query-council.sh [OPTIONS] [--] <prompt>

Options:
  --providers LIST    Comma-separated providers (gemini,openai,grok,perplexity)
  --roles LIST        Assign roles to providers (security,performance,maintainability)
                      Or use preset: balanced, security-focused, architecture, review
  --debate            Enable two-round debate mode
  --file PATH         Include file contents in query context
  --output PATH       Export destination (passed in metadata for caller)

Note: Flags accept both --flag=value and --flag value formats.
  --quiet, -q         Suppress individual responses (passed in metadata)
  --no-cache          Skip cache, force fresh queries
  --no-auto-context   Disable auto file detection (passed in metadata)
  --no-pane           Disable streaming tmux pane (default: on inside tmux)
  --list-available    List configured providers and exit

Output: JSON with metadata and provider responses
EOF
    exit 1
}

# Parse arguments
FILTER_PROVIDERS=""
PROMPT=""
LIST_AVAILABLE=false
USE_CACHE=true
ROLES=""
DEBATE_MODE=false
FILE_PATH=""
OUTPUT_PATH=""
QUIET_MODE=false
AUTO_CONTEXT=true
NO_PANE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --providers=*)
            FILTER_PROVIDERS="${1#*=}"
            shift
            ;;
        --providers)
            FILTER_PROVIDERS="$2"
            shift 2
            ;;
        --roles=*)
            ROLES="${1#*=}"
            shift
            ;;
        --roles)
            ROLES="$2"
            shift 2
            ;;
        --debate)
            DEBATE_MODE=true
            shift
            ;;
        --file=*)
            FILE_PATH="${1#*=}"
            shift
            ;;
        --file)
            FILE_PATH="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"
            shift
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --quiet|-q)
            QUIET_MODE=true
            shift
            ;;
        --no-cache)
            USE_CACHE=false
            shift
            ;;
        --no-auto-context)
            AUTO_CONTEXT=false
            shift
            ;;
        --no-pane)
            NO_PANE=true
            shift
            ;;
        --list-available)
            LIST_AVAILABLE=true
            shift
            ;;
        --prompt=*)
            PROMPT="${1#*=}"
            shift
            ;;
        --prompt)
            PROMPT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        --)
            shift
            # Everything after -- is the prompt
            PROMPT="$*"
            break
            ;;
        -*)
            echo "Error: Unknown flag: $1" >&2
            usage
            ;;
        *)
            # Accumulate prompt (allows multi-word without quotes)
            if [[ -z "$PROMPT" ]]; then
                PROMPT="$1"
            else
                PROMPT="$PROMPT $1"
            fi
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
    [[ -n "${PERPLEXITY_API_KEY:-}" ]] && available+=("perplexity")
    echo "${available[*]}"
    exit 0
fi

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    usage
fi

# Validate --file exists if specified
if [[ -n "$FILE_PATH" ]] && [[ ! -f "$FILE_PATH" ]]; then
    echo "Error: File not found: $FILE_PATH" >&2
    exit 1
fi

# Validate --output directory is writable if specified
if [[ -n "$OUTPUT_PATH" ]]; then
    output_dir=$(dirname "$OUTPUT_PATH")
    if [[ "$output_dir" != "." ]] && [[ ! -d "$output_dir" ]]; then
        if ! mkdir -p "$output_dir" 2>/dev/null; then
            echo "Error: Cannot create output directory: $output_dir" >&2
            exit 1
        fi
    fi
fi

# Validate --roles if specified
if [[ -n "$ROLES" ]]; then
    if ! validate_roles "$ROLES"; then
        exit 1
    fi
    # Normalize roles (expand presets)
    ROLES=$(normalize_roles "$ROLES")
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

    echo "${available[@]+"${available[@]}"}"
}

# Get list of providers to query
if [[ -n "$FILTER_PROVIDERS" ]]; then
    IFS=',' read -ra PROVIDERS <<< "$FILTER_PROVIDERS"
else
    read -ra PROVIDERS <<< "$(discover_providers)"
fi

if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
    echo "Error: No providers configured. Set API keys for at least one provider." >&2
    echo "  GEMINI_API_KEY, OPENAI_API_KEY, XAI_API_KEY (or GROK_API_KEY), or PERPLEXITY_API_KEY" >&2
    exit 1
fi

# Create temp directory for parallel results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Query provider and save result to temp file
# Uses cache if available and USE_CACHE=true
# Args: provider prompt output_file [role]
query_provider() {
    local provider="$1"
    local prompt="$2"
    local output_file="$3"
    local role="${4:-}"
    local script="${PROVIDERS_DIR}/${provider}.sh"
    local model
    model=$(get_model "$provider")

    if [[ ! -x "$script" ]]; then
        jq -n --arg role "$role" '{status: "error", error: "Script not found or not executable", role: (if $role == "" then null else $role end)}' > "$output_file"
        [[ -n "${COUNCIL_PANE_DIR:-}" ]] && pane_status_event "$COUNCIL_PANE_DIR" "$provider" error "" "$model"
        return
    fi

    [[ -n "${COUNCIL_PANE_DIR:-}" ]] && pane_status_event "$COUNCIL_PANE_DIR" "$provider" querying "" "$model"
    local start_ms
    start_ms=$(now_ms)

    # Build the final prompt (with role injection if specified)
    local final_prompt
    if [[ -n "$role" ]]; then
        final_prompt=$(build_prompt_with_role "$prompt" "$role")
    else
        final_prompt="$prompt"
    fi

    # Check cache if enabled (cache key includes role)
    if [[ "$USE_CACHE" == true ]]; then
        local key
        key=$(cache_key "$provider" "$model" "$final_prompt")
        local cached_response
        cached_response=$(cache_get "$key")
        if [[ -n "$cached_response" ]]; then
            jq -n --arg r "$cached_response" --arg role "$role" \
                '{status: "success", response: $r, cached: true, role: (if $role == "" then null else $role end)}' > "$output_file"
            if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
                pane_status_event "$COUNCIL_PANE_DIR" "$provider" cached "" "$model"
                pane_response_write "$COUNCIL_PANE_DIR" "$provider" "$cached_response"
            fi
            return
        fi
    fi

    # Query provider with role-injected prompt
    if response=$("$script" "$final_prompt" 2>&1); then
        local elapsed=$(( $(now_ms) - start_ms ))
        jq -n --arg r "$response" --arg role "$role" \
            '{status: "success", response: $r, cached: false, role: (if $role == "" then null else $role end)}' > "$output_file"
        if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
            pane_status_event "$COUNCIL_PANE_DIR" "$provider" complete "$elapsed" "$model"
            pane_response_write "$COUNCIL_PANE_DIR" "$provider" "$response"
        fi
        # Store in cache on success
        if [[ "$USE_CACHE" == true ]]; then
            local key
            key=$(cache_key "$provider" "$model" "$final_prompt")
            cache_set "$key" "$provider" "$model" "$final_prompt" "$response"
        fi
    else
        jq -n --arg e "$response" --arg role "$role" \
            '{status: "error", error: $e, cached: false, role: (if $role == "" then null else $role end)}' > "$output_file"
        if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
            pane_error_write "$COUNCIL_PANE_DIR" "$provider" "$response"
            pane_status_event "$COUNCIL_PANE_DIR" "$provider" error "" "$model"
        fi
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
DIM='\033[2m'
RESET='\033[0m'

provider_color() {
    case "$1" in
        gemini)     echo -e "${BLUE}" ;;
        openai)     echo -e "${WHITE}" ;;
        grok)       echo -e "${RED}" ;;
        perplexity) echo -e "${GREEN}" ;;
        *)          echo -e "${CYAN}" ;;
    esac
}

# Get model name for provider (mirrors logic in provider scripts)
get_model() {
    case "$1" in
        gemini)     echo "${GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
        openai)     echo "${OPENAI_MODEL:-gpt-5.5-pro}" ;;
        grok)       echo "${GROK_MODEL:-grok-4.20-reasoning}" ;;
        perplexity) echo "${PERPLEXITY_MODEL:-sonar-reasoning-pro}" ;;
        *)          echo "unknown" ;;
    esac
}

# Get emoji for provider
provider_emoji() {
    case "$1" in
        gemini)     echo "🟦" ;;
        openai)     echo "🔳" ;;
        grok)       echo "🟥" ;;
        perplexity) echo "🟩" ;;
        *)          echo "⬛" ;;
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

# Assign roles to providers if specified
ROLE_ASSIGNMENTS=""
if [[ -n "$ROLES" ]]; then
    ROLE_ASSIGNMENTS=$(assign_roles_to_providers "$ROLES" "${PROVIDERS[@]}")
    echo -e "Provider roles:" >&2
    for assignment in $ROLE_ASSIGNMENTS; do
        local_provider="${assignment%%:*}"
        local_role="${assignment#*:}"
        if [[ -n "$local_role" ]]; then
            local_role_name=$(get_role_name "$local_role")
            local_color=$(provider_color "$local_provider")
            echo -e "  ${local_color}${local_provider}${RESET}: ${local_role_name}" >&2
        fi
    done
fi

# Include file content in prompt if --file specified
if [[ -n "$FILE_PATH" ]]; then
    FILE_CONTENT=$(cat "$FILE_PATH")
    PROMPT="Here is the content of ${FILE_PATH}:

\`\`\`
${FILE_CONTENT}
\`\`\`

${PROMPT}"
fi

# Open streaming pane (best effort) and signal "querying" via tab color
COUNCIL_PANE_DIR=""
if [[ "$NO_PANE" != true ]]; then
    if pane_dir=$(display_pane_open 2>/dev/null); then
        COUNCIL_PANE_DIR="$pane_dir"
    fi
fi
# Probe /dev/tty once — `-w` test passes for the device file even when
# redirects fail without a controlling tty. Cache the result for the
# council_signal_* helpers in display.sh.
COUNCIL_HAS_TTY=0
: >/dev/tty 2>/dev/null && COUNCIL_HAS_TTY=1
council_signal_state yellow
COUNCIL_START_MS=$(now_ms)

# Launch all queries in parallel
FORMATTED_PROVIDERS=$(format_providers "${PROVIDERS[@]}")
echo -e "🚀 Querying ${#PROVIDERS[@]} providers in parallel: ${FORMATTED_PROVIDERS}..." >&2

PIDS=()
for provider in "${PROVIDERS[@]}"; do
    # Get role for this provider (empty if no roles assigned)
    provider_role=""
    if [[ -n "$ROLE_ASSIGNMENTS" ]]; then
        provider_role=$(get_provider_role "$provider" "$ROLE_ASSIGNMENTS")
    fi
    query_provider "$provider" "$PROMPT" "${TEMP_DIR}/${provider}.json" "$provider_role" &
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
        status=$(echo "$result" | jq -r '.status')
        cached=$(echo "$result" | jq -r '.cached // false')

        if [[ "$status" == "error" ]]; then
            error_msg=$(echo "$result" | jq -r '.error')
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${RED}error${RESET} - ${DIM}${error_msg}${RESET}" >&2
            ERRORS+=("$provider: $error_msg")
        elif [[ "$cached" == "true" ]]; then
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${CYAN}cached${RESET}" >&2
        else
            echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${GREEN}success${RESET}" >&2
        fi
    else
        echo -e "${color}${provider}${RESET} ${ITALIC}${LIGHT_YELLOW}${model}${RESET}: ${RED}no response${RESET}" >&2
        ERRORS+=("$provider: No response received")
        RESULTS=$(echo "$RESULTS" | jq --arg p "$provider" --arg m "$model" '.[$p] = {status: "error", error: "No response received", model: $m, cached: false}')
    fi
done

# Debate mode: Round 2 rebuttals
ROUND2_RESULTS="{}"
if [[ "$DEBATE_MODE" == true ]]; then
    echo -e "\n🔄 Debate mode: Starting round 2 rebuttals..." >&2

    # Build debate prompt with all round 1 responses
    debate_prompt="Here are other perspectives on this question:"
    debate_prompt+=$'\n\n'
    for provider in "${PROVIDERS[@]}"; do
        response=$(echo "$RESULTS" | jq -r --arg p "$provider" '.[$p].response // empty')
        if [[ -n "$response" ]]; then
            provider_upper=$(echo "$provider" | tr '[:lower:]' '[:upper:]')
            debate_prompt+="[${provider_upper}'S RESPONSE]"
            debate_prompt+=$'\n'
            debate_prompt+="${response}"
            debate_prompt+=$'\n\n'
        fi
    done

    debate_prompt+="As a critical reviewer, analyze these responses:"
    debate_prompt+=$'\n'
    debate_prompt+="1. What are the strengths of each approach?"
    debate_prompt+=$'\n'
    debate_prompt+="2. What are the weaknesses or blind spots?"
    debate_prompt+=$'\n'
    debate_prompt+="3. What did the other responses miss?"
    debate_prompt+=$'\n'
    debate_prompt+="4. What would you change about your original recommendation after seeing these?"

    # Query all providers for rebuttals (no roles, no cache)
    ROUND2_PIDS=()
    for provider in "${PROVIDERS[@]}"; do
        # Round 2: no role, skip cache (rebuttals depend on round 1 content)
        (
            script="${PROVIDERS_DIR}/${provider}.sh"
            model=$(get_model "$provider")
            output_file="${TEMP_DIR}/${provider}_r2.json"

            if [[ ! -x "$script" ]]; then
                echo '{"status": "error", "error": "Script not found"}' > "$output_file"
            elif response=$("$script" "$debate_prompt" 2>&1); then
                jq -n --arg r "$response" '{status: "success", response: $r}' > "$output_file"
            else
                jq -n --arg e "$response" '{status: "error", error: $e}' > "$output_file"
            fi
        ) &
        ROUND2_PIDS+=($!)
    done

    # Wait for round 2
    for pid in "${ROUND2_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect round 2 results
    for provider in "${PROVIDERS[@]}"; do
        result_file="${TEMP_DIR}/${provider}_r2.json"
        color=$(provider_color "$provider")
        model=$(get_model "$provider")

        if [[ -f "$result_file" ]]; then
            result=$(cat "$result_file")
            result=$(echo "$result" | jq --arg m "$model" '. + {model: $m}')
            ROUND2_RESULTS=$(echo "$ROUND2_RESULTS" | jq --arg p "$provider" --argjson r "$result" '.[$p] = $r')

            status=$(echo "$result" | jq -r '.status')
            if [[ "$status" == "error" ]]; then
                echo -e "${color}${provider}${RESET} rebuttal: ${RED}error${RESET}" >&2
            else
                echo -e "${color}${provider}${RESET} rebuttal: ${GREEN}success${RESET}" >&2
            fi
        else
            echo -e "${color}${provider}${RESET} rebuttal: ${RED}no response${RESET}" >&2
            ROUND2_RESULTS=$(echo "$ROUND2_RESULTS" | jq --arg p "$provider" --arg m "$model" '.[$p] = {status: "error", error: "No response received", model: $m}')
        fi
    done
fi

# Build metadata object
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Convert roles to JSON array
if [[ -n "$ROLES" ]]; then
    ROLES_JSON=$(echo "$ROLES" | tr ',' '\n' | jq -R . | jq -s .)
else
    ROLES_JSON="null"
fi
METADATA=$(jq -n \
    --arg prompt "$PROMPT" \
    --arg file_path "$FILE_PATH" \
    --argjson roles_used "$ROLES_JSON" \
    --argjson debate_mode "$DEBATE_MODE" \
    --argjson quiet_mode "$QUIET_MODE" \
    --arg output_path "$OUTPUT_PATH" \
    --argjson auto_context "$AUTO_CONTEXT" \
    --arg timestamp "$TIMESTAMP" \
    '{
        prompt: $prompt,
        file_path: (if $file_path == "" then null else $file_path end),
        roles_used: $roles_used,
        debate_mode: $debate_mode,
        quiet_mode: $quiet_mode,
        output_path: (if $output_path == "" then null else $output_path end),
        auto_context: $auto_context,
        timestamp: $timestamp
    }')

# Output final JSON with metadata and results
if [[ "$DEBATE_MODE" == true ]]; then
    jq -n \
        --argjson metadata "$METADATA" \
        --argjson round1 "$RESULTS" \
        --argjson round2 "$ROUND2_RESULTS" \
        '{metadata: $metadata, round1: $round1, round2: $round2}'
else
    jq -n \
        --argjson metadata "$METADATA" \
        --argjson round1 "$RESULTS" \
        '{metadata: $metadata, round1: $round1}'
fi

# Report errors to stderr
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Errors:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  - $err" >&2
    done
fi

# Lifecycle closeout: tab color, dock attention, pane handoff to interactive close.
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    council_signal_state red
else
    council_signal_state green
fi

COUNCIL_ELAPSED_MS=$(( $(now_ms) - COUNCIL_START_MS ))
COUNCIL_ATTENTION_THRESHOLD_MS="${COUNCIL_ATTENTION_THRESHOLD:-2000}"
if [[ $COUNCIL_ELAPSED_MS -ge $COUNCIL_ATTENTION_THRESHOLD_MS ]]; then
    council_signal_attention
fi

if [[ -n "$COUNCIL_PANE_DIR" ]]; then
    display_pane_close "$COUNCIL_PANE_DIR"
fi
