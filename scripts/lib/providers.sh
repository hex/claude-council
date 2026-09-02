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
            openrouter)
                # The one script that can seat more than once. With a roster set,
                # it enlists as openrouter-1..N instead of itself, so each model
                # gets its own header, cache key and role; without one it behaves
                # like any other API seat.
                if api_key_present openrouter; then
                    local seats=() i
                    openrouter_seat_models seats
                    if (( ${#seats[@]} > 0 )); then
                        for ((i = 1; i <= ${#seats[@]}; i++)); do
                            available+=("openrouter-$i")
                        done
                        continue
                    fi
                    is_available=true
                fi
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

# Fills the array named by $1 with the roster's model ids, in list order — the
# entries of OPENROUTER_MODELS split the way parse_provider_list splits, without
# a fork. An unset or empty roster fills nothing.
# Empty when OPENROUTER_MODELS is unset — which leaves the single `openrouter`
# seat in place, unchanged.
#
# A router can front many models at once, but the council's unit of identity is
# the seat: one header, one model label, one cache key, one role. So a roster of
# N models is N seats rather than one seat that varies, and `openrouter-N` names
# the Nth. There is no openrouter-N.sh — provider_script_path routes them all
# back to the one script, which reads COUNCIL_SEAT to learn which it is.
openrouter_seat_models() {
    local __roster="${OPENROUTER_MODELS:-}"
    read -ra "$1" <<< "${__roster//,/ }"
}

# The roster position a router seat name carries: prints N and returns 0 for
# openrouter-N with N a plain positive number, returns 1 for any other name.
# The one definition, because the number reaches array arithmetic and a glob
# alone admits shapes that are not positions: openrouter-0 would index -1,
# which is the LAST entry on bash 4.3+, and bash reads a leading zero as octal
# and aborts the run outright.
router_seat_index() {
    [[ "$1" =~ ^openrouter-([1-9][0-9]*)$ ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# The script that answers for a provider name. Every name is its own filename
# except the router's numbered seats, which share openrouter.sh.
provider_script_path() {
    if router_seat_index "$1" >/dev/null; then
        echo "${PROVIDERS_DIR}/openrouter.sh"
    else
        echo "${PROVIDERS_DIR}/$1.sh"
    fi
}

# Reads one bare key from a TOML file — the root table when $2 is empty, the
# named table otherwise. Deliberately minimal: enough for the three CLI configs
# below, with no arrays, no multi-line values and no dotted keys. Returns
# nothing when the file, table or key is absent, so callers fall back.
toml_value() {
    local file="$1" table="$2" key="$3"
    [[ -f "$file" ]] || return 0
    # Errors are swallowed and the read reports nothing, so a corrupt config
    # degrades to the "default" label. Neither half is optional: awk's
    # complaint would otherwise be stored as the provider's error text, and
    # its non-zero exit would abort the caller under set -e.
    #
    # A table header must match in full, trailing comment included. Matching
    # loosely on a leading "[" would take "[models] # mine" as a table named
    # "models] # mine" — losing the whole table — and would let any bracketed
    # line inside a multi-line value masquerade as a header.
    awk -v want="$table" -v key="$key" -v q="'" '
        # Multi-line values are skipped wholesale. Their bodies are arbitrary
        # text, and a line reading "[models]" inside one is a valid table
        # header by shape alone — no pattern can tell it from the real thing,
        # only knowing we are inside a string can.
        {
            marks = gsub(/"""/, "&") + gsub(q q q, "&")
            if (instr) { if (marks % 2) instr = 0; next }
            if (marks % 2) { instr = 1; next }
        }
        /^[[:space:]]*\[/ {
            if ($0 ~ /^[[:space:]]*\[[^]]*\][[:space:]]*(#.*)?$/) {
                cur = $0
                sub(/^[[:space:]]*\[/, "", cur)
                sub(/\][[:space:]]*(#.*)?$/, "", cur)
            }
            next
        }
        cur == want && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            # Basic strings first, then TOML literal strings; both are valid
            # for these keys and users write either.
            if (match($0, /"[^"]*"/) || match($0, q "[^" q "]*" q)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        }
    ' "$file" 2>/dev/null || true
}

# Reads one top-level key from a JSON file, the counterpart to toml_value, and
# swallows failure the same way: malformed JSON reports nothing rather than
# failing the caller under set -e.
json_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null || true
}

# The model a CLI provider will use when the council passes no model flag,
# read from the CLI's own configuration. This is what the CLI would select,
# not a record of what a given run did — the two can diverge if the model is
# switched mid-run or the vendor substitutes one server-side. Empty when the
# CLI keeps no such config (agy) or has not been configured yet.
cli_config_model() {
    case "$1" in
        # codex scopes its config to CODEX_HOME, per its own --help.
        codex)      toml_value "${CODEX_HOME:-$HOME/.codex}/config.toml" "" model ;;
        # grok's default differs by auth mode (see grok-cli.sh), so a config
        # read could in principle name a model the run did not use. Checked
        # under the council's own XAI_API_KEY env auth: `grok models` reports
        # the same id the config holds, and a run's JSON envelope attributes
        # its usage to that same id. Config and run agree there.
        grok-cli)   toml_value "$HOME/.grok/config.toml" models default ;;
        kimi-cli)   toml_value "$HOME/.kimi-code/config.toml" "" default_model ;;
        # agy records the app's current selection as a display label, spaces
        # and all ("Gemini 3.6 Flash (High)"). The key is absent until a model
        # has actually been selected, so a fresh install still reads as unset.
        antigravity) json_value "$HOME/.gemini/antigravity-cli/settings.json" model ;;
    esac
}

# Default model per provider, and the one place any of them is named: the
# provider scripts read their model from here too. API defaults are pinned ids
# (bump when a vendor ships a flagship we want to track), except gemini and grok,
# which track their vendor's rolling alias. An alias trades the pin for automatic
# tracking at a cost: the id in the cache key stays constant while the model
# behind it moves, so a cached answer can outlive the model that gave it, and the
# same is true of the model-unavailable verdicts keyed on it in model_fallback.sh.
# CLI providers pass no model flag
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
        gemini)     echo "${GEMINI_MODEL:-gemini-pro-latest}" ;;
        openai)     echo "${OPENAI_MODEL:-gpt-5.6-sol}" ;;
        grok)       echo "${GROK_MODEL:-grok-latest}" ;;
        grok-cli)   cli_model grok-cli "${GROK_CLI_MODEL:-}" ;;
        perplexity) echo "${PERPLEXITY_MODEL:-sonar-reasoning-pro}" ;;
        codex)      cli_model codex "${CODEX_MODEL:-}" ;;
        antigravity) cli_model antigravity "${ANTIGRAVITY_MODEL:-}" ;;
        kimi)       echo "${KIMI_MODEL:-kimi-k3}" ;;
        kimi-cli)   cli_model kimi-cli "${KIMI_CLI_MODEL:-}" ;;
        ollama)     echo "${OLLAMA_MODEL:-local}" ;;
        # Pinned rather than an alias for the reason stated above, and pinned to
        # an Anthropic id because that is the one vendor the council otherwise
        # has no voice for. A router's default is retargetable by design:
        # OPENROUTER_MODEL takes any id from openrouter.ai/models.
        openrouter) echo "${OPENROUTER_MODEL:-anthropic/claude-sonnet-5}" ;;
        openrouter-[0-9]*)
            # An explicit <PREFIX>_MODEL wins, exactly as it does for every other
            # provider: the exit-3 degrade path forces a fallback that way, and a
            # roster entry must not send the model that just failed.
            local __ovr __models __seat
            # A name that is not a roster position answers like a seat past the
            # end rather than reaching the arithmetic.
            __seat=$(router_seat_index "$1") || { echo "unknown"; return; }
            __ovr="$(provider_env_prefix "$1")_MODEL"
            if [[ -n "${!__ovr:-}" ]]; then
                echo "${!__ovr}"
            else
                __models=()
                openrouter_seat_models __models
                # A seat past the end of the roster reports "unknown" rather than
                # a neighbour's id, so a mislabelled answer is impossible.
                echo "${__models[$(( __seat - 1 ))]:-unknown}"
            fi
            ;;
        *)          echo "unknown" ;;
    esac
}

# True (exit 0) if the provider's default model accepts image input. The MVP
# vision set; everything else routes to a sibling or answers text-only.
provider_vision_capable() {
    case "$1" in
        gemini|openai|grok|perplexity) return 0 ;;
        # kimi.sh builds the image payload already; the default model reads it.
        # An override may not — kimi-k2 and its variants are text-only while
        # k2.5 and later are not — so an override opts in the same way the
        # router's does. kimi-cli is deliberately absent, like every other CLI:
        # a CLI cannot take an image, it reaches one only by routing here.
        # The router's curated default accepts images too, and an override
        # points at any of hundreds of routed models whose modalities are not
        # knowable from here, so both opt in the same way: the default is
        # capable, an override says so with <PREFIX>_VISION=1.
        kimi|openrouter)
            local __p __m __v
            __p="$(provider_env_prefix "$1")"; __m="${__p}_MODEL"; __v="${__p}_VISION"
            [[ -z "${!__m:-}" || "${!__v:-}" == 1 ]]
            ;;
        openrouter-[0-9]*)
            # A roster entry is whichever id the user listed, so nothing here can
            # know its modalities. Each seat opts in on its own — collectively
            # would route an image to the two seats that cannot read it.
            local __vis
            __vis="$(provider_env_prefix "$1")_VISION"
            [[ "${!__vis:-}" == 1 ]]
            ;;
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
# Callers define BLUE/WHITE/RED/GREEN/MAGENTA/CYAN/BRIGHT_BLACK; the expansions below
# default to empty so a provider that no arm names cannot abort the caller
# under `set -u` (check-status.sh defines no CYAN, so the default arm used to
# kill the whole status run the moment any new provider was added).
provider_color() {
    case "$1" in
        gemini|antigravity) echo -e "${BLUE:-}" ;;
        openai|codex)      echo -e "${WHITE:-}" ;;
        grok|grok-cli)     echo -e "${RED:-}" ;;
        perplexity)        echo -e "${GREEN:-}" ;;
        kimi|kimi-cli)     echo -e "${BRIGHT_BLACK:-}" ;;
        ollama)            echo -e "${CYAN:-}" ;;
        openrouter|openrouter-[0-9]*) echo -e "${MAGENTA:-}" ;;
        *)                 echo -e "${CYAN:-}" ;;
    esac
}

# Vendor RGB triplet for a provider name, as a 24-bit foreground colour over the
# user's unknown terminal background — mid-tone shades readable on light and
# dark themes. Writes the triplet into the variable named by $1 (printf -v avoids
# a subshell). Same grouping as provider_color: CLI variants speak for the same
# vendor as their API sibling.
provider_color_rgb() {
    local __out="$1"
    case "$2" in
        gemini|antigravity) printf -v "$__out" '59;130;246'   ;;  # blue-500
        openai|codex)      printf -v "$__out" '100;116;139'  ;;  # slate-500
        grok|grok-cli)     printf -v "$__out" '239;68;68'    ;;  # red-500
        perplexity)        printf -v "$__out" '22;163;74'    ;;  # green-600
        kimi|kimi-cli)     printf -v "$__out" '63;63;70'     ;;  # zinc-700
        ollama)            printf -v "$__out" '8;145;178'    ;;  # cyan-600
        openrouter|openrouter-[0-9]*) printf -v "$__out" '124;58;237' ;;  # violet-600
        *)                 printf -v "$__out" '113;113;122'  ;;  # zinc-500
    esac
}

# The provider's colour swatch that precedes its name in every listing: one
# circle in the provider's own colour.
#
# Two earlier shapes did not survive contact with real terminals. Emoji squares
# come in seven colours with no black, and the two codepoints that fill the gaps
# (U+2B1B, U+2B1C) render at text width in many fonts, so they sat narrower than
# their neighbours and broke the column. Drawn blocks fixed the width but
# inherited the cell's roughly 1:2 aspect, reading as a tall bar rather than a
# chip. A circle is drawn to shape by the font, so it is round at any cell
# aspect, occupies exactly one column for every provider, and takes its colour
# from the RGB table above rather than from whichever squares Unicode ships.
provider_swatch() {
    local __rgb
    provider_color_rgb __rgb "$1"
    printf '\033[38;2;%sm●\033[0m' "$__rgb"
}
