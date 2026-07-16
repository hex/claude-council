#!/bin/bash
# ABOUTME: Fallback model per provider, plus a TTL cache of "unavailable" verdicts
# ABOUTME: A verdict is recorded only once the fallback model has actually answered

LIB_MODEL_FALLBACK_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${LIB_MODEL_FALLBACK_DIR}/cache.sh"
# provider_env_prefix lives in providers.sh; needed for key-hash derivation.
source "${LIB_MODEL_FALLBACK_DIR}/providers.sh"

# One source of truth for the fallback map, as "provider:fallback" tokens; the
# preferred model is whatever get_model returns, so it is not repeated here.
# Mirrors the SHADOW_PAIRS idiom in providers.sh. Adding a provider is one token.
# Each id is verified against the live API before it lands here: a model can be
# listed by a provider's models endpoint and still fail a completion (gemini-2.5-pro
# is listed by Google's, and 404s on generateContent).
MODEL_FALLBACKS="openai:gpt-5.5-pro grok:grok-4.20-reasoning perplexity:sonar-pro gemini:gemini-pro-latest"

# The model a provider degrades to when its preferred model is unavailable.
# Empty for CLI providers, which degrade to their API sibling instead.
model_fallback_for() {
    local token
    for token in $MODEL_FALLBACKS; do
        [[ "${token%%:*}" == "$1" ]] && { echo "${token#*:}"; return; }
    done
    echo ""
}

# How long an "unavailable" verdict stays fresh. Deliberately independent of
# COUNCIL_CACHE_TTL and of --no-cache: a regional rollout moves on the order of
# days, and forcing fresh answers should not force a re-failed API call.
# COUNCIL_AVAILABILITY_TTL=0 disables the cache entirely.
COUNCIL_AVAILABILITY_TTL="${COUNCIL_AVAILABILITY_TTL:-86400}"

# Short digest of a provider's API key. Availability depends on the key
# (region and tier), not on the provider name, so verdicts are scoped to it.
model_fallback_key_hash() {
    local var val
    var="$(provider_env_prefix "$1")_API_KEY"
    val="${!var:-}"
    printf '%s' "$val" | sha256_hex | cut -c1-16
}

model_verdict_dir() {
    printf '%s' "${COUNCIL_CACHE_DIR}/model-verdicts"
}

# Verdict path for provider+preferred-model+key. The model is hashed so an id
# containing a slash (e.g. "models/x") cannot escape the directory.
model_verdict_file() {
    local mhash
    mhash=$(printf '%s' "$2" | sha256_hex | cut -c1-16)
    printf '%s/%s-%s-%s.json' "$(model_verdict_dir)" "$1" "$mhash" "$3"
}

# True (exit 0) if a fresh "unavailable" verdict exists for this provider+model+key.
model_unavailable_cached() {
    local file ts now age
    file="$(model_verdict_file "$1" "$2" "$3")"
    [[ -f "$file" ]] || return 1
    # A truncated or hand-edited entry yields a non-numeric timestamp, and the
    # arithmetic below would then abort the run under `set -e`. Treat any
    # unusable timestamp as epoch 0 — infinitely stale — and re-probe.
    ts=$(jq -r '.checked_at // 0' "$file" 2>/dev/null || echo 0)
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    now=$(date +%s)
    age=$((now - ts))
    [[ $age -lt $COUNCIL_AVAILABILITY_TTL ]]
}

# Record that <preferred> is unavailable for <provider> under this key. Callers
# write this only after the fallback model has answered, so an account-level 403
# — where the fallback fails too — cannot poison a day of runs with a wrong verdict.
model_unavailable_remember() {
    ensure_cache_dir
    local dir file now
    dir="$(model_verdict_dir)"
    mkdir -p "$dir"
    file="$(model_verdict_file "$1" "$2" "$3")"
    now=$(date +%s)
    jq -n --arg p "$1" --arg m "$2" --argjson t "$now" \
        '{provider: $p, model: $m, checked_at: $t}' > "$file"
}
