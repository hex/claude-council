#!/usr/bin/env bats
# ABOUTME: Tests check-status.sh provider probes, rejected-key classification, and remediation
# ABOUTME: Hermetic via fake CLIs and a shadow curl; no real keys or network

load test_helper
load fixtures/fake-clis

SCRIPT="${SCRIPTS_DIR}/check-status.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    unset_provider_keys
}

@test "fixture: --version succeeds even under auth-failure behavior" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run codex --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"fake-codex"* ]]
}

@test "check-status: authed CLI provider shows Connected" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex CLI"* ]]
    [[ "$output" == *"Connected"* ]]
}

@test "check-status: codex installed but unauthenticated is its own state" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed, not authenticated"* ]]
    [[ "$output" == *"codex login"* ]]
}

@test "check-status: unauthenticated codex is not counted available" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # antigravity (no auth probe) is the only available provider
    [[ "$output" == *"1/6 providers available"* ]]
}

@test "check-status: missing API key shows exact export remediation" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"export OPENAI_API_KEY="* ]]
    [[ "$output" == *"export PERPLEXITY_API_KEY="* ]]
}

@test "check-status: missing CLI binary shows install remediation" {
    # Drop the fakes (and any real CLIs) from PATH
    export PATH="/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm install -g @openai/codex"* ]]
    [[ "$output" == *"install the Antigravity CLI (agy)"* ]]
}

# Shadow curl with a stub that writes a scripted body to curl's -o target and
# echoes a scripted HTTP code, so check_provider's result branches can be
# exercised offline with no real keys or network. Keys are dummy values only to
# get past the no_key guard.
#
# The stub exits non-zero on a failed transfer (code 000) because that is what
# the real binary does: curl writes 000 through -w and also exits non-zero (7 on
# a refused connection, 28 on a timeout), and the stub picks one such code. A
# stub that always exits 0 would let the script's transfer-failure branch pass
# without ever running under a non-zero curl.
shadow_curl() {
    local dir="${BATS_TEST_TMPDIR}/fakecurl"
    mkdir -p "$dir"
    cat > "$dir/curl" <<'EOF'
#!/bin/bash
code="${COUNCIL_FAKE_HTTP_CODE:-200}"
# Mirror curl's -o: the body lands in the named file, never on stdout, so a
# probe that inspects the body reads it exactly as it would from the real thing.
out=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then out="$arg"; fi
    prev="$arg"
done
if [[ -n "$out" ]]; then printf '%s' "${COUNCIL_FAKE_HTTP_BODY:-}" > "$out"; fi
printf '%s' "$code"
if [[ "$code" == "000" ]]; then exit 7; fi
exit 0
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
    export GEMINI_API_KEY=k OPENAI_API_KEY=k XAI_API_KEY=k PERPLEXITY_API_KEY=k
    export COUNCIL_FAKE_BEHAVIOR=valid
}

@test "check-status: HTTP 200 reports Connected and counts the provider available" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connected"* ]]
    # 4 API providers + codex + antigravity, all healthy
    [[ "$output" == *"6/6 providers available"* ]]
}

@test "check-status: HTTP 401 reports auth failure with regenerate remediation" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=401
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auth failed (HTTP 401)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Only the two CLI providers remain available
    [[ "$output" == *"2/6 providers available"* ]]
}

@test "check-status: HTTP 500 reports a generic error with the code" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=500
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Error (HTTP 500)"* ]]
    [[ "$output" == *"2/6 providers available"* ]]
}

@test "check-status: curl failure (000) reports a connection timeout" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=000
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connection timeout"* ]]
    [[ "$output" == *"2/6 providers available"* ]]
}

# Gemini and xAI answer a rejected key with 400 rather than a 401, so the status
# code alone cannot classify it and each vendor marks it differently in the body.
# The first two bodies below are what Gemini and xAI return for a rejected key;
# the third is a 400 that no vendor marks as a credentials problem. The two
# vendor tests each assert that exactly one provider is flagged, so neither
# vendor's body shape can satisfy the other's rule.

# Count the providers reported as an auth failure (one row per provider).
auth_failures() {
    printf '%s\n' "$1" | grep -c 'Auth failed' || true
}

@test "check-status: xAI 400 with an invalid-argument body reports auth failure" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Reported as an auth failure, but keeping the true code so debugging is honest
    [[ "$output" == *"Auth failed (HTTP 400)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Only Grok matches this shape; the other three 400s stay generic errors
    [ "$(auth_failures "$output")" -eq 1 ]
    [[ "$output" == *"Error (HTTP 400)"* ]]
}

@test "check-status: Gemini 400 with an INVALID_ARGUMENT body reports auth failure" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auth failed (HTTP 400)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Only Gemini matches this shape; the other three 400s stay generic errors
    [ "$(auth_failures "$output")" -eq 1 ]
    [[ "$output" == *"Error (HTTP 400)"* ]]
}

@test "check-status: a 400 that no vendor marks as a bad key stays a generic error" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"code":"failed-precondition","error":"malformed request"}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # A malformed request is not a credentials problem; do not offer to regenerate
    [[ "$output" == *"Error (HTTP 400)"* ]]
    [ "$(auth_failures "$output")" -eq 0 ]
    [[ "$output" != *"key rejected"* ]]
}

# ---- secret hygiene: /status probes must keep keys off the process argv ----

# Recording curl: appends its argv (one arg per line) to CS_ARGV_FILE, copies any
# --config file's contents to CS_CONFIG_FILE, then prints the scripted HTTP code.
record_curl() {
    local dir="${BATS_TEST_TMPDIR}/reccurl"
    mkdir -p "$dir"
    export CS_ARGV_FILE="${BATS_TEST_TMPDIR}/argv"
    export CS_CONFIG_FILE="${BATS_TEST_TMPDIR}/cfg"
    : > "$CS_ARGV_FILE"; : > "$CS_CONFIG_FILE"
    cat > "$dir/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CS_ARGV_FILE"
prev=""
for a in "$@"; do
    [[ "$prev" == "--config" && -f "$a" ]] && cat "$a" >> "$CS_CONFIG_FILE"
    prev="$a"
done
printf '%s' "${COUNCIL_FAKE_HTTP_CODE:-200}"
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
    export GEMINI_API_KEY=SEKRET_GEM OPENAI_API_KEY=SEKRET_OAI \
           XAI_API_KEY=SEKRET_GROK PERPLEXITY_API_KEY=SEKRET_PPX
    export COUNCIL_FAKE_BEHAVIOR=valid
}

# Perplexity is the one provider probed with a chat request, and it rejects any
# request below 16 output tokens with HTTP 400 ("max_tokens must be at least
# 16"). A probe cheaper than the floor is not a cheaper probe, it is a broken
# one, and record_curl cannot notice: only the payload we send can.
@test "check-status: the Perplexity probe requests at least the API's minimum max_tokens" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$CS_ARGV_FILE" ]
    local payload max_tokens
    payload=$(grep -o '{"model":"sonar".*}' "$CS_ARGV_FILE" | head -1)
    [ -n "$payload" ]
    max_tokens=$(printf '%s' "$payload" | jq -r '.max_tokens')
    [ "$max_tokens" -ge 16 ]
}

@test "check-status: probe API keys never appear on the curl argv" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Guard against a vacuous pass: curl must have actually run and recorded argv.
    [ -s "$CS_ARGV_FILE" ]
    # None of the four keys may reach the process table (ps-visible for the 10s probe).
    ! grep -qF "SEKRET_GEM" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_OAI" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_GROK" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_PPX" "$CS_ARGV_FILE"
    # They must instead travel via the mode-600 --config file.
    grep -qF "SEKRET_GEM" "$CS_CONFIG_FILE"
    grep -qF "SEKRET_OAI" "$CS_CONFIG_FILE"
}

@test "check-status: now_ms scales the date fallback to milliseconds" {
    # Durations render as "(Nms)"; without python3 the fallback must be
    # date-seconds * 1000, never bare seconds (which would show ~1000x too small).
    run grep -qE '\|\| *date \+%s *$' "$SCRIPT"
    [ "$status" -ne 0 ]
}
