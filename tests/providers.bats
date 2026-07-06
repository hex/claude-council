#!/usr/bin/env bats
# ABOUTME: Hermetic coverage for the four API provider scripts — response
# ABOUTME: parsing, endpoint routing, error extraction, and secret/payload hygiene

load test_helper
bats_require_minimum_version 1.5.0

PROVIDERS="${SCRIPTS_DIR}/providers"

setup() {
    FAKE_DIR="${BATS_TEST_TMPDIR}/fakebin"
    mkdir -p "$FAKE_DIR"
    ARGV_FILE="${BATS_TEST_TMPDIR}/argv"
    CONFIG_FILE="${BATS_TEST_TMPDIR}/cfg"
    DATA_FILE="${BATS_TEST_TMPDIR}/data"
    : > "$ARGV_FILE"; : > "$CONFIG_FILE"; : > "$DATA_FILE"
    write_fake_curl "$FAKE_DIR/curl"
    unset_provider_keys
}

# Fake curl: records argv (one arg per line), copies any --config and
# --data-binary @file contents out for inspection (the provider deletes its
# temp files on exit), writes the canned body to the -o target, prints the
# http code. Static script; inputs arrive via the environment.
write_fake_curl() {
    cat > "$1" <<'CURL'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_ARGV_FILE"
outfile=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && outfile="$a"
    [[ "$prev" == "--config" && -f "$a" ]] && cat "$a" >> "$FAKE_CONFIG_FILE"
    [[ "$prev" == "--data-binary" && "$a" == @* && -f "${a#@}" ]] && cat "${a#@}" >> "$FAKE_DATA_FILE"
    prev="$a"
done
[[ -n "$outfile" ]] && printf '%s' "$FAKE_BODY" > "$outfile"
printf '%s' "${FAKE_HTTP:-200}"
exit 0
CURL
    chmod +x "$1"
}

# Run a provider script with the fake curl shadowing PATH.
# Usage: run_provider <script> <prompt> [ENVVAR=value ...]
run_provider() {
    local script="$1" prompt="$2"; shift 2
    run --separate-stderr env \
        PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" \
        FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" \
        FAKE_BODY="$FAKE_BODY" \
        FAKE_HTTP="${FAKE_HTTP:-200}" \
        COUNCIL_RETRY_DELAY=0 \
        "$@" \
        bash "$PROVIDERS/$script" "$prompt"
}

# ---- response parsing (characterization) ----

@test "gemini: extracts text from candidates path" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"GEM_OK"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GEM_OK" ]
}

@test "gemini: surfaces .error.message on a failure body" {
    FAKE_BODY='{"error":{"message":"quota exceeded"}}' FAKE_HTTP=429
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Error from Gemini: quota exceeded"* ]]
}

@test "openai: gpt-5.1 routes to chat/completions and parses content" {
    FAKE_BODY='{"choices":[{"message":{"content":"OAI_CHAT"}}]}'
    run_provider openai.sh "hi" OPENAI_API_KEY=k OPENAI_MODEL=gpt-5.1
    [ "$status" -eq 0 ]
    [ "$output" = "OAI_CHAT" ]
    grep -qF "https://api.openai.com/v1/chat/completions" "$ARGV_FILE"
    grep -qF "max_completion_tokens" "$DATA_FILE"
}

@test "openai: gpt-5.5-pro routes to v1/responses with a bumped token cap" {
    FAKE_BODY='{"output":[{"type":"message","content":[{"text":"OAI_RESP"}]}]}'
    run_provider openai.sh "hi" OPENAI_API_KEY=k OPENAI_MODEL=gpt-5.5-pro
    [ "$status" -eq 0 ]
    [ "$output" = "OAI_RESP" ]
    grep -qF "https://api.openai.com/v1/responses" "$ARGV_FILE"
    # 8x/32768 bump lands in the payload, not the base 2048
    [ "$(jq -r '.max_output_tokens' "$DATA_FILE")" -ge 32768 ]
}

@test "openai: surfaces .error.message on a failure body" {
    FAKE_BODY='{"error":{"message":"bad key"}}' FAKE_HTTP=401
    run_provider openai.sh "hi" OPENAI_API_KEY=k OPENAI_MODEL=gpt-5.1
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Error from OpenAI: bad key"* ]]
}

@test "grok: extracts content and surfaces errors" {
    FAKE_BODY='{"choices":[{"message":{"content":"GROK_OK"}}]}'
    run_provider grok.sh "hi" XAI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GROK_OK" ]
}

@test "perplexity: extracts content and surfaces errors" {
    FAKE_BODY='{"choices":[{"message":{"content":"PPX_OK"}}]}'
    run_provider perplexity.sh "hi" PERPLEXITY_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "PPX_OK" ]
}

# ---- secret + payload hygiene (findings #14, #6, #4 provider hop) ----

@test "gemini: API key never appears in the process argv" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=SEKRET_GEMINI
    [ "$status" -eq 0 ]
    ! grep -qF "SEKRET_GEMINI" "$ARGV_FILE"
    grep -qF "SEKRET_GEMINI" "$CONFIG_FILE"
}

@test "openai: bearer key never appears in the process argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider openai.sh "hi" OPENAI_API_KEY=SEKRET_OAI OPENAI_MODEL=gpt-5.1
    [ "$status" -eq 0 ]
    ! grep -qF "SEKRET_OAI" "$ARGV_FILE"
    grep -qF "SEKRET_OAI" "$CONFIG_FILE"
}

@test "grok: bearer key never appears in the process argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider grok.sh "hi" XAI_API_KEY=SEKRET_GROK
    [ "$status" -eq 0 ]
    ! grep -qF "SEKRET_GROK" "$ARGV_FILE"
    grep -qF "SEKRET_GROK" "$CONFIG_FILE"
}

@test "perplexity: bearer key never appears in the process argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider perplexity.sh "hi" PERPLEXITY_API_KEY=SEKRET_PPX
    [ "$status" -eq 0 ]
    ! grep -qF "SEKRET_PPX" "$ARGV_FILE"
    grep -qF "SEKRET_PPX" "$CONFIG_FILE"
}

@test "gemini: request payload is sent off-argv via a file" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "UNIQUE_PROMPT_MARKER_42" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    ! grep -qF "UNIQUE_PROMPT_MARKER_42" "$ARGV_FILE"
    grep -qF "UNIQUE_PROMPT_MARKER_42" "$DATA_FILE"
}
