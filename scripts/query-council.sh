#!/bin/bash
# ABOUTME: Queries multiple AI providers in parallel and collects responses
# ABOUTME: Supports filtering by provider and outputs JSON results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${PROVIDERS_DIR:-${SCRIPT_DIR}/providers}"

# Source libraries
source "${SCRIPT_DIR}/lib/cache.sh"
source "${SCRIPT_DIR}/lib/roles.sh"
source "${SCRIPT_DIR}/lib/keys.sh"
source "${SCRIPT_DIR}/lib/display.sh"
source "${SCRIPT_DIR}/lib/verbosity.sh"
resolve_grok_key

# Helper: current time in milliseconds (falls back to seconds if python3 missing)
now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s
}

source "${SCRIPT_DIR}/lib/providers.sh"

usage() {
    cat >&2 << 'EOF'
Usage: query-council.sh [OPTIONS] [--] <prompt>

Options:
  --providers LIST    Comma-separated providers (gemini,openai,grok,perplexity)
  --roles LIST        Assign roles to providers (security,performance,maintainability)
                      Or use preset: balanced, security-focused, architecture, review
  --verbosity LEVEL   Response verbosity: brief, standard (default), detailed
  --debate            Enable two-round debate mode
  --file PATH         Include file contents in query context
  --output PATH       Export destination (passed in metadata for caller)

Note: Flags accept both --flag=value and --flag value formats.
  --quiet, -q         Suppress individual responses (passed in metadata)
  --no-cache          Skip cache, force fresh queries
  --no-auto-context   Disable auto file detection (passed in metadata)
  --no-pane           Disable streaming tmux pane (default: on inside tmux)
  --list-available    List configured providers (human-readable, with policy info)
  --list-default      List providers that would be queried by default (machine-readable)

Output: JSON with metadata and provider responses
EOF
    exit 1
}

# Parse arguments
FILTER_PROVIDERS=""
PROMPT=""
LIST_AVAILABLE=false
LIST_DEFAULT=false
USE_CACHE=true
ROLES=""
DEBATE_MODE=false
FILE_PATH=""
OUTPUT_PATH=""
QUIET_MODE=false
AUTO_CONTEXT=true
NO_PANE=false
VERBOSITY=""

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
        --verbosity=*)
            VERBOSITY="${1#*=}"
            shift
            ;;
        --verbosity)
            VERBOSITY="$2"
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
        --list-default)
            LIST_DEFAULT=true
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

# --list-default: machine-readable list of providers that a default query
# would actually run (post CLI-prefers-API filter). For tooling.
if [[ "$LIST_DEFAULT" == true ]]; then
    default_provider_set
    exit 0
fi

# --list-available: human-readable view of everything configured, grouped by
# whether the CLI-prefers-API policy would query them or shadow them.
if [[ "$LIST_AVAILABLE" == true ]]; then
    read -ra DISCOVERED <<< "$(discover_providers)"
    if [[ ${#DISCOVERED[@]} -eq 0 ]]; then
        echo "No providers configured."
        echo "  Set an API key (GEMINI_API_KEY, OPENAI_API_KEY, XAI_API_KEY/GROK_API_KEY, or PERPLEXITY_API_KEY)"
        echo "  or install a CLI agent (codex, agy)."
        exit 0
    fi
    read -ra DEFAULT_SET <<< "$(prefer_cli_over_api "${DISCOVERED[@]+"${DISCOVERED[@]}"}")"
    # Space-padded set for bash 3.2 compat (no associative arrays).
    in_default=" ${DEFAULT_SET[*]+${DEFAULT_SET[*]}} "
    SHADOWED=()
    for p in "${DISCOVERED[@]}"; do
        [[ "$in_default" != *" $p "* ]] && SHADOWED+=("$p")
    done

    echo "Default query set (${#DEFAULT_SET[@]}):"
    for p in "${DEFAULT_SET[@]+"${DEFAULT_SET[@]}"}"; do
        echo "  $p"
    done
    if [[ ${#SHADOWED[@]} -gt 0 ]]; then
        echo ""
        echo "Shadowed by CLI policy (use --providers=<name> to force):"
        for p in "${SHADOWED[@]}"; do
            cli=$(shadow_origin "$p")
            if [[ -n "$cli" ]]; then
                printf '  %-10s (%s preferred)\n' "$p" "$cli"
            else
                printf '  %s\n' "$p"
            fi
        done
    fi
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

# Validate --verbosity if specified, then export so provider scripts see it
if [[ -n "$VERBOSITY" ]]; then
    validate_verbosity "$VERBOSITY" || exit 1
    export COUNCIL_VERBOSITY="$VERBOSITY"
fi

# Validate --roles if specified
if [[ -n "$ROLES" ]]; then
    if ! validate_roles "$ROLES"; then
        exit 1
    fi
    # Normalize roles (expand presets)
    ROLES=$(normalize_roles "$ROLES")
fi

# Get list of providers to query
if [[ -n "$FILTER_PROVIDERS" ]]; then
    IFS=',' read -ra PROVIDERS <<< "$FILTER_PROVIDERS"
else
    read -ra PROVIDERS <<< "$(default_provider_set)"
fi

if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
    echo "Error: No providers configured." >&2
    echo "  Set an API key (GEMINI_API_KEY, OPENAI_API_KEY, XAI_API_KEY/GROK_API_KEY, or PERPLEXITY_API_KEY)" >&2
    echo "  or install a CLI agent (codex, agy)." >&2
    echo "  Or run '/claude-council:ask --local' for a local Claude-only council (same-model, no API keys)." >&2
    exit 1
fi

# Create temp directory for parallel results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# On a CLI provider failure, attempt its API-sibling fallback. Echoes a JSON
# object {response, model, fallback} when the sibling exists, its key is set,
# and the sibling script succeeds; echoes nothing otherwise (caller then keeps
# the original CLI error). Shared by round 1 (query_provider) and round 2.
attempt_api_fallback() {
    local provider="$1" prompt="$2"
    local sibling sibling_script sibling_model key cached p
    sibling=$(api_sibling "$provider")
    [[ -n "$sibling" ]] && api_key_present "$sibling" || return 0
    # Don't shadow-fall-back to a provider the user already selected — it
    # answers in its own slot, so duplicating it would present one vendor's
    # view twice and double the API call.
    for p in ${PROVIDERS[@]+"${PROVIDERS[@]}"}; do
        [[ "$p" == "$sibling" ]] && return 0
    done
    sibling_model=$(get_model "$sibling")
    # Reuse a cached sibling answer instead of re-hitting the paid API on a
    # repeat run; the sibling script bypasses query_provider's own cache check.
    local resp
    if [[ "$USE_CACHE" == true ]]; then
        key=$(cache_key "$sibling" "$sibling_model" "$prompt")
        cached=$(cache_get "$key")
        [[ -n "$cached" ]] && resp="$cached"
    fi
    if [[ -z "${resp:-}" ]]; then
        sibling_script="${PROVIDERS_DIR}/${sibling}.sh"
        if [[ -x "$sibling_script" ]] && resp=$("$sibling_script" "$prompt" 2>&1); then
            [[ "$USE_CACHE" == true ]] && cache_set "$key" "$sibling" "$sibling_model" "$prompt" "$resp"
        else
            return 0
        fi
    fi
    printf '%s' "$resp" | jq -Rs --arg m "$sibling_model" --arg s "$sibling" \
        '{response: ., model: $m, fallback: $s}'
}

# Compose a success slot from an attempt_api_fallback object ({response, model,
# fallback}), adding the common status/cached/role fields. Single definition so
# round 1 and round 2 build the fallback slot identically. Args: fb_json role
fallback_slot_json() {
    jq --arg role "$2" \
        '. + {status: "success", cached: false, role: (if $role == "" then null else $role end)}' <<<"$1"
}

# Handle a CLI provider that is unusable (missing script or runtime failure):
# try the API-sibling fallback, writing its answer (with pane events) on success
# or the given error otherwise. Shared by query_provider's missing-script and
# runtime-failure paths. Args: provider final_prompt output_file role error_msg start_ms
finish_with_fallback_or_error() {
    local provider="$1" final_prompt="$2" output_file="$3" role="$4"
    local error_msg="$5" start_ms="$6"
    local fb_json
    fb_json=$(attempt_api_fallback "$provider" "$final_prompt")
    if [[ -n "$fb_json" ]]; then
        fallback_slot_json "$fb_json" "$role" > "$output_file"
        if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
            local elapsed
            elapsed=$(( $(now_ms) - start_ms ))
            pane_status_event "$COUNCIL_PANE_DIR" "$provider" complete "$elapsed" "$(jq -r '.model' <<<"$fb_json")"
            pane_response_write "$COUNCIL_PANE_DIR" "$provider" "$(jq -r '.response' <<<"$fb_json")"
        fi
        return 0
    fi
    # No fallback available, or it failed too: preserve the original error.
    printf '%s' "$error_msg" | jq -Rs --arg role "$role" \
        '{status: "error", error: ., cached: false, role: (if $role == "" then null else $role end)}' > "$output_file"
    if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
        pane_error_write "$COUNCIL_PANE_DIR" "$provider" "$error_msg"
        pane_status_event "$COUNCIL_PANE_DIR" "$provider" error "" "$(get_model "$provider")"
    fi
}

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

    # Build the final prompt (with role injection if specified)
    local final_prompt
    if [[ -n "$role" ]]; then
        final_prompt=$(build_prompt_with_role "$prompt" "$role")
    else
        final_prompt="$prompt"
    fi

    local start_ms
    start_ms=$(now_ms)

    if [[ ! -x "$script" ]]; then
        # A missing/non-executable script is as unusable as a runtime failure,
        # so it gets the same API-sibling fallback rather than a bare error.
        finish_with_fallback_or_error "$provider" "$final_prompt" "$output_file" \
            "$role" "Script not found or not executable" "$start_ms"
        return
    fi

    [[ -n "${COUNCIL_PANE_DIR:-}" ]] && pane_status_event "$COUNCIL_PANE_DIR" "$provider" querying "" "$model"

    # Check cache if enabled (cache key includes role)
    if [[ "$USE_CACHE" == true ]]; then
        local key
        key=$(cache_key "$provider" "$model" "$final_prompt")
        local cached_response
        cached_response=$(cache_get "$key")
        if [[ -n "$cached_response" ]]; then
            printf '%s' "$cached_response" | jq -Rs --arg role "$role" \
                '{status: "success", response: ., cached: true, role: (if $role == "" then null else $role end)}' > "$output_file"
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
        printf '%s' "$response" | jq -Rs --arg role "$role" \
            '{status: "success", response: ., cached: false, role: (if $role == "" then null else $role end)}' > "$output_file"
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
        finish_with_fallback_or_error "$provider" "$final_prompt" "$output_file" \
            "$role" "$response" "$start_ms"
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

# provider_color and provider_emoji are defined in lib/providers.sh
# (sourced near the top of this file).

# Get model name for provider (mirrors logic in provider scripts)
# get_model is defined in lib/providers.sh (sourced near the top of this file).

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
# Probe /dev/tty once and cache the result for the council_signal_* helpers.
COUNCIL_HAS_TTY=0
council_probe_tty && COUNCIL_HAS_TTY=1
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

# Fold one provider's coerced result into an accumulator object under its
# provider key. Both blobs reach jq via STDIN, never argv: on MSYS/Windows
# ARG_MAX is ~32KB and a large response passed on the command line overflows it
# ("jq: Argument list too long"), silently dropping output. printf is a bash
# builtin, so the pipe is not bounded by ARG_MAX.
# Args: accumulator-json provider result-json   Stdout: merged accumulator
merge_result() {
    printf '%s\n%s' "$1" "$3" | jq -s --arg p "$2" '.[0] + {($p): .[1]}'
}

# Collect results
RESULTS="{}"
ERRORS=()

for provider in "${PROVIDERS[@]}"; do
    result_file="${TEMP_DIR}/${provider}.json"
    color=$(provider_color "$provider")
    model=$(get_model "$provider")

    if [[ -f "$result_file" ]]; then
        # coerce_result_json adds the model and guarantees valid JSON, so a
        # provider that wrote malformed output can't crash the whole run here.
        result=$(coerce_result_json "$(cat "$result_file")" "$model")
        RESULTS=$(merge_result "$RESULTS" "$provider" "$result")

        # Show the model that actually answered: on a fallback the slot carries
        # the API sibling's model, not this provider's CLI default. coerce_result_json
        # guarantees .model is present.
        model=$(echo "$result" | jq -r '.model')

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
                printf '%s' "$response" | jq -Rs '{status: "success", response: .}' > "$output_file"
            else
                fb_json=$(attempt_api_fallback "$provider" "$debate_prompt")
                if [[ -n "$fb_json" ]]; then
                    fallback_slot_json "$fb_json" "" > "$output_file"
                else
                    printf '%s' "$response" | jq -Rs '{status: "error", error: .}' > "$output_file"
                fi
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
            result=$(coerce_result_json "$(cat "$result_file")" "$model")
            ROUND2_RESULTS=$(merge_result "$ROUND2_RESULTS" "$provider" "$result")

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
# The prompt (large with file context) reaches jq as a raw string via STDIN,
# not argv: -Rs slurps it to a JSON string exactly as --rawfile would, with no
# argv-bounded path. See merge_result for the ARG_MAX rationale.
METADATA=$(printf '%s' "$PROMPT" | jq -Rs \
    --arg file_path "$FILE_PATH" \
    --argjson roles_used "$ROLES_JSON" \
    --argjson debate_mode "$DEBATE_MODE" \
    --argjson quiet_mode "$QUIET_MODE" \
    --arg output_path "$OUTPUT_PATH" \
    --argjson auto_context "$AUTO_CONTEXT" \
    --arg timestamp "$TIMESTAMP" \
    '{
        prompt: .,
        file_path: (if $file_path == "" then null else $file_path end),
        roles_used: $roles_used,
        debate_mode: $debate_mode,
        quiet_mode: $quiet_mode,
        output_path: (if $output_path == "" then null else $output_path end),
        auto_context: $auto_context,
        timestamp: $timestamp
    }')

# Output final JSON. Feed the large blobs (metadata + every provider response)
# to jq via STDIN, not argv — see merge_result for the ARG_MAX rationale. Each
# blob is exactly one JSON value, so `jq -s` slurps them into an array to index.
if [[ "$DEBATE_MODE" == true ]]; then
    printf '%s\n%s\n%s' "$METADATA" "$RESULTS" "$ROUND2_RESULTS" |
        jq -s '{metadata: .[0], round1: .[1], round2: .[2]}'
else
    printf '%s\n%s' "$METADATA" "$RESULTS" |
        jq -s '{metadata: .[0], round1: .[1]}'
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
    # Best-effort: the user closing the pane early already removed the watch
    # dir, and a missing display must not fail an otherwise successful query
    display_pane_close "$COUNCIL_PANE_DIR" || true
fi
