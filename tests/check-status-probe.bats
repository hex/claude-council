#!/usr/bin/env bats
# ABOUTME: Tests check-status.sh probe mechanics: argv secrecy, temp files, endpoints, timeouts
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

# The probes themselves rather than what they report: what reaches curl's argv,
# what is written to disk, which endpoint is hit and under what bounds. Split
# from check-status.bats because bats parallelises across files, not within one,
# so the suite's wall clock had a floor at that file's total.

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
    # The request is billed, so the probe must sit at the floor, not merely above it
    [ "$max_tokens" -le 32 ]
    # A GET on /chat/completions answers 405, rendering a working key as broken
    grep -qxF -- '-X' "$CS_ARGV_FILE"
    grep -qxF -- 'POST' "$CS_ARGV_FILE"
}

# Without --max-time a black-holed endpoint hangs /status indefinitely.
# /api/v1/models answers 200 with no key at all and with a rejected one, so a
# probe pointed there reports a dead OpenRouter seat as Connected. Only the URL
# on the argv can tell the two endpoints apart.
# A literal tab was used for this once, and a tab stop lands at a different place
# depending on how long the preceding name is — so "Grok" and "Perplexity" pushed
# their status to different columns. Eyeballing catches that only when someone
# happens to have the right mix of providers configured.
@test "check-status: every row's status begins at the same column" {
    shadow_curl
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max"
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Padding is invisible once painted, so measure the plain text.
    local plain offsets rows
    plain=$(printf '%s\n' "$output" | sed $'s/\033\[[0-9;]*m//g')
    rows=$(printf '%s\n' "$plain" | grep -c '^  ●' || true)
    [ "$rows" -ge 10 ]
    offsets=$(printf '%s\n' "$plain" | grep '^  ●' \
        | awk '{ if (match($0, /(Connected|API key not set|CLI not installed|Auth failed|Error \(HTTP|Connection timeout|Installed,)/)) print RSTART }' \
        | sort -u | wc -l)
    [ "$offsets" -eq 1 ]
}

# A roster turns the one router script into several seats. /status has to show
# each of them, or a user reading 11/11 cannot tell that two of their three
# configured models are absent from the council.
@test "check-status: a router roster gets a row per seat, each naming its model" {
    shadow_curl
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max"
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deepseek/deepseek-v3.2"* ]]
    [[ "$output" == *"z-ai/glm-5.3"* ]]
    [[ "$output" == *"qwen/qwen3-max"* ]]
    # The single unnumbered row must be gone, not joined by three more.
    [[ "$output" != *"anthropic/claude-sonnet-5"* ]]
    [[ "$output" == *"13/13 providers available"* ]]
}

# The key is what the probe tests, and every seat shares it, so a roster must not
# multiply the network calls it makes.
@test "check-status: a router roster is probed once, not once per seat" {
    record_curl
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -cxF 'https://openrouter.ai/api/v1/key' "$CS_ARGV_FILE")" -eq 1 ]
}

@test "check-status: the OpenRouter probe authenticates rather than listing models" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$CS_ARGV_FILE" ]
    grep -qxF 'https://openrouter.ai/api/v1/key' "$CS_ARGV_FILE"
    ! grep -q 'openrouter.ai/api/v1/models' "$CS_ARGV_FILE"
}

@test "check-status: every probe is bounded by a request timeout" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$CS_ARGV_FILE" ]
    [ "$(grep -cxF -- '--max-time' "$CS_ARGV_FILE" || true)" -eq 5 ]
}

# rejected_key reads the vendor's key marker with jq. Without a working jq that
# marker is unreadable, and a rejected key looks exactly like an ordinary 400 —
# a wrong answer, not a missing one, from the script whose job is diagnosis.
@test "check-status: an unusable jq is reported rather than silently misdiagnosed" {
    shadow_curl
    printf '#!/bin/bash\nexit 127\n' > "${BATS_TEST_TMPDIR}/fakecurl/jq"
    chmod +x "${BATS_TEST_TMPDIR}/fakecurl/jq"
    export COUNCIL_FAKE_HTTP_CODE=400
    export COUNCIL_FAKE_HTTP_BODY='{"code":"invalid-argument","error":"Incorrect API key provided."}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"jq not found"* ]]
}

# curl can exit having written nothing at all: the binary may be absent, or a
# --config file unreadable, in which case -w never fires and the code is empty.
@test "check-status: curl writing nothing is classified as a failed transfer" {
    local dir="${BATS_TEST_TMPDIR}/silentcurl"
    mkdir -p "$dir"
    printf '#!/bin/bash\nexit 127\n' > "$dir/curl"
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
    export GEMINI_API_KEY=k OPENAI_API_KEY=k XAI_API_KEY=k PERPLEXITY_API_KEY=k
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Connection timeout"* ]]
    [[ "$output" != *"HTTP )"* ]]
}

@test "check-status: probes whose body is never read do not write one to disk" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$CS_ARGV_FILE" ]
    # OpenAI's error body echoes a redacted key and nothing reads it; Perplexity's
    # and OpenRouter's are never read either. Only Gemini and xAI keep a body.
    [ "$(grep -c '^/dev/null$' "$CS_ARGV_FILE" || true)" -eq 3 ]
}

# A probe body and the curl config that carries the key both live in TMPDIR for
# the length of the request. Neither may outlive the run.
@test "check-status: a completed probe leaves no temp file behind" {
    export TMPDIR="${BATS_TEST_TMPDIR}/tmpdir"
    mkdir -p "$TMPDIR"
    shadow_curl
    export COUNCIL_FAKE_HTTP_CODE=200
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "check-status: a keyless provider never creates a temp file at all" {
    export TMPDIR="${BATS_TEST_TMPDIR}/tmpdir"
    mkdir -p "$TMPDIR"
    # setup() unsets every provider key, so each probe must return before mktemp
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "check-status: probe API keys never appear on the curl argv" {
    record_curl
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Guard against a vacuous pass: curl must have actually run and recorded argv.
    [ -s "$CS_ARGV_FILE" ]
    # None of the five keys may reach the process table (ps-visible for the 10s probe).
    ! grep -qF "SEKRET_GEM" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_OAI" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_GROK" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_PPX" "$CS_ARGV_FILE"
    ! grep -qF "SEKRET_ORT" "$CS_ARGV_FILE"
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
