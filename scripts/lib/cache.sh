#!/bin/bash
# ABOUTME: Response caching for council queries
# ABOUTME: Stores responses by prompt+provider+model+verbosity hash with TTL

source "$(dirname "${BASH_SOURCE[0]}")/hash.sh"

# Cache directory (relative to project root)
COUNCIL_CACHE_DIR="${COUNCIL_CACHE_DIR:-.claude/council-cache}"
COUNCIL_CACHE_TTL="${COUNCIL_CACHE_TTL:-3600}"  # Default 1 hour in seconds

# Ensure cache directory exists. Also drops a self-ignoring .gitignore so cached
# entries — which embed full prompts and any --file contents — never land in a
# user's commits.
ensure_cache_dir() {
    [[ -d "$COUNCIL_CACHE_DIR" ]] || mkdir -p "$COUNCIL_CACHE_DIR"
    [[ -f "${COUNCIL_CACHE_DIR}/.gitignore" ]] || printf '*\n' > "${COUNCIL_CACHE_DIR}/.gitignore"
}

# Generate cache key from prompt + provider + model + verbosity + token cap.
# Verbosity and the token cap travel via env and materially change the response,
# so they must be part of the key or a re-ask at a different verbosity would be
# served the prior answer.
# Usage: cache_key <provider> <model> <prompt>
cache_key() {
    local provider="$1"
    local model="$2"
    local prompt="$3"
    local verbosity="${COUNCIL_VERBOSITY:-standard}"
    local tokens="${COUNCIL_MAX_TOKENS:-}"
    local image="${COUNCIL_IMAGE_HASH:-}"

    # Create deterministic hash from all inputs
    printf '%s' "${provider}:${model}:${verbosity}:${tokens}:${image}:${prompt}" | sha256_hex
}

# Check if cache entry exists and is valid
# Usage: cache_valid <key>
# Returns 0 if valid, 1 if expired/missing
cache_valid() {
    local key="$1"
    local cache_file="${COUNCIL_CACHE_DIR}/${key}.json"

    [[ -f "$cache_file" ]] || return 1

    local timestamp
    timestamp=$(jq -r '.timestamp // 0' "$cache_file" 2>/dev/null)
    local now
    now=$(date +%s)
    local age=$((now - timestamp))

    [[ $age -lt $COUNCIL_CACHE_TTL ]]
}

# Get cached response
# Usage: cache_get <key>
# Outputs response JSON or empty string
cache_get() {
    local key="$1"
    local cache_file="${COUNCIL_CACHE_DIR}/${key}.json"

    if cache_valid "$key"; then
        # // empty guards a corrupt entry with no .response: jq -r would emit the
        # literal string "null", which the caller would serve as a cached answer.
        jq -r '.response // empty' "$cache_file" 2>/dev/null
    fi
}

# Store response in cache
# Usage: cache_set <key> <provider> <model> <prompt> <response>
cache_set() {
    local key="$1"
    local provider="$2"
    local model="$3"
    local prompt="$4"
    local response="$5"

    ensure_cache_dir

    local cache_file="${COUNCIL_CACHE_DIR}/${key}.json"
    local timestamp
    timestamp=$(date +%s)

    # Route prompt and response through --rawfile, not --arg: a large --file
    # prompt or response passed on jq's command line would overflow ARG_MAX.
    local ptmp rtmp
    ptmp=$(mktemp); rtmp=$(mktemp)
    printf '%s' "$prompt" > "$ptmp"
    printf '%s' "$response" > "$rtmp"
    jq -n \
        --arg provider "$provider" \
        --arg model "$model" \
        --rawfile prompt "$ptmp" \
        --rawfile response "$rtmp" \
        --argjson timestamp "$timestamp" \
        '{provider: $provider, model: $model, prompt: $prompt, response: $response, timestamp: $timestamp}' \
        > "$cache_file"
    rm -f "$ptmp" "$rtmp"
}

# Clear all cache entries
cache_clear() {
    [[ -d "$COUNCIL_CACHE_DIR" ]] && rm -rf "${COUNCIL_CACHE_DIR:?}"/*
}

# Clear expired cache entries
cache_prune() {
    ensure_cache_dir
    local now
    now=$(date +%s)

    for cache_file in "${COUNCIL_CACHE_DIR}"/*.json; do
        [[ -f "$cache_file" ]] || continue
        local timestamp
        timestamp=$(jq -r '.timestamp // 0' "$cache_file" 2>/dev/null)
        local age=$((now - timestamp))
        if [[ $age -ge $COUNCIL_CACHE_TTL ]]; then
            rm -f "$cache_file"
        fi
    done
}

# Show cache stats
cache_stats() {
    ensure_cache_dir
    local total=0
    local valid=0
    local expired=0
    local now
    now=$(date +%s)

    for cache_file in "${COUNCIL_CACHE_DIR}"/*.json; do
        [[ -f "$cache_file" ]] || continue
        ((total++))
        local timestamp
        timestamp=$(jq -r '.timestamp // 0' "$cache_file" 2>/dev/null)
        local age=$((now - timestamp))
        if [[ $age -lt $COUNCIL_CACHE_TTL ]]; then
            ((valid++))
        else
            ((expired++))
        fi
    done

    echo "Cache: $valid valid, $expired expired, $total total"
}
