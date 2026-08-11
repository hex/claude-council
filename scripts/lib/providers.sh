#!/bin/bash
# ABOUTME: Provider discovery + selection policy shared by query-council.sh
# ABOUTME: Caller must export PROVIDERS_DIR before sourcing for discover_providers

# Discover which provider scripts are available to query.
# API providers are gated on their <NAME>_API_KEY env var; subscription-auth
# CLI providers (codex, antigravity, grok-cli) are gated on their binary being on PATH.
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
            antigravity)
                command -v agy >/dev/null 2>&1 && is_available=true
                ;;
            grok-cli)
                command -v grok >/dev/null 2>&1 && is_available=true
                ;;
            kimi-cli)
                command -v kimi >/dev/null 2>&1 && is_available=true
                ;;
            ollama)
                command -v ollama >/dev/null 2>&1 && is_available=true
                ;;
            *)
                # API providers gate on <NAME>_API_KEY — the same check
                # api_key_present makes, so there's one definition of it.
                api_key_present "$name" && is_available=true
                ;;
        esac

        if [[ "$is_available" == true ]]; then
            available+=("$name")
        fi
    done

    echo "${available[@]+"${available[@]}"}"
}

# Single source of truth for the API↔CLI shadowing pairs, as "api:cli" tokens.
# Both shadow_origin and api_sibling derive from this list, so they cannot
# drift: adding a pair is a one-line change here that propagates to
# prefer_cli_over_api, the --list-available display, and the CLI→API fallback.
SHADOW_PAIRS="openai:codex gemini:antigravity grok:grok-cli kimi:kimi-cli"

# Returns the CLI provider that shadows the given API provider (empty if none).
shadow_origin() {
    local pair
    for pair in $SHADOW_PAIRS; do
        [[ "${pair%%:*}" == "$1" ]] && { echo "${pair#*:}"; return; }
    done
    echo ""
}

# Reverse of shadow_origin: the API provider a failed CLI provider falls back
# to (empty if none). Derived from the same SHADOW_PAIRS, so it cannot drift
# from shadow_origin.
api_sibling() {
    local pair
    for pair in $SHADOW_PAIRS; do
        [[ "${pair#*:}" == "$1" ]] && { echo "${pair%%:*}"; return; }
    done
    echo ""
}

# Env-var prefix for a provider name: uppercased, with hyphens mapped to
# underscores (grok-cli -> GROK_CLI). A hyphen kept in the name would make
# derived vars like GROK-CLI_MODEL invalid, and expanding an invalid name
# via ${!var} is fatal on bash 5.x.
provider_env_prefix() {
    echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

# True (exit 0) if the API key env var for an API provider is set. Uses the
# same <NAME>_API_KEY convention discover_providers gates on, so any API
# provider is covered without a per-provider case arm.
api_key_present() {
    local var
    var="$(provider_env_prefix "$1")_API_KEY"
    [[ -n "${!var:-}" ]]
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
    local requested=" $* "
    local p out=() shadow_cli
    for p in "$@"; do
        shadow_cli=$(shadow_origin "$p")
        if [[ -n "$shadow_cli" && "$requested" == *" $shadow_cli "* ]]; then
            continue
        fi
        out+=("$p")
    done
    echo "${out[@]+"${out[@]}"}"
}

# Discovery + policy in one step: the providers a default query would run.
#
# COUNCIL_PROVIDERS pins a standing roster ahead of discovery, which otherwise
# enlists every agent on PATH (ollama in particular joins uninvited once
# installed) with no way to say "these, every time" short of retyping
# --providers. A pinned roster is taken verbatim, like --providers: the
# CLI-prefers-API filter exists to resolve what discovery guessed at, and there
# is nothing to guess when the set was named explicitly.
#
# This lives here rather than at the query call site so that --list-default,
# which promises the providers a default query would actually run, keeps telling
# the truth.
default_provider_set() {
    if [[ -n "${COUNCIL_PROVIDERS:-}" ]]; then
        parse_provider_list "$COUNCIL_PROVIDERS"
        return 0
    fi
    local discovered
    read -ra discovered <<< "$(discover_providers)"
    prefer_cli_over_api "${discovered[@]+"${discovered[@]}"}"
}

# Splits a comma-separated roster into space-separated names, tolerating spaces
# around the commas and dropping empty entries. --providers and COUNCIL_PROVIDERS
# are documented as one mechanism at two precedences, so they share this rather
# than each splitting their own way: a roster pasted into a shell rc is where a
# stray space actually turns up, and an entry of " antigravity" resolves to no
# provider script at all.
parse_provider_list() {
    local parsed
    read -ra parsed <<< "${1//,/ }"
    echo "${parsed[*]+"${parsed[*]}"}"
}

# Reads one bare key from a TOML file — the root table when $2 is empty, the
# named table otherwise. Deliberately minimal: enough for the three CLI configs
# below, with no arrays, no multi-line values and no dotted keys. Returns
# nothing when the file, table or key is absent, so callers fall back.
toml_value() {
    local file="$1" table="$2" key="$3"
    [[ -f "$file" ]] || return 0
    awk -v want="$table" -v key="$key" '
        /^[[:space:]]*\[/ {
            cur = $0
            sub(/^[[:space:]]*\[/, "", cur)
            sub(/\][[:space:]]*$/, "", cur)
            next
        }
        cur == want && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (match($0, /"[^"]*"/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        }
    ' "$file"
}

# The model a CLI provider will use when the council passes no model flag,
# read from the CLI's own configuration. This is what the CLI would select,
# not a record of what a given run did — the two can diverge if the model is
# switched mid-run or the vendor substitutes one server-side. Empty when the
# CLI keeps no such config (agy) or has not been configured yet.
cli_config_model() {
    case "$1" in
        codex)      toml_value "$HOME/.codex/config.toml" "" model ;;
        grok-cli)   toml_value "$HOME/.grok/config.toml" models default ;;
        kimi-cli)   toml_value "$HOME/.kimi-code/config.toml" "" default_model ;;
    esac
}

# Default model per provider. API defaults are pinned ids; bump when a vendor
# ships a new flagship we want to track. CLI providers pass no model flag
# unless the *_MODEL override is set, so their model is whatever their own
# config selects; "default" remains for the CLIs that publish no such config
# and for a CLI that has not been configured. The value reaches the cache key,
# so reconfiguring a CLI's model correctly stops the council serving an answer
# the previous model gave.
# Resolves a CLI provider's model: the explicit override in $2, else what the
# CLI's own config selects, else the label. Kept separate from get_model so the
# three-stage fallback is stated once rather than per provider.
cli_model() {
    local provider="$1" override="$2" configured
    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    configured=$(cli_config_model "$provider")
    printf '%s\n' "${configured:-default}"
}

get_model() {
    case "$1" in
        gemini)     echo "${GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
        openai)     echo "${OPENAI_MODEL:-gpt-5.6-sol}" ;;
        grok)       echo "${GROK_MODEL:-grok-4.5}" ;;
        grok-cli)   cli_model grok-cli "${GROK_CLI_MODEL:-}" ;;
        perplexity) echo "${PERPLEXITY_MODEL:-sonar-reasoning-pro}" ;;
        codex)      cli_model codex "${CODEX_MODEL:-}" ;;
        antigravity) cli_model antigravity "${ANTIGRAVITY_MODEL:-}" ;;
        kimi)       echo "${KIMI_MODEL:-kimi-k3}" ;;
        kimi-cli)   cli_model kimi-cli "${KIMI_CLI_MODEL:-}" ;;
        ollama)     echo "${OLLAMA_MODEL:-local}" ;;
        *)          echo "unknown" ;;
    esac
}

# True (exit 0) if the provider's default model accepts image input. The MVP
# vision set; everything else routes to a sibling or answers text-only.
provider_vision_capable() {
    case "$1" in
        gemini|openai|grok|perplexity) return 0 ;;
        *) return 1 ;;
    esac
}

# Merge the model name into a provider's raw result, guaranteeing valid JSON.
# Provider scripts can write arbitrary bytes to their result file; feeding
# invalid JSON straight to the collection loop's accumulator merge aborts the
# whole run under `set -e`, so one broken provider would take down every other
# provider's result. Invalid input is coerced into a structured error instead.
# Usage: coerce_result_json <raw> <model>
# Stdout: a valid JSON object carrying a .model field
coerce_result_json() {
    local raw="$1" model="$2"
    # The result must be a JSON object: `. + {model}` is a type error on a
    # scalar (e.g. a bare `42`) or array, and empty input yields no value at
    # all — both produce empty output that breaks the downstream accumulator
    # merge the same way unparseable bytes do. One `type == "object"` check
    # covers them.
    if ! jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
        raw=$(jq -n --arg e "Provider returned invalid JSON: $(head -c 120 <<<"$raw")" \
            '{status: "error", error: $e, cached: false}')
    fi
    # {model:$m} + . lets a model already present in the result win; the
    # default applies only when the provider didn't set one (fallback results
    # carry the API sibling's model and must not be relabeled here).
    jq --arg m "$model" '{model: $m} + .' <<<"$raw"
}

# Vendor color for a provider name. CLI variants share their vendor's color
# (codex with openai, antigravity with gemini, grok-cli with grok) since they
# speak for the same vendor.
# Callers define BLUE/WHITE/RED/GREEN/MAGENTA/CYAN; the expansions below
# default to empty so a provider that no arm names cannot abort the caller
# under `set -u` (check-status.sh defines no CYAN, so the default arm used to
# kill the whole status run the moment any new provider was added).
provider_color() {
    case "$1" in
        gemini|antigravity) echo -e "${BLUE:-}" ;;
        openai|codex)      echo -e "${WHITE:-}" ;;
        grok|grok-cli)     echo -e "${RED:-}" ;;
        perplexity)        echo -e "${GREEN:-}" ;;
        kimi|kimi-cli)     echo -e "${MAGENTA:-}" ;;
        ollama)            echo -e "${CYAN:-}" ;;
        *)                 echo -e "${CYAN:-}" ;;
    esac
}

# Vendor emoji for a provider name. Same grouping as provider_color.
provider_emoji() {
    case "$1" in
        gemini|antigravity) echo "🟦" ;;
        openai|codex)      echo "🔳" ;;
        grok|grok-cli)     echo "🟥" ;;
        perplexity)        echo "🟩" ;;
        kimi|kimi-cli)     echo "🟪" ;;
        ollama)            echo "⬜" ;;
        *)                 echo "⬛" ;;
    esac
}
