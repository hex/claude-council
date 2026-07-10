#!/bin/bash
# ABOUTME: Shared retry logic for API calls with exponential backoff
# ABOUTME: Source this file and use curl_with_retry instead of curl

# Configuration via environment variables
COUNCIL_MAX_RETRIES="${COUNCIL_MAX_RETRIES:-3}"
COUNCIL_RETRY_DELAY="${COUNCIL_RETRY_DELAY:-1}"
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"  # seconds per request (reasoning models need more time)

# Write a curl --config file (mode 600) holding header lines, echo its path.
# Keeps secrets (API keys) out of the process argv, where `ps` would show them.
# Usage: cfg=$(curl_secret_config "Authorization: Bearer $KEY"); curl --config "$cfg" ...
curl_secret_config() {
    local f header
    f=$(mktemp)
    chmod 600 "$f"
    for header in "$@"; do
        printf 'header = "%s"\n' "$header" >> "$f"
    done
    printf '%s' "$f"
}

# HTTP status codes that should trigger a retry
is_retryable_status() {
    local status="$1"
    case "$status" in
        429|500|502|503|504) return 0 ;;  # Retryable
        *) return 1 ;;  # Not retryable
    esac
}

# Check if curl exit code indicates timeout
is_timeout_error() {
    local exit_code="$1"
    # curl exit 28 = operation timeout
    [[ "$exit_code" -eq 28 ]]
}

# Emit a structured error body so callers can always extract .error.message.
retry_error_body() {
    jq -n --arg m "$1" '{error: {message: $m}}'
}

# Given the final HTTP code and response body (on stdin), pass the body through
# unless it is a >=400 status with no usable message — in which case synthesise
# one carrying the HTTP code, keeping the raw body for detail. Every >=400 body
# gains a top-level .http_status so callers can classify the failure.
ensure_error_body() {
    local code="$1" body
    body=$(cat)
    if [[ "$code" =~ ^[0-9]+$ ]] && (( code >= 400 )); then
        # `.error.message` on a string `.error` (xAI) raises a jq error rather
        # than yielding null, and `//` does not catch an error — so branch on
        # the type before indexing.
        if ! printf '%s' "$body" | jq -e '
            type == "object" and
            ((if (.error | type) == "object" then .error.message
              elif (.error | type) == "string" then .error
              else null end) | . != null and . != "")' >/dev/null 2>&1; then
            body=$(jq -n --arg m "HTTP $code" --arg raw "$body" '{error: {message: $m, raw: $raw}}')
        fi
        # Stamped at the top level, never under .error: .error is a bare string
        # for xAI, and Gemini's own .error.status is a string like "NOT_FOUND".
        printf '%s' "$body" | jq --argjson c "$code" '. + {http_status: $c}'
        return
    fi
    printf '%s' "$body"
}

# Perform curl with retry logic.
# Usage: curl_with_retry [curl_args...]
# Always returns 0; every failure mode leaves a JSON error body on stdout so a
# `RESPONSE=$(curl_with_retry ...)` caller under `set -e` survives and can parse
# .error.message. Callers distinguish success from failure by the body, not the
# exit code.
curl_with_retry() {
    local attempt=0
    local delay="$COUNCIL_RETRY_DELAY"
    local response=""
    local http_code=""
    local curl_exit=""
    local temp_file
    temp_file=$(mktemp)

    while [[ $attempt -le $COUNCIL_MAX_RETRIES ]]; do
        # Make request with timeout, capture HTTP status code separately
        http_code=$(curl -s --max-time "$COUNCIL_TIMEOUT" -w "%{http_code}" -o "$temp_file" "$@")
        curl_exit=$?
        response=$(cat "$temp_file")

        # Check for timeout (curl exit 28) - don't retry, fail fast
        if is_timeout_error "$curl_exit"; then
            [[ -n "${DEBUG:-}" ]] && echo "=== TIMEOUT: Request exceeded ${COUNCIL_TIMEOUT}s ===" >&2
            rm -f "$temp_file"
            retry_error_body "Request timed out after ${COUNCIL_TIMEOUT} seconds"
            return 0
        fi

        # Check for other curl errors (network issues, DNS)
        if [[ $curl_exit -ne 0 ]]; then
            if [[ $attempt -lt $COUNCIL_MAX_RETRIES ]]; then
                [[ -n "${DEBUG:-}" ]] && echo "=== RETRY: curl failed (exit $curl_exit), attempt $((attempt + 1))/$COUNCIL_MAX_RETRIES, waiting ${delay}s ===" >&2
                sleep "$delay"
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                rm -f "$temp_file"
                retry_error_body "Network request failed (curl exit ${curl_exit}) after ${COUNCIL_MAX_RETRIES} retries"
                return 0
            fi
        fi

        # Check for retryable HTTP status codes
        if is_retryable_status "$http_code"; then
            if [[ $attempt -lt $COUNCIL_MAX_RETRIES ]]; then
                [[ -n "${DEBUG:-}" ]] && echo "=== RETRY: HTTP $http_code, attempt $((attempt + 1))/$COUNCIL_MAX_RETRIES, waiting ${delay}s ===" >&2
                sleep "$delay"
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Success or non-retryable error
        rm -f "$temp_file"
        printf '%s' "$response" | ensure_error_body "$http_code"
        return 0
    done

    rm -f "$temp_file"
    printf '%s' "$response" | ensure_error_body "$http_code"
    return 0
}
