#!/usr/bin/env bats
# ABOUTME: Tests for scripts/query-council.sh
# ABOUTME: Validates argument parsing, error handling, and JSON output structure

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${SCRIPTS_DIR}/query-council.sh"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    export COUNCIL_CACHE_DIR="$TEST_CACHE_DIR"
    # Unset all provider keys to test error cases. XAI_API_KEY also has to go,
    # since keys.sh's resolve_grok_key copies it to GROK_API_KEY automatically.
    unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY XAI_API_KEY PERPLEXITY_API_KEY
    # Hide codex/gemini binaries so binary-gated discovery doesn't make real CLI
    # calls during arg-parsing tests. The cli-providers.bats file does the
    # opposite — it keeps them on PATH on purpose.
    export PATH=$(path_without_clis)

    # Hermetic provider dir: --providers=<name> runs these stubs with no network
    # and no API key (query-council splits --providers straight into its list).
    STUB_DIR="${BATS_TEST_TMPDIR}/providers"
    CALLS_LOG="${BATS_TEST_TMPDIR}/calls.log"
    mkdir -p "$STUB_DIR"
    : > "$CALLS_LOG"
}

# Install a stub provider that echoes a canned answer and, as a side effect,
# appends its name to CALLS_LOG (one line per invocation) and records the exact
# prompt and verbosity it received. Lets tests assert real behavior offline.
# Usage: write_stub <name> [answer]
write_stub() {
    local name="$1" answer="${2:-ANSWER-FROM-${1}}"
    cat > "$STUB_DIR/${name}.sh" <<EOF
#!/bin/bash
prompt="\${1:-}"
[[ "\$prompt" == "--prompt-file" ]] && prompt="\$(cat "\$2")"
echo "${name}" >> "${CALLS_LOG}"
printf '%s' "\$prompt" > "${STUB_DIR}/${name}.last_prompt"
printf '%s' "\${COUNCIL_VERBOSITY:-}" > "${STUB_DIR}/${name}.verbosity"
printf '%s\n' "${answer}"
EOF
    chmod +x "$STUB_DIR/${name}.sh"
}

# Run query-council hermetically: no pane, no auto-context, stub providers.
run_council() {
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" \
        bash "$SCRIPT" --no-pane --no-auto-context "$@"
}

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "query-council: shows usage with --help" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: shows usage with -h" {
    run bash "$SCRIPT" -h
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: errors on unknown flag" {
    run bash "$SCRIPT" --unknown-flag "test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "query-council: errors on empty prompt" {
    run bash "$SCRIPT" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"No prompt"* ]] || [[ "$output" == *"Usage"* ]]
}

# ============================================================================
# Provider discovery tests
# ============================================================================

@test "query-council: --list-available reports the exact no-providers message" {
    run bash "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    [[ "$output" == *"No providers configured."* ]]
}

@test "query-council: querying with no providers exits nonzero with guidance" {
    run bash "$SCRIPT" "test prompt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No providers configured."* ]]
    # Points at the local fallback so the user has a next step
    [[ "$output" == *"--local"* ]]
}

# ============================================================================
# Role validation tests
# ============================================================================

@test "query-council: an invalid role exits nonzero and names the problem" {
    write_stub gemini
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" \
        bash "$SCRIPT" --no-pane --no-auto-context --providers=gemini \
        --roles=invalidrole "test prompt"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"Unknown role"* ]]
}

# ============================================================================
# File context tests
# ============================================================================

@test "query-council: errors on missing file" {
    write_stub gemini
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" \
        bash "$SCRIPT" --no-pane --providers=gemini \
        --file=/nonexistent/path "test prompt"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"not found"* ]] || [[ "$stderr" == *"No such file"* ]]
}

# ============================================================================
# Output structure and provider execution (hermetic, via stub providers)
# ============================================================================

@test "query-council: a stub provider produces a success slot in round1" {
    write_stub gemini "hello from the stub"
    run_council --providers=gemini "test"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.metadata' >/dev/null
    echo "$output" | jq -e '.round1' >/dev/null
    [[ "$(echo "$output" | jq -r '.round1.gemini.status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.round1.gemini.response')" == "hello from the stub" ]]
}

@test "query-council: accepts the prompt via --prompt=" {
    write_stub gemini
    run_council --providers=gemini --prompt="from the prompt flag"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.metadata.prompt')" == "from the prompt flag" ]]
}

@test "query-council: --providers queries exactly the named providers" {
    write_stub gemini
    write_stub openai
    run_council --providers=gemini,openai "test"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.round1.gemini' >/dev/null
    echo "$output" | jq -e '.round1.openai' >/dev/null
    # Each named provider was invoked once
    [ "$(grep -c . "$CALLS_LOG")" -eq 2 ]
}

@test "query-council: --quiet sets quiet_mode in metadata" {
    write_stub gemini
    run_council --providers=gemini --quiet "test"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.metadata.quiet_mode')" == "true" ]]
}

@test "query-council: -q short flag also sets quiet_mode" {
    write_stub gemini
    run_council --providers=gemini -q "test"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.metadata.quiet_mode')" == "true" ]]
}

@test "query-council: --verbosity is validated and exported to the provider" {
    write_stub gemini
    run_council --providers=gemini --verbosity=brief "test"
    [ "$status" -eq 0 ]
    [[ "$(cat "${STUB_DIR}/gemini.verbosity")" == "brief" ]]
}

@test "query-council: an unknown verbosity is rejected" {
    write_stub gemini
    run_council --providers=gemini --verbosity=louder "test"
    [ "$status" -ne 0 ]
}

# ============================================================================
# Cache behavior
# ============================================================================

@test "query-council: a warm cache serves round1 without re-invoking the provider" {
    write_stub gemini
    run_council --providers=gemini "same question"
    [ "$status" -eq 0 ]
    run_council --providers=gemini "same question"
    [ "$status" -eq 0 ]
    # Second run was a cache hit
    [[ "$(echo "$output" | jq -r '.round1.gemini.cached')" == "true" ]]
    # Provider invoked exactly once across both runs
    [ "$(grep -c . "$CALLS_LOG")" -eq 1 ]
}

@test "query-council: --no-cache forces a fresh provider invocation each run" {
    write_stub gemini
    run_council --providers=gemini --no-cache "same question"
    [ "$status" -eq 0 ]
    run_council --providers=gemini --no-cache "same question"
    [ "$status" -eq 0 ]
    # Provider invoked on both runs
    [ "$(grep -c . "$CALLS_LOG")" -eq 2 ]
}

# ============================================================================
# Debate mode (round 2)
# ============================================================================

@test "query-council: --debate produces a round2 block" {
    write_stub gemini
    run_council --providers=gemini --debate "test"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.round2' >/dev/null
    [[ "$(echo "$output" | jq -r '.metadata.debate_mode')" == "true" ]]
    [[ "$(echo "$output" | jq -r '.round2.gemini.status')" == "success" ]]
}

@test "query-council: the round2 prompt carries the original question and a per-provider self-label" {
    write_stub gemini
    run_council --providers=gemini --debate "what is the original question here"
    [ "$status" -eq 0 ]
    # The stub's last_prompt is round 2's prompt (stateless calls have no round-1
    # memory), so it must restate the question and tell gemini which answer is its own
    local r2
    r2=$(cat "${STUB_DIR}/gemini.last_prompt")
    [[ "$r2" == *"The original question was:"* ]]
    [[ "$r2" == *"what is the original question here"* ]]
    [[ "$r2" == *"You are GEMINI."* ]]
    [[ "$r2" == *"[GEMINI'S RESPONSE]"* ]]
}

# ============================================================================
# run_provider_with_model_fallback
# ============================================================================

# A fake provider that exits 3 for the preferred model and 0 for the fallback,
# reading the model from the same env var the real scripts read.
write_model_aware_stub() {
    local name="$1" preferred="$2"
    cat > "$STUB_DIR/${name}.sh" <<EOF
#!/bin/bash
model="\${$(echo "$name" | tr '[:lower:]' '[:upper:]')_MODEL:-${preferred}}"
echo "\$model" >> "${CALLS_LOG}"
if [[ "\$model" == "${preferred}" ]]; then
    echo "Error from ${name}: model unavailable" >&2
    exit 3
fi
printf 'ANSWER-FROM-%s\n' "\$model"
EOF
    chmod +x "$STUB_DIR/${name}.sh"
}

# The wrapper is exercised through the real query-council.sh rather than sourced
# in isolation: it depends on TEMP_DIR, PROVIDERS_DIR and the pane globals that
# the script sets up, and driving the script proves the whole path.

@test "wrapper: exit 3 on the preferred model retries with the fallback" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-4.5
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.model' 'grok-4.20-reasoning'
    assert_json_eq "$output" '.round1.grok.model_fallback' 'grok-4.5'
    [[ "$stderr" == *"grok-4.5 unavailable"* ]]
}

@test "wrapper: the preferred model is tried first, then the fallback" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-4.5
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$CALLS_LOG")" = "grok-4.5" ]
    [ "$(sed -n 2p "$CALLS_LOG")" = "grok-4.20-reasoning" ]
}

@test "wrapper: a cached verdict skips the known-bad preferred model" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-4.5
    # First run discovers and remembers the verdict.
    env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1
    : > "$CALLS_LOG"
    # Second run must go straight to the fallback: exactly one invocation.
    env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1
    [ "$(grep -c . "$CALLS_LOG")" -eq 1 ]
    [ "$(sed -n 1p "$CALLS_LOG")" = "grok-4.20-reasoning" ]
}

@test "wrapper: an explicit GROK_MODEL override never falls back" {
    export GROK_API_KEY=k GROK_MODEL=grok-4.5
    write_model_aware_stub grok grok-4.5
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
    # The stub exits 3; with an override there is no fallback, so it is an error.
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ "$(grep -c . "$CALLS_LOG")" -eq 1 ]
}

@test "wrapper: when the fallback also fails, no verdict is remembered" {
    export GROK_API_KEY=k
    # Both models fail: an account-level block, not a model-level one.
    cat > "$STUB_DIR/grok.sh" <<'EOF'
#!/bin/bash
echo "Error from grok: model unavailable" >&2
exit 3
EOF
    chmod +x "$STUB_DIR/grok.sh"
    env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1 || true
    # A poisoned verdict would silently downgrade grok for a day.
    [ ! -d "${TEST_CACHE_DIR}/model-verdicts" ] || [ -z "$(ls -A "${TEST_CACHE_DIR}/model-verdicts")" ]
}
