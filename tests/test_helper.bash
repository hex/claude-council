# ABOUTME: Common test utilities and setup for bats tests
# ABOUTME: Sourced by all test files to provide shared fixtures and helpers

# Project root directory
export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
export SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
export LIB_DIR="${SCRIPTS_DIR}/lib"
export CONFIG_DIR="${PROJECT_ROOT}/config"

# Resolve bash before any setup() strips CLI directories from PATH: those dirs
# can also hold the bash users actually run (e.g. Homebrew's 5.x), and falling
# back to /bin/bash 3.2 masks expansion errors that are fatal on modern bash.
# Scripts under test should be invoked as: "$HOST_BASH" "$SCRIPT" ...
export HOST_BASH="$(command -v bash)"

# Test-specific directories
export TEST_TMP_DIR="${BATS_TEST_TMPDIR:-/tmp/council-tests}"
export TEST_CACHE_DIR="${TEST_TMP_DIR}/cache"
export TEST_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"

# Override cache dir for tests
export COUNCIL_CACHE_DIR="$TEST_CACHE_DIR"
export COUNCIL_CACHE_TTL=3600

# Tests should never spawn the streaming tmux pane — it spawns a real
# split that waits for keypress, leaving orphans that accumulate across
# bats runs. NO_PANE skips opening; AUTO_CLOSE is a belt-and-suspenders
# fallback if any code path bypasses NO_PANE in the future.
export COUNCIL_NO_PANE=1
export COUNCIL_AUTO_CLOSE=1

# A roster pinned in the developer's own shell would otherwise decide which
# providers the suite queries — the README tells users to export this, so a
# machine configured as documented must not turn the suite red.
unset COUNCIL_PROVIDERS

# Same reasoning for the per-provider model overrides: the README documents
# exporting these, and a pinned one wins over the default the suite asserts.
# A test that wants an override sets it on its own invocation.
unset GEMINI_MODEL OPENAI_MODEL GROK_MODEL PERPLEXITY_MODEL KIMI_MODEL OLLAMA_MODEL
unset CODEX_MODEL ANTIGRAVITY_MODEL GROK_CLI_MODEL KIMI_CLI_MODEL OPENROUTER_MODEL
# OPENROUTER_VISION is read alongside OPENROUTER_MODEL by provider_vision_capable,
# so a developer who exported it would flip the vision answer the suite asserts.
unset OPENROUTER_VISION

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

# Helper: clear every provider API key so discovery sees none of them
unset_provider_keys() {
    unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY XAI_API_KEY PERPLEXITY_API_KEY
    unset KIMI_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY
}

# Helper: block until any of the given files exists. Gives up after ~8s so a
# producer or watcher that never writes the file cannot hang the test. Written
# with `if`, not `[[ ]] && return`, so it survives errexit inside bats.
await_any_file() {
    local waited=0 f
    while true; do
        for f in "$@"; do
            [[ -e "$f" ]] && return 0
        done
        sleep 0.05
        waited=$((waited + 1))
        if [[ $waited -gt 160 ]]; then
            echo "timed out waiting for any of: $*" >&2
            return 1
        fi
    done
}

# Helper: assert a string is empty or whitespace-only
assert_blank() {
    [[ -z "${1//[[:space:]]/}" ]]
}

# Helper: assert a string carries something a user could act on. A provider that
# fails silently is worse than one that fails loudly — the council stores the
# script's own output as the error text, so a blank one renders an empty slot.
assert_not_blank() {
    [[ -n "${1//[[:space:]]/}" ]]
}

# Helper: compute a PATH that excludes the directories holding codex and gemini.
# Use when a test needs to assert "no providers available" on a developer machine
# that has the CLI agents installed.
# Removes the DIRECTORY each binary-gated CLI lives in, so discovery finds
# none of them. Caveat worth knowing before adding an entry: a CLI installed
# into a shared prefix takes that whole prefix out of PATH for the test — put
# nothing here that commonly shares a directory with jq, curl or node.
path_without_clis() {
    local clean=$PATH
    local cli dir
    for cli in codex gemini agy grok kimi ollama; do
        dir=$(dirname "$(command -v "$cli" 2>/dev/null)" 2>/dev/null || true)
        [[ -n "$dir" ]] || continue
        clean=$(echo "$clean" | tr ':' '\n' | grep -vF -- "$dir" | tr '\n' ':')
    done
    echo "${clean%:}"
}

# Helper: put a jq on PATH whose stdout ends every line with \r\n, as jq's
# Windows build does when piped. Sets CRLF_BIN; prefix PATH="$CRLF_BIN:$PATH"
# on the one invocation under test so the test's own jq calls stay clean.
install_crlf_jq() {
    local real_jq
    real_jq=$(command -v jq)
    CRLF_BIN="${BATS_TEST_TMPDIR}/crlf-bin"
    mkdir -p "$CRLF_BIN"
    cat > "$CRLF_BIN/jq" <<EOF
#!/bin/bash
"$real_jq" "\$@" | sed 's/\$/\r/'
exit "\${PIPESTATUS[0]}"
EOF
    chmod +x "$CRLF_BIN/jq"
    export CRLF_BIN
}

# Helper: put a jq on PATH that records every argument it is given, then execs
# the real one. Sets JQ_BIN (prefix it onto PATH) and JQ_ARGV_FILE. Used to
# prove a large prompt is never passed to jq on the command line, where MSYS's
# ~32KB ARG_MAX would reject it.
install_recording_jq() {
    local real_jq
    real_jq=$(command -v jq)
    JQ_BIN="${BATS_TEST_TMPDIR}/jq-bin"
    JQ_ARGV_FILE="${BATS_TEST_TMPDIR}/jq-argv"
    mkdir -p "$JQ_BIN"
    : > "$JQ_ARGV_FILE"
    cat > "$JQ_BIN/jq" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$JQ_ARGV_FILE"
exec "$real_jq" "\$@"
EOF
    chmod +x "$JQ_BIN/jq"
    export JQ_BIN JQ_ARGV_FILE
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
