#!/bin/bash
# ABOUTME: Shared retry logic for API calls with exponential backoff
# ABOUTME: Source this file and use curl_with_retry instead of curl

# Configuration via environment variables
COUNCIL_MAX_RETRIES="${COUNCIL_MAX_RETRIES:-3}"
COUNCIL_RETRY_DELAY="${COUNCIL_RETRY_DELAY:-1}"

# HTTP status codes that should trigger a retry
is_retryable_status() {
    local status="$1"
    case "$status" in
        429|500|502|503|504) return 0 ;;  # Retryable
        *) return 1 ;;  # Not retryable
    esac
}

# Perform curl with retry logic
# Usage: curl_with_retry [curl_args...]
# Returns: curl exit code, outputs response to stdout
curl_with_retry() {
    local attempt=0
    local delay="$COUNCIL_RETRY_DELAY"
    local response=""
    local http_code=""
    local curl_exit=""
    local temp_file
    temp_file=$(mktemp)

    while [[ $attempt -le $COUNCIL_MAX_RETRIES ]]; do
        # Make request, capture HTTP status code separately
        http_code=$(curl -s -w "%{http_code}" -o "$temp_file" "$@")
        curl_exit=$?
        response=$(cat "$temp_file")

        # Check for curl errors (network issues, DNS, timeout)
        if [[ $curl_exit -ne 0 ]]; then
            if [[ $attempt -lt $COUNCIL_MAX_RETRIES ]]; then
                [[ -n "$DEBUG" ]] && echo "=== RETRY: curl failed (exit $curl_exit), attempt $((attempt + 1))/$COUNCIL_MAX_RETRIES, waiting ${delay}s ===" >&2
                sleep "$delay"
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                rm -f "$temp_file"
                echo "$response"
                return $curl_exit
            fi
        fi

        # Check for retryable HTTP status codes
        if is_retryable_status "$http_code"; then
            if [[ $attempt -lt $COUNCIL_MAX_RETRIES ]]; then
                [[ -n "$DEBUG" ]] && echo "=== RETRY: HTTP $http_code, attempt $((attempt + 1))/$COUNCIL_MAX_RETRIES, waiting ${delay}s ===" >&2
                sleep "$delay"
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Success or non-retryable error
        rm -f "$temp_file"
        echo "$response"
        return 0
    done

    rm -f "$temp_file"
    echo "$response"
    return 0
}
