#!/bin/bash
# ABOUTME: Response caching for council queries
# ABOUTME: Stores responses by prompt+provider+model hash with TTL

# Cache directory (relative to project root)
COUNCIL_CACHE_DIR="${COUNCIL_CACHE_DIR:-.claude/council-cache}"
COUNCIL_CACHE_TTL="${COUNCIL_CACHE_TTL:-3600}"  # Default 1 hour in seconds

# Ensure cache directory exists
ensure_cache_dir() {
    [[ -d "$COUNCIL_CACHE_DIR" ]] || mkdir -p "$COUNCIL_CACHE_DIR"
}

# Generate cache key from prompt + provider + model
# Usage: cache_key <provider> <model> <prompt>
cache_key() {
    local provider="$1"
    local model="$2"
    local prompt="$3"

    # Create deterministic hash from all inputs
    echo -n "${provider}:${model}:${prompt}" | shasum -a 256 | cut -d' ' -f1
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
        jq -r '.response' "$cache_file" 2>/dev/null
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

    jq -n \
        --arg provider "$provider" \
        --arg model "$model" \
        --arg prompt "$prompt" \
        --arg response "$response" \
        --argjson timestamp "$timestamp" \
        '{provider: $provider, model: $model, prompt: $prompt, response: $response, timestamp: $timestamp}' \
        > "$cache_file"
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
