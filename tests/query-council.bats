#!/usr/bin/env bats
# ABOUTME: Tests for scripts/query-council.sh
# ABOUTME: Validates argument parsing, error handling, and JSON output structure

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${SCRIPTS_DIR}/query-council.sh"
# provider_env_prefix, used when generating model-aware stubs.
source "${LIB_DIR}/providers.sh"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    export COUNCIL_CACHE_DIR="$TEST_CACHE_DIR"
    # Unset all provider keys to test error cases. Call the shared helper rather
    # than repeating the list: a second copy silently goes stale the next time a
    # provider is added, and the no-providers tests below then see a populated
    # council on any machine that exports the new key.
    unset_provider_keys
    # Hide codex/gemini binaries so binary-gated discovery doesn't make real CLI
    # calls during arg-parsing tests. The cli-providers.bats file does the
    # opposite — it keeps them on PATH on purpose. The stripped PATH can demote
    # bare `bash` to /bin/bash 3.2, so the SUT always runs via "$HOST_BASH"
    # (resolved in test_helper.bash before the strip).
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
        "$HOST_BASH" "$SCRIPT" --no-pane --no-auto-context "$@"
}

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "query-council: shows usage with --help" {
    run "$HOST_BASH" "$SCRIPT" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: shows usage with -h" {
    run "$HOST_BASH" "$SCRIPT" -h
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "query-council: errors on unknown flag" {
    run "$HOST_BASH" "$SCRIPT" --unknown-flag "test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "query-council: errors on empty prompt" {
    run "$HOST_BASH" "$SCRIPT" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"No prompt"* ]] || [[ "$output" == *"Usage"* ]]
}

# ============================================================================
# Provider discovery tests
# ============================================================================

@test "query-council: --list-available reports the exact no-providers message" {
    run "$HOST_BASH" "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    [[ "$output" == *"No providers configured."* ]]
}

@test "query-council: querying with no providers exits nonzero with guidance" {
    run "$HOST_BASH" "$SCRIPT" "test prompt"
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
        "$HOST_BASH" "$SCRIPT" --no-pane --no-auto-context --providers=gemini \
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
        "$HOST_BASH" "$SCRIPT" --no-pane --providers=gemini \
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

@test "query-council: a hyphenated provider name produces a success slot in round1" {
    # grok-cli's hyphen must not break the MODEL override-var derivation
    # (GROK-CLI_MODEL is an invalid bash name; expanding it kills the worker).
    write_stub grok-cli "hello from the hyphenated stub"
    run_council --providers=grok-cli "test"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"invalid variable name"* ]]
    [[ "$(echo "$output" | jq -r '.round1."grok-cli".status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.round1."grok-cli".response')" == "hello from the hyphenated stub" ]]
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
# reading the model from the same env var the real scripts read — derived with
# the same provider_env_prefix the real scripts use, so hyphenated names work.
write_model_aware_stub() {
    local name="$1" preferred="$2"
    cat > "$STUB_DIR/${name}.sh" <<EOF
#!/bin/bash
model="\${$(provider_env_prefix "$name")_MODEL:-${preferred}}"
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
    write_model_aware_stub grok grok-latest
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.model' 'grok-4.6'
    assert_json_eq "$output" '.round1.grok.model_fallback' 'grok-latest'
    [[ "$stderr" == *"grok-latest unavailable"* ]]
}

@test "wrapper: the preferred model is tried first, then the fallback" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-latest
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$CALLS_LOG")" = "grok-latest" ]
    [ "$(sed -n 2p "$CALLS_LOG")" = "grok-4.6" ]
}

@test "wrapper: a cached verdict skips the known-bad preferred model" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-latest
    # First run discovers and remembers the verdict.
    env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1
    : > "$CALLS_LOG"
    # Second run must go straight to the fallback: exactly one invocation.
    env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1
    [ "$(grep -c . "$CALLS_LOG")" -eq 1 ]
    [ "$(sed -n 1p "$CALLS_LOG")" = "grok-4.6" ]
}

@test "wrapper: an explicit GROK_MODEL override never falls back" {
    export GROK_API_KEY=k GROK_MODEL=grok-latest
    write_model_aware_stub grok grok-latest
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q"
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
        "$HOST_BASH" "$SCRIPT" --providers=grok --no-pane --no-auto-context --no-cache "q" >/dev/null 2>&1 || true
    # A poisoned verdict would silently downgrade grok for a day.
    [ ! -d "${TEST_CACHE_DIR}/model-verdicts" ] || [ -z "$(ls -A "${TEST_CACHE_DIR}/model-verdicts")" ]
}

@test "round2: the rebuttal slot carries the fallback model and the displaced one" {
    export GROK_API_KEY=k
    write_model_aware_stub grok grok-latest
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=grok --debate --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round2.grok.model' 'grok-4.6'
    assert_json_eq "$output" '.round2.grok.model_fallback' 'grok-latest'
}

@test "sibling: a CLI provider's API sibling reports its own model fallback" {
    # codex is unusable; its sibling openai answers, and openai's preferred model
    # is itself unavailable, so the slot must name both fallbacks.
    export OPENAI_API_KEY=k
    write_model_aware_stub openai gpt-6-astra
    cat > "$STUB_DIR/codex.sh" <<'EOF'
#!/bin/bash
echo "codex is broken" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/codex.sh"
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        "$HOST_BASH" "$SCRIPT" --providers=codex --no-pane --no-auto-context --no-cache "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.codex.fallback' 'openai'
    assert_json_eq "$output" '.round1.codex.model' 'gpt-6.1-sol'
    assert_json_eq "$output" '.round1.codex.model_fallback' 'gpt-6-astra'
}

# ============================================================================
# Retry offer: the producer re-queries failed providers when the pane asks
# ============================================================================

# A stub that fails its first call and answers on the second, so a retry has
# something to recover. Records calls in CALLS_LOG like write_stub.
write_flaky_stub() {
    local name="$1"
    cat > "$STUB_DIR/${name}.sh" <<EOF
#!/bin/bash
prompt="\${1:-}"
[[ "\$prompt" == "--prompt-file" ]] && prompt="\$(cat "\$2")"
echo "${name}" >> "${CALLS_LOG}"
printf '%s' "\$prompt" > "${STUB_DIR}/${name}.last_prompt"
if [[ ! -f "${STUB_DIR}/${name}.failed-once" ]]; then
    touch "${STUB_DIR}/${name}.failed-once"
    echo "Error from ${name}: transient failure" >&2
    exit 1
fi
printf '%s\n' "ANSWER-FROM-${name}"
EOF
    chmod +x "$STUB_DIR/${name}.sh"
}

# Stand in for the pane watcher: wait for the retry offer, keep a copy of it,
# then answer with $1 — "retry" accepts the way the watcher does (renaming the
# offer to .retry), "close" removes the watch dir the way the watcher's exit
# trap does. A run that ends without offering releases the wait too.
play_pane() {
    local answer="$1"
    await_any_file "$PANE/retry-offer" "$PANE/run-over" || return 0
    [[ -f "$PANE/retry-offer" ]] || return 0
    cp "$PANE/retry-offer" "$PANE/offer-seen"
    case "$answer" in
        retry) mv "$PANE/retry-offer" "$PANE/.retry" ;;
        close) rm -rf "$PANE" ;;
    esac
}

# Run with a pre-created watch dir standing in for an open pane (bats has no
# tmux), so the retry protocol can be driven through the dir's files. The
# run-over marker lets a waiting play_pane stop once the run has ended.
run_council_with_pane() {
    COUNCIL_PANE_DIR="$PANE" run_council --no-cache "$@"
    touch "$PANE/run-over" 2>/dev/null || true
}

setup_pane() {
    PANE="${BATS_TEST_TMPDIR}/pane"
    # The responses/ subdir is what display_pane_open creates; it is how the
    # producer tells a watch dir from any other directory the variable names.
    mkdir -p "$PANE/responses"
}

@test "retry: re-queries only the failed providers when the pane presses r" {
    setup_pane
    write_stub gemini
    write_flaky_stub grok
    play_pane retry &
    COUNCIL_RETRY_WAIT=5 run_council_with_pane --providers=gemini,grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'success'
    assert_json_eq "$output" '.round1.grok.response' 'ANSWER-FROM-grok'
    assert_json_eq "$output" '.round1.gemini.status' 'success'
    [ "$(grep -c '^gemini$' "$CALLS_LOG")" -eq 1 ]
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 2 ]
    # The retry sends the query the provider failed, not a variant of it.
    cmp -s "$STUB_DIR/grok.last_prompt" "$STUB_DIR/gemini.last_prompt"
    # The offer names the wait in seconds, then only the providers that failed.
    [ "$(cat "$PANE/offer-seen")" = $'5\ngrok' ]
    # Both signal files are consumed, so a later run cannot mistake them.
    [ ! -f "$PANE/retry-offer" ]
    [ ! -f "$PANE/.retry" ]
    # The pane saw grok query, fail, query again and complete.
    [ "$(pane_states grok)" = "querying,error,querying,complete" ]
    # A provider that answered on retry is no longer an error.
    [[ "$stderr" != *"Errors:"* ]]
}

@test "retry: an unanswered offer expires and the run reports the error" {
    setup_pane
    write_flaky_stub grok
    play_pane ignore &
    COUNCIL_RETRY_WAIT=1 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
    [ -f "$PANE/offer-seen" ]
    [ ! -f "$PANE/retry-offer" ]
    [[ "$stderr" == *"Errors:"* ]]
}

@test "retry: closing the pane at the offer lets the run finish without a retry" {
    setup_pane
    write_flaky_stub grok
    play_pane close &
    COUNCIL_RETRY_WAIT=5 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
    [ ! -d "$PANE" ]
}

@test "retry: COUNCIL_RETRY_WAIT=0 never offers" {
    setup_pane
    write_flaky_stub grok
    play_pane retry &
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ ! -f "$PANE/offer-seen" ]
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
}

@test "retry: no offer is written without a pane" {
    write_flaky_stub grok
    COUNCIL_RETRY_WAIT=5 run_council --no-cache --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
}

# A stub that answers after <seconds>, through a child sleep whose pid it
# records, so a test can tell whether a cancel ended the whole tree. The
# first <fast_calls> calls answer at once instead, for a seat whose slow call
# is its debate one. Usage: write_slow_stub <name> <seconds> [fast_calls]
write_slow_stub() {
    local name="$1" seconds="$2" fast_calls="${3:-0}"
    cat > "$STUB_DIR/${name}.sh" <<EOF
#!/bin/bash
echo "${name}" >> "${CALLS_LOG}"
if [[ "\$(grep -c '^${name}\$' "${CALLS_LOG}")" -gt ${fast_calls} ]]; then
    sleep ${seconds} &
    echo \$! > "${STUB_DIR}/${name}.sleeper"
    wait \$!
fi
printf 'ANSWER-FROM-%s\\n' "${name}"
EOF
    chmod +x "$STUB_DIR/${name}.sh"
}

# Stand in for the mod pane cancelling a seat: once its slow call is running
# (the stub records its sleeper), drop the marker the pane writes.
cancel_from_pane() {
    local name="$1"
    await_any_file "$STUB_DIR/${name}.sleeper" "$PANE/run-over" || return 1
    mkdir -p "$PANE/cancel"
    touch "$PANE/cancel/${name}"
}

# The states the pane saw for one provider, in order, comma-separated.
pane_states() {
    awk -F'\t' -v p="$1" '$1 == p { print $2 }' "$PANE/status" | paste -sd, -
}

@test "cancel: a marker from the pane ends that seat and the run goes on without it" {
    setup_pane
    write_stub gemini
    write_slow_stub grok 30
    cancel_from_pane grok &
    local started; started=$SECONDS
    COUNCIL_RETRY_WAIT=5 run_council_with_pane --providers=gemini,grok "q"
    [ "$status" -eq 0 ]
    # The run did not wait out the sleeper.
    [ $(( SECONDS - started )) -lt 20 ]
    assert_json_eq "$output" '.round1.gemini.status' 'success'
    assert_json_eq "$output" '.round1.grok.status' 'error'
    assert_json_eq "$output" '.round1.grok.error' 'cancelled from the pane'
    # The pane saw the seat query and then be cancelled, never errored, and
    # the status line is the whole story: no error file.
    [ "$(pane_states grok)" = "querying,cancelled" ]
    [ ! -f "$PANE/errors/grok.txt" ]
    # A cancelled seat is not offered for retry, and the marker is consumed.
    [ ! -f "$PANE/offer-seen" ]
    [ ! -f "$PANE/cancel/grok" ]
    # The stub's own child went with it.
    run ! kill -0 "$(cat "$STUB_DIR/grok.sleeper")"
}

@test "cancel: a marker that lands after the seat answered keeps the answer" {
    setup_pane
    # The stub answers at once; query_provider then streams the answer to the
    # pane and the cache, a window in which the job is still alive.
    write_stub grok
    # Pressed the moment the answer file exists, before the job is reaped.
    (
        await_any_file "$PANE/responses/grok.md" "$PANE/run-over"
        mkdir -p "$PANE/cancel"; touch "$PANE/cancel/grok"
    ) &
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'success'
    assert_json_eq "$output" '.round1.grok.response' 'ANSWER-FROM-grok'
    [[ "$(pane_states grok)" != *cancelled* ]]
    # The marker is consumed only while the run is still waiting on seats; one
    # that lands after that stays, and goes with the watch dir.
}

@test "cancel: a marker older than the round is spent, not honoured" {
    # A press that lands after round 1 has collected (the row still read
    # querying for the pane's last half-second) must not cancel the seat's
    # rebuttal in round 2 and overwrite its complete row.
    setup_pane
    write_stub gemini
    write_stub grok
    mkdir -p "$PANE/cancel"; touch "$PANE/cancel/grok"
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=gemini,grok --debate "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'success'
    assert_json_eq "$output" '.round2.grok.status' 'success'
    [[ "$(pane_states grok)" != *cancelled* ]]
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 2 ]
    [ ! -f "$PANE/cancel/grok" ]
}

@test "cancel: a tree that ignores the signal is killed, and the run does not wait on it" {
    setup_pane
    write_stub gemini
    # The stub and its child both shrug off SIGTERM, as a CLI that traps it
    # for a graceful exit does.
    cat > "$STUB_DIR/grok.sh" <<EOF
#!/bin/bash
trap '' TERM
echo grok >> "${CALLS_LOG}"
bash -c 'trap "" TERM; sleep 60' &
echo \$! > "${STUB_DIR}/grok.sleeper"
wait \$!
echo ANSWER-FROM-grok
EOF
    chmod +x "$STUB_DIR/grok.sh"
    cancel_from_pane grok &
    local started; started=$SECONDS
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=gemini,grok "q"
    [ "$status" -eq 0 ]
    # Ended by the kill that follows the grace period, well inside the sleep.
    [ $(( SECONDS - started )) -lt 30 ]
    assert_json_eq "$output" '.round1.grok.error' 'cancelled from the pane'
    run ! kill -0 "$(cat "$STUB_DIR/grok.sleeper")"
}

@test "cancel: a cancelled seat's slot keeps its role" {
    setup_pane
    write_stub gemini
    write_slow_stub grok 30
    cancel_from_pane grok &
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=gemini,grok --roles=security,performance "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.gemini.role' 'security'
    assert_json_eq "$output" '.round1.grok.role' 'performance'
    assert_json_eq "$output" '.round1.grok.error' 'cancelled from the pane'
}

@test "cancel: without a pane the run touches no cancel path" {
    # With COUNCIL_PANE_DIR empty the marker path must not resolve to the
    # filesystem root and be removed from there.
    local spy="${BATS_TEST_TMPDIR}/spy"
    mkdir -p "$spy"
    cat > "$spy/rm" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "${BATS_TEST_TMPDIR}/rm-argv"
exec /bin/rm "\$@"
EOF
    chmod +x "$spy/rm"
    write_stub gemini
    PATH="$spy:$PATH" run_council --no-cache --providers=gemini --debate "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round2.gemini.status' 'success'
    run ! grep -q '^/cancel/' "${BATS_TEST_TMPDIR}/rm-argv"
}

@test "cancel: a seat cancelled in round 1 sits out the debate round" {
    setup_pane
    write_stub gemini
    write_slow_stub grok 30
    cancel_from_pane grok &
    COUNCIL_RETRY_WAIT=0 run_council_with_pane --providers=gemini,grok --debate "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.error' 'cancelled from the pane'
    assert_json_eq "$output" '.round2.gemini.status' 'success'
    assert_json_eq "$output" '.round2 | has("grok")' 'false'
    # gemini twice (both rounds), grok once (the cancelled attempt).
    [ "$(grep -c '^gemini$' "$CALLS_LOG")" -eq 2 ]
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
}

@test "metadata: pane_shown is true when a pane streamed the run" {
    setup_pane
    write_stub gemini
    run_council_with_pane --providers=gemini "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.metadata.pane_shown' 'true'
}

@test "metadata: pane_shown is false when the pane was closed before the run ended" {
    # A closed pane stops receiving answers, so the chat must not skip them.
    setup_pane
    write_flaky_stub grok
    play_pane close &
    COUNCIL_RETRY_WAIT=5 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    [ ! -d "$PANE" ]
    assert_json_eq "$output" '.metadata.pane_shown' 'false'
}

@test "metadata: pane_shown is false for a detached --async job" {
    setup_pane
    write_stub gemini
    COUNCIL_JOB_ID=job-test run_council_with_pane --providers=gemini "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.metadata.pane_shown' 'false'
}

@test "metadata: pane_shown is false when no pane opened" {
    write_stub gemini
    run_council --no-cache --no-pane --providers=gemini "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.metadata.pane_shown' 'false'
}

@test "retry: an inherited COUNCIL_PANE_DIR that is not a watch dir is ignored" {
    # A leaked export naming some ordinary directory must not turn it into a
    # pane: nothing would be streamed into it and no watcher would ever answer
    # the offer, so the run would wait out the whole window for nobody.
    PANE="${BATS_TEST_TMPDIR}/not-a-pane"
    mkdir -p "$PANE"
    write_flaky_stub grok
    COUNCIL_RETRY_WAIT=5 run_council_with_pane --providers=grok "q"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.round1.grok.status' 'error'
    [ ! -f "$PANE/status" ]
    [ "$(grep -c '^grok$' "$CALLS_LOG")" -eq 1 ]
}

# A provider script that answers with the names of the variables it received.
env_reporting_provider() {
    mkdir -p "$1"
    printf '#!/bin/bash\nenv | cut -d= -f1 | sort | tr "\\n" " "\n' > "$1/$2.sh"
    chmod +x "$1/$2.sh"
}

@test "query-council: a provider gets its own key and the base environment, no other secret" {
    local fakedir="${BATS_TEST_TMPDIR}/env-scrub"
    env_reporting_provider "$fakedir" gemini
    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY=example-key GEMINI_MODEL=gemini-x \
        OPENAI_API_KEY=other-key BWS_ACCESS_TOKEN=vault EXAMPLE_DB_PASSWORD=pw \
        CLAUDE_CODE_OAUTH_TOKEN=example-token \
        "$HOST_BASH" "$SCRIPT" --no-cache --no-pane --providers=gemini "ping"
    [ "$status" -eq 0 ]
    local seen
    seen=" $(echo "$output" | jq -r '.round1.gemini.response') "
    for name in GEMINI_API_KEY GEMINI_MODEL PATH HOME COUNCIL_SEAT; do
        [[ "$seen" == *" $name "* ]] || { echo "missing $name in:$seen"; return 1; }
    done
    for name in OPENAI_API_KEY BWS_ACCESS_TOKEN EXAMPLE_DB_PASSWORD CLAUDE_CODE_OAUTH_TOKEN PROVIDERS_DIR_REAL; do
        [[ "$seen" != *" $name "* ]] || { echo "leaked $name in:$seen"; return 1; }
    done
}

@test "query-council: COUNCIL_PASS_ENV lets named variables through to every provider" {
    local fakedir="${BATS_TEST_TMPDIR}/env-pass"
    env_reporting_provider "$fakedir" gemini
    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY=example-key \
        EXAMPLE_CA_PATH=/etc/ca EXAMPLE_DB_PASSWORD=pw COUNCIL_PASS_ENV="EXAMPLE_CA_PATH" \
        "$HOST_BASH" "$SCRIPT" --no-cache --no-pane --providers=gemini "ping"
    [ "$status" -eq 0 ]
    local seen
    seen=" $(echo "$output" | jq -r '.round1.gemini.response') "
    [[ "$seen" == *" EXAMPLE_CA_PATH "* ]]
    [[ "$seen" != *" EXAMPLE_DB_PASSWORD "* ]]
}

@test "query-council: claude-cli keeps its login variables and none of the driving session's" {
    local fakedir="${BATS_TEST_TMPDIR}/env-claude-cli"
    env_reporting_provider "$fakedir" claude-cli
    run --separate-stderr env PROVIDERS_DIR="$fakedir" CLAUDE_CLI_MODEL=example-model \
        CLAUDE_CODE_OAUTH_TOKEN=example-token CLAUDE_CONFIG_DIR=/tmp/example-config \
        CLAUDE_CODE_SESSION_ID=example-session CLAUDE_CODE_MESSAGING_SOCKET=/tmp/example.sock \
        CLAUDECODE=1 ANTHROPIC_API_KEY=example-key \
        "$HOST_BASH" "$SCRIPT" --no-cache --no-pane --providers=claude-cli "ping"
    [ "$status" -eq 0 ]
    local seen
    seen=" $(echo "$output" | jq -r '.round1["claude-cli"].response') "
    for name in CLAUDE_CLI_MODEL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR PATH HOME; do
        [[ "$seen" == *" $name "* ]] || { echo "missing $name in:$seen"; return 1; }
    done
    for name in CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDECODE ANTHROPIC_API_KEY; do
        [[ "$seen" != *" $name "* ]] || { echo "leaked $name in:$seen"; return 1; }
    done
}

@test "query-council: grok gets the xAI key it is issued under" {
    local fakedir="${BATS_TEST_TMPDIR}/env-grok"
    env_reporting_provider "$fakedir" grok
    run --separate-stderr env PROVIDERS_DIR="$fakedir" XAI_API_KEY=example-key GEMINI_API_KEY=other-key \
        "$HOST_BASH" "$SCRIPT" --no-cache --no-pane --providers=grok "ping"
    [ "$status" -eq 0 ]
    local seen
    seen=" $(echo "$output" | jq -r '.round1.grok.response') "
    [[ "$seen" == *" XAI_API_KEY "* ]]
    [[ "$seen" != *" GEMINI_API_KEY "* ]]
}
