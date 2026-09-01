#!/usr/bin/env bats
# ABOUTME: Hermetic coverage for the six API provider scripts — response
# ABOUTME: parsing, endpoint routing, error extraction, and secret/payload hygiene

load test_helper
bats_require_minimum_version 1.5.0

PROVIDERS="${SCRIPTS_DIR}/providers"

# setup() clears every provider key before each test, so the gated E2E tests
# below take a copy here, at file scope, where the real environment is still
# visible. Reading the live variables inside a test would skip unconditionally.
E2E_GEMINI_KEY="${GEMINI_API_KEY:-}"
E2E_OPENAI_KEY="${OPENAI_API_KEY:-}"
E2E_GROK_KEY="${XAI_API_KEY:-${GROK_API_KEY:-}}"
E2E_PERPLEXITY_KEY="${PERPLEXITY_API_KEY:-}"
E2E_KIMI_KEY="${KIMI_API_KEY:-${MOONSHOT_API_KEY:-}}"
E2E_OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"

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

# ---- large prompts stay off jq's argv ----

# The orchestrator hands every provider its prompt in a file precisely so a
# large one never rides the process argv (MSYS caps it near 32KB). A provider
# that then passes that prompt to jq with --arg puts it straight back. These
# assert the invariant, not a failure: on a machine with a roomy ARG_MAX the
# call succeeds either way, so only the recorded argv can tell the two apart.
PROMPT_LEAK_MARK="ARGVLEAK_5b3d"

# Write a prompt file far larger than MSYS's limit and echo its path.
big_prompt_file() {
    local f="${BATS_TEST_TMPDIR}/big-prompt"
    { printf '%s ' "$PROMPT_LEAK_MARK"; head -c 40000 /dev/zero | tr '\0' 'z'; } > "$f"
    printf '%s' "$f"
}

# Run a provider the way the orchestrator does — via --prompt-file — with jq
# recording its argv. Usage: run_provider_with_prompt_file <script> [ENV=v ...]
run_provider_with_prompt_file() {
    local script="$1"; shift
    local pfile; pfile=$(big_prompt_file)
    install_recording_jq
    run --separate-stderr env \
        PATH="${JQ_BIN}:${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" \
        FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" \
        FAKE_BODY="$FAKE_BODY" \
        FAKE_HTTP="${FAKE_HTTP:-200}" \
        COUNCIL_RETRY_DELAY=0 \
        "$@" \
        bash "$PROVIDERS/$script" --prompt-file "$pfile"
}

@test "gemini: a large prompt never reaches jq's argv" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"GEM_OK"}]}}]}'
    run_provider_with_prompt_file gemini.sh GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GEM_OK" ]
    # The prompt reached the request body...
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    # ...without ever being an argument to jq.
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

@test "grok: a large prompt never reaches jq's argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"GROK_OK"}}]}'
    run_provider_with_prompt_file grok.sh GROK_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GROK_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

@test "openai: a large prompt never reaches jq's argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"OAI_OK"}}]}'
    run_provider_with_prompt_file openai.sh OPENAI_API_KEY=k OPENAI_MODEL=gpt-4o
    [ "$status" -eq 0 ]
    [ "$output" = "OAI_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

@test "perplexity: a large prompt never reaches jq's argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"PPLX_OK"}}]}'
    run_provider_with_prompt_file perplexity.sh PERPLEXITY_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "PPLX_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

@test "kimi: a large prompt never reaches jq's argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"KIMI_OK"}}]}'
    run_provider_with_prompt_file kimi.sh KIMI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "KIMI_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

@test "ollama: a large prompt never reaches jq's argv" {
    # ollama gates on its binary rather than a key, and OLLAMA_MODEL skips the
    # `ollama list` lookup, so a bare stub on PATH is enough to reach the payload.
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DIR/ollama"
    chmod +x "$FAKE_DIR/ollama"
    FAKE_BODY='{"choices":[{"message":{"content":"OLL_OK"}}]}'
    run_provider_with_prompt_file ollama.sh OLLAMA_MODEL=llama3
    [ "$status" -eq 0 ]
    [ "$output" = "OLL_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
}

# ---- response parsing (characterization) ----

@test "gemini: extracts text from candidates path" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"GEM_OK"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GEM_OK" ]
}

@test "gemini: joins every text part and skips thought parts" {
    # A thinking model can put a thought-signature part before the answer, and
    # split the answer across parts; parts[0].text alone would drop the answer.
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"thought":true,"thoughtSignature":"sig"},{"text":"GEM_"},{"text":"OK"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "GEM_OK" ]
}

@test "gemini: an empty 200 names the finish reason and the thinking spend" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}],"usageMetadata":{"thoughtsTokenCount":8000,"totalTokenCount":8192}}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Error from Gemini: empty response (finishReason: MAX_TOKENS, thoughts tokens: 8000/8192)"* ]]
}

@test "gemini: sends no thinking cap unless GEMINI_THINKING_BUDGET is set" {
    # The model's own thinking policy is the default; a cap is a deliberate
    # user choice, like COUNCIL_MAX_TOKENS.
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    [[ "$(cat "$DATA_FILE")" != *thinkingConfig* ]]
}

@test "gemini: GEMINI_THINKING_BUDGET caps thinking in the request" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k GEMINI_THINKING_BUDGET=4096
    [ "$status" -eq 0 ]
    [ "$(jq -r '.generationConfig.thinkingConfig.thinkingBudget' "$DATA_FILE")" = "4096" ]
}

@test "gemini: a non-numeric GEMINI_THINKING_BUDGET is refused before the request" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k GEMINI_THINKING_BUDGET=lots
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"GEMINI_THINKING_BUDGET"* ]]
    [ ! -s "$DATA_FILE" ]
}

@test "gemini: surfaces .error.message on a failure body" {
    FAKE_BODY='{"error":{"message":"quota exceeded"}}' FAKE_HTTP=429
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Error from Gemini: quota exceeded"* ]]
}

@test "gemini: the default model is the pro alias, and it earns the token bump" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 0 ]
    grep -qF "models/gemini-pro-latest:generateContent" "$ARGV_FILE"
    # The cap is asserted on the same run: the default is a reasoning model, and
    # the pattern that bumps it is the one an id rename silently stops matching.
    [ "$(jq -r '.generationConfig.maxOutputTokens' "$DATA_FILE")" -ge 32768 ]
}

@test "grok: the default model is the grok alias, and it earns the token bump" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider grok.sh "hi" XAI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$(jq -r '.model' "$DATA_FILE")" = "grok-latest" ]
    [ "$(jq -r '.max_tokens' "$DATA_FILE")" -ge 32768 ]
}

@test "grok: an alias other than the default still gets the reasoning token bump" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider grok.sh "hi" XAI_API_KEY=k GROK_MODEL=grok-4-latest
    [ "$status" -eq 0 ]
    # An alias serves a reasoning model, whose thinking shares the cap with the
    # visible answer; the 2048 base would truncate the answer. Pinned to an alias
    # that is not the default, so the bump stays covered when the default moves.
    [ "$(jq -r '.max_tokens' "$DATA_FILE")" -ge 32768 ]
}

@test "gemini: an alias other than the default still gets the reasoning token bump" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}'
    run_provider gemini.sh "hi" GEMINI_API_KEY=k GEMINI_MODEL=gemini-flash-latest
    [ "$status" -eq 0 ]
    [ "$(jq -r '.generationConfig.maxOutputTokens' "$DATA_FILE")" -ge 32768 ]
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

@test "gemini: injects inlineData when given an image" {
    FAKE_BODY='{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"   # "ABC"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 GEMINI_API_KEY=k \
        bash "$PROVIDERS/gemini.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'inlineData' "$DATA_FILE"
    grep -qF 'image/png' "$DATA_FILE"
    grep -qF 'QUJD' "$DATA_FILE"
}

@test "openai: Responses path injects input_image (string image_url)" {
    FAKE_BODY='{"output":[{"type":"message","content":[{"text":"ok"}]}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 OPENAI_API_KEY=k \
        bash "$PROVIDERS/openai.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'input_image' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
}

@test "openai: Chat path injects image_url object" {
    FAKE_BODY='{"choices":[{"message":{"content":"ok"}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 OPENAI_API_KEY=k OPENAI_MODEL=gpt-5.1 \
        bash "$PROVIDERS/openai.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'image_url' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
}

@test "grok: injects image_url object when given an image" {
    FAKE_BODY='{"choices":[{"message":{"content":"ok"}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 XAI_API_KEY=k \
        bash "$PROVIDERS/grok.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'image_url' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
}

@test "perplexity: injects image_url object when given an image" {
    FAKE_BODY='{"choices":[{"message":{"content":"ok"}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 PERPLEXITY_API_KEY=k \
        bash "$PROVIDERS/perplexity.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'image_url' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
}

@test "perplexity: injects image_url object with a recency filter set" {
    FAKE_BODY='{"choices":[{"message":{"content":"ok"}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" FAKE_HTTP=200 \
        COUNCIL_RETRY_DELAY=0 PERPLEXITY_API_KEY=k PERPLEXITY_RECENCY=week \
        bash "$PROVIDERS/perplexity.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'image_url' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
    grep -qF 'search_recency_filter' "$DATA_FILE"
}

@test "provider_vision_capable: true for gemini/openai/grok/perplexity, false for the rest" {
    source "${LIB_DIR}/providers.sh"
    provider_vision_capable gemini
    provider_vision_capable openai
    provider_vision_capable grok
    provider_vision_capable perplexity
    ! provider_vision_capable codex
    ! provider_vision_capable antigravity
}

# ---- model-unavailable signalling: exit 3, not exit 1 ----

@test "grok: a 403 region block exits 3" {
    # Real xAI shape: .error is a bare string, .code sits at the top level.
    FAKE_BODY='{"code":"permission-denied","error":"The model grok-4.5 is not available in your region."}' FAKE_HTTP=403
    run_provider grok.sh "hi" XAI_API_KEY=k
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"not available in your region"* ]]
}

@test "grok: a 401 bad key still exits 1" {
    FAKE_BODY='{"code":"unauthenticated","error":"Incorrect API key provided."}' FAKE_HTTP=401
    run_provider grok.sh "hi" XAI_API_KEY=k
    [ "$status" -eq 1 ]
}

@test "openai: a 404 model_not_found exits 3" {
    FAKE_BODY='{"error":{"message":"The model does not exist or you do not have access to it.","code":"model_not_found"}}' FAKE_HTTP=404
    run_provider openai.sh "hi" OPENAI_API_KEY=k
    [ "$status" -eq 3 ]
}

@test "gemini: a 404 NOT_FOUND exits 3" {
    FAKE_BODY='{"error":{"code":404,"message":"models/x is not found for API version v1beta.","status":"NOT_FOUND"}}' FAKE_HTTP=404
    run_provider gemini.sh "hi" GEMINI_API_KEY=k
    [ "$status" -eq 3 ]
}

@test "perplexity: a 400 invalid model exits 3" {
    FAKE_BODY='{"error":{"message":"Invalid model '\''x'\''.","type":"invalid_model","code":400}}' FAKE_HTTP=400
    run_provider perplexity.sh "hi" PERPLEXITY_API_KEY=k
    [ "$status" -eq 3 ]
}

@test "perplexity: a 500 server error still exits 1" {
    FAKE_BODY='{"error":{"message":"Internal server error."}}' FAKE_HTTP=500
    run_provider perplexity.sh "hi" PERPLEXITY_API_KEY=k COUNCIL_MAX_RETRIES=0
    [ "$status" -eq 1 ]
}

@test "openai: a bare-string .error on a 502 does not crash the extractor" {
    # A gateway/proxy body can carry .error as a bare string rather than an
    # object; .error.message on a string raises a jq error that // cannot
    # catch, and that would abort the script before is_model_unavailable_error runs.
    FAKE_BODY='{"error":"upstream gateway error"}' FAKE_HTTP=502
    run_provider openai.sh "hi" OPENAI_API_KEY=k COUNCIL_MAX_RETRIES=0
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"upstream gateway error"* ]]
}

@test "perplexity: a bare-string .error on a 502 does not crash the extractor" {
    FAKE_BODY='{"error":"upstream gateway error"}' FAKE_HTTP=502
    run_provider perplexity.sh "hi" PERPLEXITY_API_KEY=k COUNCIL_MAX_RETRIES=0
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"upstream gateway error"* ]]
}

# ---- kimi (Moonshot) ----

@test "kimi: extracts content and surfaces errors" {
    FAKE_BODY='{"choices":[{"message":{"content":"KIMI_OK"}}]}'
    run_provider kimi.sh "hi" KIMI_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "KIMI_OK" ]
}

@test "kimi: missing key fails before any request" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider kimi.sh "hi"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"KIMI_API_KEY not set"* ]]
    assert_blank "$(cat "$ARGV_FILE")"
}

@test "kimi: MOONSHOT_API_KEY is accepted as an alias" {
    FAKE_BODY='{"choices":[{"message":{"content":"ALIAS_OK"}}]}'
    run_provider kimi.sh "hi" MOONSHOT_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "ALIAS_OK" ]
}

@test "kimi: routes to the Moonshot chat-completions endpoint" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider kimi.sh "hi" KIMI_API_KEY=k
    [ "$status" -eq 0 ]
    grep -qF "https://api.moonshot.ai/v1/chat/completions" "$ARGV_FILE"
}

@test "kimi: bearer key never appears in the process argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider kimi.sh "hi" KIMI_API_KEY=SEKRET_KIMI
    [ "$status" -eq 0 ]
    ! grep -qF "SEKRET_KIMI" "$ARGV_FILE"
    grep -qF "SEKRET_KIMI" "$CONFIG_FILE"
}

@test "kimi: request payload is sent off-argv via a file" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider kimi.sh "UNIQUE_KIMI_MARKER_77" KIMI_API_KEY=k
    [ "$status" -eq 0 ]
    ! grep -qF "UNIQUE_KIMI_MARKER_77" "$ARGV_FILE"
    grep -qF "UNIQUE_KIMI_MARKER_77" "$DATA_FILE"
}

@test "kimi: an unavailable model exits 3, an ordinary error exits 1" {
    FAKE_BODY='{"error":{"message":"model not found","type":"invalid_request_error"}}'
    FAKE_HTTP=404 run_provider kimi.sh "hi" KIMI_API_KEY=k
    [ "$status" -eq 3 ]

    FAKE_BODY='{"error":{"message":"invalid api key"}}'
    FAKE_HTTP=401 run_provider kimi.sh "hi" KIMI_API_KEY=k
    [ "$status" -eq 1 ]
}

# ---- openrouter ----
#
# OpenRouter is the one seat whose errors can arrive with HTTP 200: the body
# carries {"error":{"code":N}} and no .choices. ensure_error_body stamps
# .http_status only on a wire status >= 400 (retry.sh:51), so on that path
# is_model_unavailable_error is structurally blind — hence this seat classifies
# on .error.code first, falling back to .http_status.

@test "openrouter: a 404 carried inside an HTTP 200 exits 3" {
    FAKE_BODY='{"error":{"code":404,"message":"No endpoints found for anthropic/claude-sonnet-4.6."}}'
    FAKE_HTTP=200 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 3 ]
    assert_not_blank "$stderr"
}

@test "openrouter: a wire 404 exits 3, and 401 does not" {
    FAKE_BODY='{"error":{"message":"No endpoints found for anthropic/claude-sonnet-5."}}'
    FAKE_HTTP=404 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 3 ]

    # The key, not the model, is the fault; the fallback model shares the key.
    FAKE_BODY='{"error":{"code":401,"message":"User not found."}}'
    FAKE_HTTP=401 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 1 ]
}

@test "openrouter: a non-numeric error code does not shadow the wire status" {
    # `//` in jq falls through on null, not on a non-empty string, so a passthrough
    # code like "model_not_found" would hide the 404 that ensure_error_body stamped
    # and cost the run its one durable wrong-slug signal.
    FAKE_BODY='{"error":{"code":"model_not_found","message":"anthropic/nope is not a valid model id"}}'
    FAKE_HTTP=404 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 3 ]
}

@test "openrouter: a 403 moderation block exits 1, not 3" {
    # OpenRouter answers 403 for a prompt its moderation flagged — a property of
    # the input, not the model. is_model_unavailable_error maps a wire 403 to
    # exit 3 (retry.sh:151), which would spend a fallback call re-sending the
    # same flagged prompt.
    FAKE_BODY='{"error":{"code":403,"message":"Input flagged by moderation.","metadata":{"reasons":["harassment"]}}}'
    FAKE_HTTP=403 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"moderation"* ]]
}

@test "openrouter: an exhausted balance exits 1 and names where to top up" {
    # The fallback model draws on the same wallet, so a different model cannot
    # help; the user has to act, which means the message has to say what to do.
    FAKE_BODY='{"error":{"code":402,"message":"Insufficient credits."}}'
    FAKE_HTTP=402 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"openrouter.ai/credits"* ]]
}

@test "openrouter: transient failures exit 1 so no 24h verdict is recorded" {
    local code
    for code in 429 500 502 503 504; do
        FAKE_BODY="{\"error\":{\"code\":${code},\"message\":\"transient\"}}"
        FAKE_HTTP=$code run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k COUNCIL_MAX_RETRIES=0
        [ "$status" -eq 1 ]
    done
}

@test "openrouter: a 200 whose content is null is an error, not an answer" {
    # jq -r on a missing .choices prints the literal "null" and exits 0, so
    # without the // empty guard this body becomes a fabricated council vote.
    FAKE_BODY='{"id":"gen-1","choices":[{"message":{"content":null}}]}'
    FAKE_HTTP=200 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 1 ]
    [[ "$output" != *"null"* ]]
    assert_not_blank "$stderr"
}

@test "openrouter: a bare-string .error does not crash the extractor" {
    FAKE_BODY='{"error":"upstream is down"}'
    FAKE_HTTP=502 run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k COUNCIL_MAX_RETRIES=0
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"upstream is down"* ]]
}

@test "openrouter: missing key fails before any request" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider openrouter.sh "hi"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"OPENROUTER_API_KEY"* ]]
    [ ! -s "$ARGV_FILE" ]
}

@test "openrouter: extracts content and posts the pinned default to the router" {
    FAKE_BODY='{"choices":[{"message":{"content":"OR_OK"}}],"model":"anthropic/claude-sonnet-5"}'
    run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "OR_OK" ]
    grep -qF "https://openrouter.ai/api/v1/chat/completions" "$ARGV_FILE"
    [[ "$(jq -r '.model' "$DATA_FILE")" == "anthropic/claude-sonnet-5" ]]
}

@test "openrouter: sends one model id and never asks the router to switch models" {
    # models[] or route:"fallback" let OpenRouter answer as a different model
    # than the one the council labels, caches and synthesizes under.
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.model | type' "$DATA_FILE")" == "string" ]]
    [[ "$(jq -r 'has("models")' "$DATA_FILE")" == "false" ]]
    [[ "$(jq -r 'has("route")' "$DATA_FILE")" == "false" ]]
}

@test "openrouter: the routed model is logged to stderr only under debug" {
    # run_provider_script merges provider stderr into stdout and stores the whole
    # capture as the answer, so anything written here on the success path is
    # cached and fed to synthesis as if the model had said it.
    FAKE_BODY='{"choices":[{"message":{"content":"OR_OK"}}],"model":"anthropic/claude-sonnet-5-20260115","provider":"Anthropic"}'
    run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k
    [ "$status" -eq 0 ]
    [ "$output" = "OR_OK" ]
    assert_blank "$stderr"

    run_provider openrouter.sh "hi" OPENROUTER_API_KEY=k COUNCIL_DEBUG=1
    [ "$status" -eq 0 ]
    [ "$output" = "OR_OK" ]
    [[ "$stderr" == *"anthropic/claude-sonnet-5-20260115"* ]]
}

@test "openrouter: bearer key never appears in the process argv" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider openrouter.sh "hi" OPENROUTER_API_KEY=SEKRET_ORT
    ! grep -qF "SEKRET_ORT" "$ARGV_FILE"
    grep -qF "SEKRET_ORT" "$CONFIG_FILE"
}

@test "openrouter: injects image_url object when given an image" {
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    local bf="${BATS_TEST_TMPDIR}/b64"; printf 'QUJD' > "$bf"
    run --separate-stderr env PATH="${FAKE_DIR}:$PATH" \
        FAKE_ARGV_FILE="$ARGV_FILE" FAKE_CONFIG_FILE="$CONFIG_FILE" \
        FAKE_DATA_FILE="$DATA_FILE" FAKE_BODY="$FAKE_BODY" OPENROUTER_API_KEY=k \
        bash "$PROVIDERS/openrouter.sh" "hi" --image-file "$bf" --image-mime image/png
    [ "$status" -eq 0 ]
    grep -qF 'image_url' "$DATA_FILE"
    grep -qF 'data:image/png;base64,QUJD' "$DATA_FILE"
}

@test "openrouter: a large prompt never reaches jq's argv, model id intact" {
    # The id carries a slash and a leading tilde, the two shapes MSYS rewrites in
    # argv and env, so the Windows CI leg proves the model reaches the payload
    # unmangled rather than only that the prompt stayed off argv.
    FAKE_BODY='{"choices":[{"message":{"content":"OR_OK"}}]}'
    run_provider_with_prompt_file openrouter.sh OPENROUTER_API_KEY=k \
        'OPENROUTER_MODEL=~anthropic/claude-sonnet-latest'
    [ "$status" -eq 0 ]
    [ "$output" = "OR_OK" ]
    grep -qF "$PROMPT_LEAK_MARK" "$DATA_FILE"
    ! grep -qF "$PROMPT_LEAK_MARK" "$JQ_ARGV_FILE"
    [[ "$(jq -r '.model' "$DATA_FILE")" == '~anthropic/claude-sonnet-latest' ]]
}

@test "provider_vision_capable: openrouter is capable by default, an override opts in" {
    source "${LIB_DIR}/providers.sh"
    provider_vision_capable openrouter
    ! OPENROUTER_MODEL=deepseek/deepseek-v3 provider_vision_capable openrouter
    OPENROUTER_MODEL=deepseek/deepseek-v3 OPENROUTER_VISION=1 provider_vision_capable openrouter
}

@test "kimi: sends the only temperature its models accept" {
    # Every Moonshot model rejects any temperature but 1 with
    # "invalid temperature: only 1 is allowed for this model", so the 0.7 the
    # other providers use makes every kimi query fail against the real API.
    FAKE_BODY='{"choices":[{"message":{"content":"x"}}]}'
    run_provider kimi.sh "hi" KIMI_API_KEY=k
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.temperature' "$DATA_FILE")" == "1" ]]
}

# ============================================================================
# Real-endpoint acceptance (gated — set COUNCIL_E2E=1 to run)
#
# The fake curl above asserts what each provider sends: the endpoint, the key
# off argv, the prompt in a body file. It cannot assert the endpoint accepts
# it. Moonshot rejects every temperature but 1, so kimi shipped a payload that
# could not succeed while every hermetic test passed and `check-status` still
# reported it connected, because that probe is a /models GET rather than a
# completion. These send a real completion through each provider script.
# ============================================================================

e2e_gate() {
    [[ "${COUNCIL_E2E:-}" == "1" ]] || skip "set COUNCIL_E2E=1 to run real API calls"
    [[ -n "${1:-}" ]] || skip "no API key set for this provider"
}

# Runs a provider against the real endpoint with its key restored. PATH is left
# alone so the real curl is used, not the fake one run_provider installs.
run_e2e() {
    local script="$1" keyvar="$2" keyval="$3"
    # Exported rather than passed through `env KEY=value`, which would put the
    # key in argv until the exec. The window is sub-millisecond, but this suite
    # asserts elsewhere that a bearer key never reaches argv at all, and a test
    # that holds the code to a rule it breaks itself is a poor guard.
    export "$keyvar=$keyval"
    run --separate-stderr bash "$PROVIDERS/$script" "Reply with exactly the word: OK"
}

@test "gemini: the live endpoint accepts our payload (E2E)" {
    e2e_gate "$E2E_GEMINI_KEY"
    run_e2e gemini.sh GEMINI_API_KEY "$E2E_GEMINI_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "openai: the live endpoint accepts our payload (E2E)" {
    e2e_gate "$E2E_OPENAI_KEY"
    run_e2e openai.sh OPENAI_API_KEY "$E2E_OPENAI_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "grok: the live endpoint accepts our payload (E2E)" {
    e2e_gate "$E2E_GROK_KEY"
    run_e2e grok.sh XAI_API_KEY "$E2E_GROK_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "perplexity: the live endpoint accepts our payload (E2E)" {
    e2e_gate "$E2E_PERPLEXITY_KEY"
    run_e2e perplexity.sh PERPLEXITY_API_KEY "$E2E_PERPLEXITY_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "kimi: the live endpoint accepts our payload, temperature included (E2E)" {
    e2e_gate "$E2E_KIMI_KEY"
    run_e2e kimi.sh KIMI_API_KEY "$E2E_KIMI_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# The hermetic tests above assert what this seat sends. Only a real call can
# assert the router accepts it — and that the pinned default id still resolves,
# which a catalog listing alone does not prove.
@test "openrouter: the live endpoint accepts our payload (E2E)" {
    e2e_gate "$E2E_OPENROUTER_KEY"
    run_e2e openrouter.sh OPENROUTER_API_KEY "$E2E_OPENROUTER_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
