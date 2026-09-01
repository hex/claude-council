#!/usr/bin/env bats
# ABOUTME: Tests check-status.sh reporting: probe branches, rejected-key classification, remediation
# ABOUTME: Hermetic via fake CLIs and a shadow curl; no real keys or network

load test_helper
load fixtures/fake-clis
load fixtures/status-fakes

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

@test "check-status: grok logged out (stdout message, exit 0) is not authenticated" {
    # The real grok CLI prints "You are not authenticated." and exits 0, so the
    # probe must classify the unauth state from stdout, not the exit code.
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"grok login"* ]]
}

@test "check-status: unauthenticated codex is not counted available" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # antigravity and kimi-cli have no offline auth probe, so both still count;
    # codex and grok-cli both probe auth and report unauthed under auth-failure
    [[ "$output" == *"2/11 providers available"* ]]
}

@test "check-status: missing API key shows exact export remediation" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"export OPENAI_API_KEY="* ]]
    [[ "$output" == *"export PERPLEXITY_API_KEY="* ]]
}

@test "check-status: a roster seat without a key shows the same export remediation" {
    # The hint must not disappear precisely when the feature is configured: a
    # roster makes every row an openrouter-N, and the remediation table only
    # knew the bare name.
    export COUNCIL_FAKE_BEHAVIOR=valid
    export OPENROUTER_MODELS="vendor/one,vendor/two"
    unset OPENROUTER_API_KEY
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenRouter 1"* ]]
    [[ "$output" == *"export OPENROUTER_API_KEY="* ]]
}

@test "check-status: missing CLI binary shows install remediation" {
    # Drop the fakes (and any real CLIs) from PATH
    export PATH="/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm install -g @openai/codex"* ]]
    [[ "$output" == *"install the Antigravity CLI (agy)"* ]]
    [[ "$output" == *"install the Grok CLI (grok)"* ]]
}

# Shadow curl with a stub that writes a scripted body to curl's -o target and
# echoes a scripted HTTP code, so check_provider's result branches can be
# exercised offline with no real keys or network. Keys are dummy values only to
# get past the no_key guard.
#

@test "check-status: HTTP 200 reports Connected and counts the provider available" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connected"* ]]
    # 6 API providers + codex + antigravity + grok-cli + kimi-cli + ollama, all healthy
    [[ "$output" == *"11/11 providers available"* ]]
}

@test "check-status: the footer total equals the number of provider rows printed" {
    # The denominator used to be a literal, hand-bumped 3 -> 4 -> 6 -> 7 -> 10 as
    # the roster grew. Pin it to what the user can actually count on screen so a
    # future provider cannot add a row and leave the total behind. Provider rows
    # are the indented lines; the heading and the footer both start at column 0.
    # Identified by the indent rather than by the swatch glyph, which has already
    # changed shape twice, or by a tab, which the column layout removed.
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local rows total
    rows=$(printf '%s\n' "$output" | sed $'s/\033\[[0-9;]*m//g' | grep -c '^  [^ ]')
    total=$(printf '%s\n' "$output" | sed -n 's|.*[0-9][0-9]*/\([0-9][0-9]*\) providers available.*|\1|p')
    [ "$rows" -gt 0 ]
    [ "$total" = "$rows" ]
}

@test "check-status: HTTP 401 reports auth failure with regenerate remediation" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=401
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auth failed (HTTP 401)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Every API provider must classify 401, not just whichever one happens to be
    # first: a substring match alone cannot tell six rows from one.
    [ "$(auth_failures "$output")" -eq 6 ]
    # Only the five local providers remain (codex, antigravity, grok-cli, kimi-cli, ollama)
    [[ "$output" == *"5/11 providers available"* ]]
}

# Gemini answers 403 PERMISSION_DENIED for a referer-restricted key, OpenAI for a
# region block. Without the 403 arm these lose their remediation line entirely.
@test "check-status: HTTP 403 reports auth failure with regenerate remediation" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=403
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auth failed (HTTP 403)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    [ "$(auth_failures "$output")" -eq 6 ]
}

@test "check-status: HTTP 500 reports a generic error with the code" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=500
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Error (HTTP 500)"* ]]
    # A server-side fault is not a credentials problem
    [ "$(auth_failures "$output")" -eq 0 ]
    [[ "$output" == *"5/11 providers available"* ]]
}

@test "check-status: curl failure (000) reports a connection timeout" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=000
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connection timeout"* ]]
    [[ "$output" == *"5/11 providers available"* ]]
}

# Gemini and xAI answer a rejected key with 400 rather than a 401, so the status
# code alone cannot classify it and each vendor marks it differently in the body.
# The first two bodies below are what Gemini and xAI return for a rejected key;

@test "check-status: xAI 400 with an invalid-argument body reports auth failure" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Reported as an auth failure, but keeping the true code so debugging is honest
    [[ "$output" == *"Auth failed (HTTP 400)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Only Grok matches this shape; the other five 400s stay generic errors
    [ "$(auth_failures "$output")" -eq 1 ]
    [[ "$output" == *"Error (HTTP 400)"* ]]
}

@test "check-status: Gemini 400 with an INVALID_ARGUMENT body reports auth failure" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    # The details array carries API_KEY_INVALID, the only field that names the key
    export COUNCIL_FAKE_HTTP_BODY='{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com","metadata":{"service":"generativelanguage.googleapis.com"}}]}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auth failed (HTTP 400)"* ]]
    [[ "$output" == *"key rejected - regenerate it"* ]]
    # Only Gemini matches this shape; the other five 400s stay generic errors
    [ "$(auth_failures "$output")" -eq 1 ]
    [[ "$output" == *"Error (HTTP 400)"* ]]
}

# Both vendors reuse their 400 marker for faults that have nothing to do with the
# key, so these bodies are the ones that must NOT be read as a rejected key. A
# user whose model name has a typo must not be told to regenerate a working key.

@test "check-status: a Gemini 400 from a malformed model name is not a rejected key" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    # Gemini answers a name that fails its format check with the same
    # INVALID_ARGUMENT status it uses for a bad key, and carries no details array
    export COUNCIL_FAKE_HTTP_BODY='{"error":{"code":400,"message":"* GetModelRequest.name: unexpected model name format\n","status":"INVALID_ARGUMENT"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # All six API providers show the generic error: proves output was produced,
    # so the auth-failure count below cannot pass on an empty run.
    [ "$(printf '%s\n' "$output" | grep -c 'Error (HTTP 400)' || true)" -eq 6 ]
    [ "$(auth_failures "$output")" -eq 0 ]
    [[ "$output" != *"key rejected"* ]]
}

@test "check-status: an xAI 400 from an unknown model is not a rejected key" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    # xAI files an unknown model under the same code it uses for a bad key
    export COUNCIL_FAKE_HTTP_BODY='{"code":"invalid-argument","error":"Model not found: grok-does-not-exist"}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # All six API providers show the generic error: proves output was produced,
    # so the auth-failure count below cannot pass on an empty run.
    [ "$(printf '%s\n' "$output" | grep -c 'Error (HTTP 400)' || true)" -eq 6 ]
    [ "$(auth_failures "$output")" -eq 0 ]
    [[ "$output" != *"key rejected"* ]]
}

@test "check-status: a 400 that no vendor marks as a bad key stays a generic error" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"code":"failed-precondition","error":"malformed request"}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # A malformed request is not a credentials problem; do not offer to regenerate
    # All six API providers show the generic error: proves output was produced,
    # so the auth-failure count below cannot pass on an empty run.
    [ "$(printf '%s\n' "$output" | grep -c 'Error (HTTP 400)' || true)" -eq 6 ]
    [ "$(auth_failures "$output")" -eq 0 ]
    [[ "$output" != *"key rejected"* ]]
}
