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

# Apply the CLI-prefers-API policy to a list of provider names.
# Pairs: codex shadows openai; gemini-cli shadows gemini.
# When the CLI variant of a pair is in the input, drop the API variant.
# This only runs when --providers is NOT specified — explicit user filters
# always win over the policy (e.g. `--providers openai` still queries the API).
#
# Args: provider names (one per arg)
# Stdout: filtered names, space-separated, original order preserved
prefer_cli_over_api() {
    local p has_codex=false has_gemini_cli=false out=()
    for p in "$@"; do
        [[ "$p" == codex ]] && has_codex=true
        [[ "$p" == gemini-cli ]] && has_gemini_cli=true
    done
    for p in "$@"; do
        [[ "$p" == openai && "$has_codex" == true ]] && continue
        [[ "$p" == gemini && "$has_gemini_cli" == true ]] && continue
        out+=("$p")
    done
    echo "${out[@]+"${out[@]}"}"
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
