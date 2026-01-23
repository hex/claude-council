# ABOUTME: Common test utilities and setup for bats tests
# ABOUTME: Sourced by all test files to provide shared fixtures and helpers

# Project root directory
export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
export SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
export LIB_DIR="${SCRIPTS_DIR}/lib"
export CONFIG_DIR="${PROJECT_ROOT}/config"

# Test-specific directories
export TEST_TMP_DIR="${BATS_TEST_TMPDIR:-/tmp/council-tests}"
export TEST_CACHE_DIR="${TEST_TMP_DIR}/cache"
export TEST_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"

# Override cache dir for tests
export COUNCIL_CACHE_DIR="$TEST_CACHE_DIR"
export COUNCIL_CACHE_TTL=3600

# Setup - runs before each test
setup() {
    mkdir -p "$TEST_TMP_DIR"
    mkdir -p "$TEST_CACHE_DIR"
}

# Teardown - runs after each test
teardown() {
    rm -rf "$TEST_CACHE_DIR"/*
}

# Helper: check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Helper: assert JSON field equals value
# Usage: assert_json_eq "$json" ".field" "expected"
assert_json_eq() {
    local json="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual=$(echo "$json" | jq -r "$path")
    if [[ "$actual" != "$expected" ]]; then
        echo "JSON assertion failed: $path"
        echo "  Expected: $expected"
        echo "  Actual: $actual"
        return 1
    fi
}

# Helper: assert JSON field exists
assert_json_has() {
    local json="$1"
    local path="$2"
    if ! echo "$json" | jq -e "$path" >/dev/null 2>&1; then
        echo "JSON field missing: $path"
        return 1
    fi
}

# Helper: create mock provider response
mock_provider_response() {
    local status="${1:-success}"
    local response="${2:-Test response}"
    local cached="${3:-false}"
    jq -n --arg s "$status" --arg r "$response" --argjson c "$cached" \
        '{status: $s, response: $r, cached: $c}'
}
