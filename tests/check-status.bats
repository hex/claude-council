#!/usr/bin/env bats
# ABOUTME: Tests check-status.sh reporting: probe branches, rejected-key classification, remediation
# ABOUTME: Hermetic via fake CLIs and a shadow curl; no real keys or network

load test_helper
bats_require_minimum_version 1.5.0
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
    # codex, grok-cli and cursor-cli probe auth and report unauthed under auth-failure
    [[ "$output" == *"2/12 providers available"* ]]
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

@test "check-status: a connected roster seat names the model the query would send" {
    # OPENROUTER_<N>_MODEL overrides a roster entry, and the exit-3 degrade path
    # sets it; a connected row that still showed the roster entry would report a
    # model the council would not send. shadow_curl sets the keys and a 200, so
    # each seat connects and its last column carries the model rather than a hint.
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    export OPENROUTER_MODELS="vendor/one,vendor/two"
    export OPENROUTER_2_MODEL="vendor/two-pinned"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenRouter 1"*"vendor/one"* ]]
    [[ "$output" == *"OpenRouter 2"*"vendor/two-pinned"* ]]
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
    # 6 API providers + codex + antigravity + grok-cli + kimi-cli + cursor-cli + ollama, all healthy
    [[ "$output" == *"12/12 providers available"* ]]
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
    # Only the six local providers remain (codex, antigravity, grok-cli, kimi-cli, cursor-cli, ollama)
    [[ "$output" == *"6/12 providers available"* ]]
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
    [[ "$output" == *"6/12 providers available"* ]]
}

@test "check-status: curl failure (000) reports a connection timeout" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=000
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connection timeout"* ]]
    [[ "$output" == *"6/12 providers available"* ]]
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

@test "check-status: cursor-cli row, and a logged-out cursor-agent is its own state" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor CLI"* ]]
    # The real CLI prints "Not logged in" and exits 0, so the probe must
    # classify the state from stdout, as it does for grok.
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cursor-agent login"* ]]
}

@test "check-status: a missing cursor-agent names the binary to install" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    rm "$FAKE_BIN_DIR/cursor-agent"
    # Drop only the directory a real cursor-agent lives in, so jq and bash
    # stay reachable; on a machine without one the PATH is left alone.
    local real_dir clean
    real_dir=$(dirname "$(command -v cursor-agent 2>/dev/null)" 2>/dev/null || true)
    clean=$PATH
    [[ -n "$real_dir" ]] && clean=$(echo "$PATH" | tr ':' '\n' | grep -vxF -- "$real_dir" | paste -sd: -)
    run bash -c "export PATH='$clean'; bash '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install the Cursor CLI (cursor-agent)"* ]]
}

# ---- a key that authenticates but cannot run inference ----
#
# /v1/models (and Gemini's model metadata) answer 200 for any valid key, so a
# key with exhausted billing or no inference entitlement used to read
# Connected. After a passed key check, OpenAI, xAI, Kimi and Gemini get one
# small chat request. What it may and may not conclude:
#   1. 402, or the vendor's own out-of-quota marker, is "Inference blocked".
#   2. A plain 429 is "Rate limited": the key works, just not right now.
#   3. Anything else (a 400 over request shape, a 500, a timeout) proves
#      nothing about billing: the row reads Connected, inference unverified,
#      with the code, so an answer nobody expected shows instead of passing.
#   4. A key that failed its check gets no chat request at all.
# Perplexity's only probe is already a chat request and is unchanged.

@test "check-status: OpenAI insufficient_quota after a passed key check reports inference blocked" {
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    export COUNCIL_FAKE_CHAT_CODE=429
    export COUNCIL_FAKE_CHAT_BODY='{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local plain
    plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
    [[ "$plain" == *"OpenAI        ✗  Inference blocked (HTTP 429)"*"fix: check the account's billing or credits"* ]]
    # Only OpenAI's body carries OpenAI's marker; the other three read it as a
    # plain 429. Perplexity, OpenRouter and the six CLIs stay available.
    [ "$(printf '%s\n' "$plain" | grep -c 'Inference blocked' || true)" -eq 1 ]
    [ "$(printf '%s\n' "$plain" | grep -c 'Rate limited (HTTP 429)' || true)" -eq 3 ]
    [[ "$plain" == *"8/12 providers available"* ]]
}

@test "check-status: OpenAI credit_balance_exhausted reports inference blocked" {
    shadow_curl
    export COUNCIL_FAKE_CHAT_CODE=429
    export COUNCIL_FAKE_CHAT_BODY='{"error":{"message":"Your organization has no prepaid credits remaining.","type":"insufficient_quota","code":"credit_balance_exhausted"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')" == *"OpenAI        ✗  Inference blocked (HTTP 429)"* ]]
}

# The one xAI shape seen in the wild (xAI documents none): a 403, which without
# its marker would read as an unverified answer rather than a rejected key.
@test "check-status: an xAI spending-limit 403 reports inference blocked" {
    shadow_curl
    export COUNCIL_FAKE_CHAT_CODE=403
    export COUNCIL_FAKE_CHAT_BODY='{"code":"personal-team-blocked:spending-limit","error":"You have run out of credits or need a Grok subscription."}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local plain
    plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
    [[ "$plain" == *"Grok          ✗  Inference blocked (HTTP 403)"* ]]
    [ "$(printf '%s\n' "$plain" | grep -c 'Inference blocked' || true)" -eq 1 ]
}

@test "check-status: Kimi exceeded_current_quota_error reports inference blocked" {
    shadow_curl
    export COUNCIL_FAKE_CHAT_CODE=429
    export COUNCIL_FAKE_CHAT_BODY='{"error":{"message":"Your account is suspended, please check your plan and billing details","type":"exceeded_current_quota_error"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local plain
    plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
    [[ "$plain" == *"Kimi          ✗  Inference blocked (HTTP 429)"* ]]
    [ "$(printf '%s\n' "$plain" | grep -c 'Inference blocked' || true)" -eq 1 ]
}

@test "check-status: a 402 from the inference probe reports inference blocked for every probed vendor" {
    shadow_curl
    export COUNCIL_FAKE_CHAT_CODE=402
    export COUNCIL_FAKE_CHAT_BODY='{"error":"Payment Required"}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local plain
    plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
    [ "$(printf '%s\n' "$plain" | grep -c 'Inference blocked (HTTP 402)' || true)" -eq 4 ]
    [[ "$plain" == *"Perplexity    ✓  Connected"* ]]
    [[ "$plain" == *"8/12 providers available"* ]]
}

@test "check-status: an inference answer the probe does not recognise reads Connected, inference unverified" {
    shadow_curl
    export COUNCIL_FAKE_CHAT_CODE=400
    export COUNCIL_FAKE_CHAT_BODY='{"error":{"message":"Unsupported parameter: max_tokens","type":"invalid_request_error","code":"unsupported_parameter"}}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local plain
    plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
    # The key works, so the provider still counts; the row says what is unproven.
    [ "$(printf '%s\n' "$plain" | grep -c 'Connected .*inference unverified (HTTP 400)' || true)" -eq 4 ]
    [[ "$plain" == *"OpenAI        ✓  Connected ("*"ms)"*"· inference unverified (HTTP 400)"* ]]
    [[ "$plain" == *"12/12 providers available"* ]]
    [[ "$plain" != *"Inference blocked"* ]]
}

@test "check-status: a key that fails its check gets no inference probe" {
    record_curl
    export COUNCIL_FAKE_HTTP_CODE=401
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$CS_ARGV_FILE" ]
    run ! grep -qE 'api\.(openai\.com|x\.ai|moonshot\.ai)/v1/chat/completions|:generateContent$' "$CS_ARGV_FILE"
}
