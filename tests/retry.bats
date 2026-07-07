#!/usr/bin/env bats
# ABOUTME: Covers curl_with_retry's failure contract — every failure mode must
# ABOUTME: return 0 with a structured JSON error so set -e callers survive it

load test_helper
bats_require_minimum_version 1.5.0

RETRY_LIB="${LIB_DIR}/retry.sh"

setup() {
    FAKE_DIR="${BATS_TEST_TMPDIR}/fakebin"
    mkdir -p "$FAKE_DIR"
    STEPS_FILE="${BATS_TEST_TMPDIR}/steps"
    COUNT_FILE="${BATS_TEST_TMPDIR}/count"
    RUNNER="${BATS_TEST_TMPDIR}/runner.sh"
    write_fake_curl "$FAKE_DIR/curl"
    write_runner "$RUNNER"
}

# Fake curl driven by a steps file: one "exit<TAB>http<TAB>body" line per
# invocation (last line repeats). Mirrors real curl's contract in
# curl_with_retry: the -w value goes to stdout, the -o file gets the body.
# Static script (quoted heredoc); all inputs arrive via the environment.
write_fake_curl() {
    cat > "$1" <<'CURL'
#!/bin/bash
outfile=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && outfile="$a"
    prev="$a"
done
n=0
[[ -f "$FAKE_COUNT_FILE" ]] && n=$(cat "$FAKE_COUNT_FILE")
line=$(sed -n "$((n + 1))p" "$FAKE_STEPS_FILE")
[[ -z "$line" ]] && line=$(tail -n 1 "$FAKE_STEPS_FILE")
echo $((n + 1)) > "$FAKE_COUNT_FILE"
xexit=$(printf '%s' "$line" | cut -f1)
xhttp=$(printf '%s' "$line" | cut -f2)
xbody=$(printf '%s' "$line" | cut -f3-)
[[ -n "$outfile" ]] && printf '%s' "$xbody" > "$outfile"
printf '%s' "$xhttp"
exit "$xexit"
CURL
    chmod +x "$1"
}

# Reproduces exactly how every provider script calls curl_with_retry: under
# set -euo pipefail, capturing into a variable. If curl_with_retry returns
# non-zero, the command substitution trips errexit and SURVIVED never prints.
write_runner() {
    cat > "$1" <<'RUNNER'
#!/bin/bash
set -euo pipefail
source "$RETRY_LIB"
RESPONSE=$(curl_with_retry -s -X POST "http://example.invalid/api" -d 'x')
printf 'SURVIVED\n'
printf '%s' "$RESPONSE"
RUNNER
    chmod +x "$1"
}

steps() { printf '%b' "$1" > "$STEPS_FILE"; }

run_retry() {
    run --separate-stderr env \
        PATH="${FAKE_DIR}:$PATH" \
        RETRY_LIB="$RETRY_LIB" \
        FAKE_STEPS_FILE="$STEPS_FILE" \
        FAKE_COUNT_FILE="$COUNT_FILE" \
        COUNCIL_RETRY_DELAY=0 \
        COUNCIL_MAX_RETRIES=3 \
        bash "$RUNNER"
}

@test "retry: timeout (curl exit 28) returns JSON error and does not kill a set -e caller" {
    steps '28\t000\t\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    echo "$body" | jq -e . >/dev/null
    local msg; msg=$(echo "$body" | jq -r '.error.message')
    [[ "$msg" == *"timed out"* ]]
}

@test "retry: exhausted network failure (curl exit 6) returns JSON error and survives set -e" {
    steps '6\t000\t\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    echo "$body" | jq -e . >/dev/null
    local msg; msg=$(echo "$body" | jq -r '.error.message // empty')
    [ -n "$msg" ]
    # tried initial + 3 retries = 4 invocations
    [ "$(cat "$COUNT_FILE")" -eq 4 ]
}

@test "retry: retryable 429 then 200 returns the success body and survives" {
    steps '0\t429\t{"first":true}\n0\t200\t{"ok":true}\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    [ "$(echo "$body" | jq -r '.ok')" = "true" ]
    [ "$(cat "$COUNT_FILE")" -eq 2 ]
}

@test "retry: persistent 500 returns the error body for the provider to parse" {
    steps '0\t500\t{"error":{"message":"boom"}}\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    [ "$(echo "$body" | jq -r '.error.message')" = "boom" ]
    # initial + 3 retries, all 500
    [ "$(cat "$COUNT_FILE")" -eq 4 ]
}

@test "retry: non-retryable 400 returns immediately without retrying" {
    steps '0\t400\t{"error":{"message":"bad request"}}\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    [ "$(echo "$body" | jq -r '.error.message')" = "bad request" ]
    [ "$(cat "$COUNT_FILE")" -eq 1 ]
}

@test "retry: successful 200 returns the body verbatim" {
    steps '0\t200\thello world\n'
    run_retry
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    local body; body=${output#*SURVIVED$'\n'}
    [ "$body" = "hello world" ]
    [ "$(cat "$COUNT_FILE")" -eq 1 ]
}
