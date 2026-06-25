#!/usr/bin/env bats
# ABOUTME: Tests for codex/antigravity provider integration and CLI-prefers-API policy
# ABOUTME: Covers lib/providers.sh discovery + filter, plus query-council.sh wiring

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${SCRIPTS_DIR}/query-council.sh"
PROVIDERS_LIB="${LIB_DIR}/providers.sh"
PROVIDERS_DIR_REAL="${SCRIPTS_DIR}/providers"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset_provider_keys
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# Source the lib in a subshell with PROVIDERS_DIR pointing at the real
# providers directory. Returns the function output to the bats `run` capture.
source_lib_and_call() {
    bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        $*
    "
}

# ============================================================================
# discover_providers — binary-gated CLI providers
# ============================================================================

@test "discover_providers: includes codex when binary is on PATH" {
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
}

@test "discover_providers: includes antigravity when agy binary is on PATH" {
    if ! command_exists agy; then skip "agy CLI not installed"; fi
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"antigravity"* ]]
}

@test "discover_providers: excludes codex when binary is missing" {
    # Strip codex from PATH by running with a minimal PATH
    run bash -c "
        set -euo pipefail
        export PATH=/usr/bin:/bin
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        discover_providers
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"codex"* ]]
    [[ "$output" != *"antigravity"* ]]
}

@test "discover_providers: excludes API providers when keys unset" {
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" != *"openai"* ]]
    [[ "$output" != *"perplexity"* ]]
}

@test "discover_providers: includes openai when OPENAI_API_KEY is set" {
    export OPENAI_API_KEY="test-key"
    run bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        export OPENAI_API_KEY='test-key'
        source '${PROVIDERS_LIB}'
        discover_providers
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai"* ]]
}

# ============================================================================
# prefer_cli_over_api — CLI-prefers-API policy
#
# These tests intentionally fail against the identity stub at lib/providers.sh.
# Alex's implementation of the policy turns them green. Per TDD: write the
# spec first, then the code.
# ============================================================================

@test "prefer_cli_over_api: identity when input is empty" {
    run source_lib_and_call 'prefer_cli_over_api'
    [ "$status" -eq 0 ]
    assert_blank "$output"
}

@test "prefer_cli_over_api: identity when neither CLI is in input" {
    run source_lib_and_call 'prefer_cli_over_api openai gemini perplexity'
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai"* ]]
    [[ "$output" == *"gemini"* ]]
    [[ "$output" == *"perplexity"* ]]
}

@test "prefer_cli_over_api: drops openai when codex is present" {
    run source_lib_and_call 'prefer_cli_over_api codex openai grok'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"grok"* ]]
    [[ "$output" != *"openai"* ]]
}

@test "prefer_cli_over_api: drops gemini when antigravity is present" {
    run source_lib_and_call 'prefer_cli_over_api antigravity gemini perplexity'
    [ "$status" -eq 0 ]
    [[ "$output" == *"antigravity"* ]]
    [[ "$output" == *"perplexity"* ]]
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}

@test "prefer_cli_over_api: drops both API siblings when both CLIs present" {
    run source_lib_and_call 'prefer_cli_over_api codex antigravity openai gemini grok'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"antigravity"* ]]
    [[ "$output" == *"grok"* ]]
    [[ "$output" != *"openai"* ]]
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}

@test "prefer_cli_over_api: preserves input order" {
    run source_lib_and_call 'prefer_cli_over_api perplexity codex grok'
    [ "$status" -eq 0 ]
    # Expect "perplexity codex grok" — order preserved, nothing dropped
    [[ "$output" =~ perplexity[[:space:]]+codex[[:space:]]+grok ]]
}

@test "shadow_origin: gemini is shadowed by antigravity" {
    run source_lib_and_call 'shadow_origin gemini'
    [ "$status" -eq 0 ]
    [[ "$output" == "antigravity" ]]
}

@test "get_model: antigravity default is a Gemini Flash model" {
    run source_lib_and_call 'get_model antigravity'
    [ "$status" -eq 0 ]
    [[ "$output" == "Gemini 3.5 Flash (High)" ]]
}

# ============================================================================
# api_sibling — reverse of shadow_origin (CLI → API fallback target)
# ============================================================================

@test "api_sibling: codex falls back to openai" {
    run source_lib_and_call 'api_sibling codex'
    [ "$status" -eq 0 ]
    [[ "$output" == "openai" ]]
}

@test "api_sibling: antigravity falls back to gemini" {
    run source_lib_and_call 'api_sibling antigravity'
    [ "$status" -eq 0 ]
    [[ "$output" == "gemini" ]]
}

@test "api_sibling: provider with no sibling yields empty" {
    run source_lib_and_call 'api_sibling grok'
    [ "$status" -eq 0 ]
    assert_blank "$output"
}

@test "api_sibling is the exact inverse of shadow_origin (single source of truth)" {
    # For every API provider shadow_origin maps to a CLI, api_sibling must map
    # that CLI back to the same API provider. Locks the two against drift.
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        for api in openai gemini; do
            cli=\$(shadow_origin \"\$api\")
            back=\$(api_sibling \"\$cli\")
            [[ \"\$back\" == \"\$api\" ]] || { echo \"MISMATCH \$api -> \$cli -> \$back\"; exit 1; }
        done
        echo OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "OK" ]]
}

@test "api_key_present: true when the env var is set" {
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        export GEMINI_API_KEY=x
        api_key_present gemini && echo YES
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "YES" ]]
}

@test "api_key_present: false when the env var is unset" {
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        unset GEMINI_API_KEY
        api_key_present gemini || echo NO
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "NO" ]]
}

@test "api_key_present: gates generically on <NAME>_API_KEY (openai)" {
    # Uses the same convention as discover_providers' generic branch, so any
    # API provider is covered without a per-provider case arm.
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        export OPENAI_API_KEY=x
        api_key_present openai && echo YES
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "YES" ]]
}

# ============================================================================
# coerce_result_json — collection-loop JSON guard (issue #3)
#
# The result-collection loop reads provider output files and feeds them to
# `jq --argjson`. Under `set -e`, a single invalid-JSON file aborts the whole
# council run. coerce_result_json guarantees valid JSON (merging .model) so one
# misbehaving provider can no longer take down every other provider's result.
# ============================================================================

@test "coerce_result_json: valid JSON passes through with model merged" {
    run source_lib_and_call $'coerce_result_json \'{"status":"success","response":"hi"}\' gpt-5'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.response')" == "hi" ]]
    [[ "$(echo "$output" | jq -r '.model')" == "gpt-5" ]]
}

@test "coerce_result_json: invalid JSON is coerced to an error result, not a crash" {
    # ANSI-coloured plain text — exactly the agy-provider repro from issue #3.
    run source_lib_and_call $'coerce_result_json "$(printf \'\\033[33mconnection refused\\033[0m\')" gemini-2.5-flash'
    [ "$status" -eq 0 ]
    # Output is itself valid JSON (so --argjson downstream cannot crash)
    echo "$output" | jq empty
    [[ "$(echo "$output" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$output" | jq -r '.error')" == *"invalid JSON"* ]]
    [[ "$(echo "$output" | jq -r '.model')" == "gemini-2.5-flash" ]]
}

@test "coerce_result_json: empty input is coerced to an error result" {
    run source_lib_and_call 'coerce_result_json "" some-model'
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
    [[ "$(echo "$output" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$output" | jq -r '.model')" == "some-model" ]]
}

@test "coerce_result_json: a model already in the result is preserved, not overwritten" {
    run source_lib_and_call $'coerce_result_json \'{"status":"success","response":"hi","model":"gemini-3.1-pro-preview"}\' some-default-model'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.model')" == "gemini-3.1-pro-preview" ]]
}

# ============================================================================
# CLI→API fallback — a failing CLI provider retries through its API sibling.
# Hermetic: a temp PROVIDERS_DIR with a failing antigravity.sh and a stub
# gemini.sh, driven through the real query-council.sh orchestration.
# ============================================================================

@test "query-council: antigravity failure falls back to the gemini API sibling" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-providers"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "FALLBACK-GEMINI-ANSWER"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    local slot
    slot=$(echo "$output" | jq -c '.round1.antigravity')
    [[ "$(echo "$slot" | jq -r '.status')" == "success" ]]
    [[ "$(echo "$slot" | jq -r '.response')" == *"FALLBACK-GEMINI-ANSWER"* ]]
    [[ "$(echo "$slot" | jq -r '.fallback')" == "gemini" ]]
    [[ "$(echo "$slot" | jq -r '.model')" == "gemini-3.1-pro-preview" ]]
}

@test "query-council: antigravity failure with no gemini key stays an error" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-nokey"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    chmod +x "$fakedir/antigravity.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" bash "$SCRIPT" \
        --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    local slot
    slot=$(echo "$output" | jq -c '.round1.antigravity')
    [[ "$(echo "$slot" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$slot" | jq -r '.error')" == *"boom"* ]]
}

@test "query-council: antigravity failure falls back to gemini in round 2 (debate)" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-r2"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "FALLBACK-GEMINI-ANSWER"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --debate --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    local r2
    r2=$(echo "$output" | jq -c '.round2.antigravity')
    [[ "$(echo "$r2" | jq -r '.status')" == "success" ]]
    [[ "$(echo "$r2" | jq -r '.response')" == *"FALLBACK-GEMINI-ANSWER"* ]]
    [[ "$(echo "$r2" | jq -r '.fallback')" == "gemini" ]]
    [[ "$(echo "$r2" | jq -r '.model')" == "gemini-3.1-pro-preview" ]]
    # Round-2 fallback slot carries the same shape as round 1 (role + cached),
    # so the success shape can't silently drift between rounds.
    [[ "$(echo "$r2" | jq -r '.cached')" == "false" ]]
    [[ "$(echo "$r2" | jq -r 'has("role")')" == "true" ]]
}

@test "query-council: no fallback when the API sibling is also an explicit provider" {
    # antigravity fails, but gemini is ALSO selected — it answers in its own
    # slot, so the antigravity slot must NOT duplicate gemini's answer.
    local fakedir="${BATS_TEST_TMPDIR}/fallback-dup"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "GEMINI-SLOT-ANSWER"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity,gemini "ping"
    [ "$status" -eq 0 ]
    # antigravity slot stays an error (no shadow-duplicate of gemini)
    [[ "$(echo "$output" | jq -r '.round1.antigravity.status')" == "error" ]]
    [[ "$(echo "$output" | jq -r '.round1.antigravity.fallback // "none"')" == "none" ]]
    # gemini answers in its own slot, exactly once
    [[ "$(echo "$output" | jq -r '.round1.gemini.status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.round1.gemini.response')" == *"GEMINI-SLOT-ANSWER"* ]]
}

@test "query-council: missing CLI provider script also falls back to the API sibling" {
    # A provider with NO script on disk is as unusable as one that exits 1 —
    # the fallback should rescue both identically.
    local fakedir="${BATS_TEST_TMPDIR}/fallback-missing"
    mkdir -p "$fakedir"
    # antigravity.sh deliberately absent; only the gemini sibling exists.
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "FALLBACK-GEMINI-ANSWER"
EOF
    chmod +x "$fakedir/gemini.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.round1.antigravity.status')" == "success" ]]
    [[ "$(echo "$output" | jq -r '.round1.antigravity.fallback')" == "gemini" ]]
    [[ "$(echo "$output" | jq -r '.round1.antigravity.response')" == *"FALLBACK-GEMINI-ANSWER"* ]]
}

@test "query-council: fallback progress line reports the sibling model, not the CLI model" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-model"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "boom" >&2
exit 1
EOF
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "answer"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    # The success status line on stderr must name the model that answered.
    [[ "$stderr" == *"gemini-3.1-pro-preview"* ]]
    [[ "$stderr" != *"Gemini 3.5 Flash (High)"* ]]
}

@test "query-council: a cached fallback is reused without re-invoking the sibling" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-cache"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "boom" >&2
exit 1
EOF
    # gemini sibling records every invocation so we can count them.
    cat > "$fakedir/gemini.sh" <<EOF
#!/bin/bash
echo "call" >> "${BATS_TEST_TMPDIR}/gemini-calls"
echo "FALLBACK-GEMINI-ANSWER"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    # Two runs with the cache ENABLED (no --no-cache), same prompt.
    for _ in 1 2; do
        run --separate-stderr env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
            COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
            bash "$SCRIPT" --no-pane --providers=antigravity "cache me"
        [ "$status" -eq 0 ]
    done
    # The sibling ran once; the second fallback reused the cached answer.
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/gemini-calls" | tr -d ' ')" -eq 1 ]
}

# ============================================================================
# query-council.sh integration
# ============================================================================

@test "query-council: --list-available shows CLI providers when binaries present" {
    if ! command_exists codex && ! command_exists agy; then
        skip "no CLI providers installed on this machine"
    fi
    run bash "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    if command_exists codex; then
        [[ "$output" == *"codex"* ]]
    fi
    if command_exists agy; then
        [[ "$output" == *"antigravity"* ]]
    fi
}

@test "query-council: --list-available annotates shadowed API providers" {
    # When both OPENAI_API_KEY and codex are present, the human-readable
    # listing must show codex in the default set AND openai in the shadowed
    # section so the user can see both exist.
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    export OPENAI_API_KEY="test-key"
    run bash "$SCRIPT" --list-available
    [ "$status" -eq 0 ]
    [[ "$output" == *"Default query set"* ]]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"Shadowed"* ]]
    [[ "$output" == *"openai"* ]]
}

@test "query-council: --list-default returns post-policy set, machine-readable" {
    # Single space-separated line; CLI siblings drop their API counterparts.
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    export OPENAI_API_KEY="test-key"
    run bash "$SCRIPT" --list-default
    [ "$status" -eq 0 ]
    # Exactly one line of output
    [[ $(echo "$output" | wc -l | tr -d ' ') == "1" ]]
    [[ "$output" == *"codex"* ]]
    # openai is shadowed, must not appear
    [[ ! "$output" =~ (^|[[:space:]])openai([[:space:]]|$) ]]
}

@test "query-council: --providers codex flag is accepted" {
    run bash "$SCRIPT" --providers=codex "test prompt" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

@test "query-council: --providers antigravity flag is accepted" {
    run bash "$SCRIPT" --providers=antigravity "test prompt" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}

# ============================================================================
# End-to-end CLI provider invocation (gated — set COUNCIL_E2E=1 to run)
# ============================================================================

@test "codex.sh: returns response for trivial prompt (E2E)" {
    [[ "${COUNCIL_E2E:-}" == "1" ]] || skip "set COUNCIL_E2E=1 to run real CLI calls"
    if ! command_exists codex; then skip "codex CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/codex.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ============================================================================
# Real-CLI guard (gated — set COUNCIL_E2E=1 to run). Verifies the flag ordering
# + tool-suppression guard against the actual CLI: agy must answer inline (no
# artifact pointer) and accept our flags. Gated like the codex E2E above so the
# default suite never depends on a live model's exact wording.
# ============================================================================

@test "antigravity.sh: real agy answers inline for a trivial prompt (E2E)" {
    [[ "${COUNCIL_E2E:-}" == "1" ]] || skip "set COUNCIL_E2E=1 to run real CLI calls"
    if ! command_exists agy; then skip "agy CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    # Inline answer, not an artifact pointer
    [[ "$output" != *"file:///"* ]]
}
