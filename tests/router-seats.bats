#!/usr/bin/env bats
# ABOUTME: One provider script, many seats — OPENROUTER_MODELS splits the router
# ABOUTME: into numbered seats that each carry their own model id

load test_helper
bats_require_minimum_version 1.5.0

PROVIDERS_LIB="${LIB_DIR}/providers.sh"
PROVIDERS_DIR_REAL="${SCRIPTS_DIR}/providers"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset_provider_keys
    unset OPENROUTER_MODELS
}

# Source the lib with PROVIDERS_DIR pointing at the real providers directory.
lib() {
    bash -c "
        set -euo pipefail
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        $*
    "
}

# ---- get_model resolves a seat to its own entry in the list ----

@test "get_model: each numbered seat reads its own entry in OPENROUTER_MODELS" {
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max"
    run lib 'get_model openrouter-1; get_model openrouter-2; get_model openrouter-3'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "deepseek/deepseek-v3.2" ]
    [ "${lines[1]}" = "z-ai/glm-5.3" ]
    [ "${lines[2]}" = "qwen/qwen3-max" ]
}

@test "get_model: the unnumbered seat ignores the list and keeps its own default" {
    # OPENROUTER_MODEL still drives the single seat, which --providers=openrouter
    # and the stop-gate reviewer both still use.
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3"
    run lib 'get_model openrouter'
    [ "$status" -eq 0 ]
    [ "$output" = "anthropic/claude-sonnet-5" ]
}

@test "get_model: a per-seat override wins over the list" {
    # The exit-3 degrade path forces a fallback by exporting <PREFIX>_MODEL, and
    # the prefix for openrouter-2 is OPENROUTER_2. If the list won, the re-run
    # would send the failing model again.
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3"
    export OPENROUTER_2_MODEL="qwen/qwen3-max"
    run lib 'get_model openrouter-2'
    [ "$status" -eq 0 ]
    [ "$output" = "qwen/qwen3-max" ]
}

@test "get_model: a seat past the end of the list is not silently a real model" {
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2"
    run lib 'get_model openrouter-4'
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# ---- discovery synthesises one seat per roster entry ----

@test "discover_providers: the roster becomes one seat per entry, replacing the single seat" {
    export OPENROUTER_API_KEY=k
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max"
    run lib 'default_provider_set'
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter-1"* ]]
    [[ "$output" == *"openrouter-2"* ]]
    [[ "$output" == *"openrouter-3"* ]]
    # The unnumbered seat must not also appear, or the roster would answer twice
    # with its first model wearing two different headers.
    [[ "$(printf '%s\n' $output | grep -cx 'openrouter')" -eq 0 ]]
}

@test "discover_providers: no roster leaves the single seat exactly as it was" {
    export OPENROUTER_API_KEY=k
    run lib 'default_provider_set'
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' $output | grep -cx 'openrouter')" -eq 1 ]]
    [[ "$output" != *"openrouter-1"* ]]
}

@test "discover_providers: a roster without a key seats nothing" {
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3"
    run lib 'default_provider_set'
    [ "$status" -eq 0 ]
    [[ "$output" != *"openrouter"* ]]
}

# ---- the seats keep their own identity in every lookup table ----

@test "provider tables: a numbered seat is not rendered as an unknown provider" {
    # provider_color and provider_emoji both have catch-all defaults, so a seat
    # missing from them renders in ollama's cyan with the fallback glyph rather
    # than failing — visibly wrong, but only if something asserts it.
    run lib 'BLUE= WHITE= RED= GREEN= MAGENTA= CYAN= LIGHT_YELLOW=SENTINEL; provider_color openrouter-2; provider_emoji openrouter-2'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "SENTINEL" ]
    [ "${lines[1]}" = "$(lib 'provider_emoji openrouter')" ]
}

@test "provider_script_path: numbered seats all run the one router script" {
    run lib 'provider_script_path openrouter-3; provider_script_path openrouter; provider_script_path gemini'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == */providers/openrouter.sh ]]
    [[ "${lines[1]}" == */providers/openrouter.sh ]]
    [[ "${lines[2]}" == */providers/gemini.sh ]]
}

@test "provider_vision_capable: a numbered seat opts in per seat, not collectively" {
    export OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3"
    # Unknowable from here which routed model takes images, so the safe default
    # is text-only; the opt-in names one seat, not the whole roster.
    run lib 'provider_vision_capable openrouter-1 && echo YES || echo NO'
    [ "$output" = "NO" ]
    run lib 'OPENROUTER_2_VISION=1; provider_vision_capable openrouter-2 && echo YES || echo NO'
    [ "$output" = "YES" ]
    run lib 'OPENROUTER_2_VISION=1; provider_vision_capable openrouter-1 && echo YES || echo NO'
    [ "$output" = "NO" ]
}

# ---- end to end: the orchestrator runs N seats off the one script ----

# A stub standing in for openrouter.sh that reports the seat it was told it is
# and the model that seat resolves to. Only these two facts are under test; the
# real script's payload is covered in providers.bats.
write_router_stub() {
    STUB_DIR="${BATS_TEST_TMPDIR}/providers"
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/openrouter.sh" <<EOF
#!/bin/bash
source "${LIB_DIR}/providers.sh"
seat="\${COUNCIL_SEAT:-openrouter}"
echo "seat=\${seat} model=\$(get_model "\$seat")"
EOF
    chmod +x "$STUB_DIR/openrouter.sh"
}

@test "query-council: a three-model roster answers as three seats, each with its own model" {
    write_router_stub
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" \
        COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        OPENROUTER_API_KEY=k \
        OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3,qwen/qwen3-max" \
        "$HOST_BASH" "${SCRIPTS_DIR}/query-council.sh" --no-cache "hi"
    [ "$status" -eq 0 ]
    # Each seat must both be labelled with, and have actually queried, its own
    # roster entry — the label alone would pass even if all three sent one model.
    [[ "$(jq -r '.round1["openrouter-1"].model' <<<"$output")" == "deepseek/deepseek-v3.2" ]]
    [[ "$(jq -r '.round1["openrouter-2"].model' <<<"$output")" == "z-ai/glm-5.3" ]]
    [[ "$(jq -r '.round1["openrouter-3"].model' <<<"$output")" == "qwen/qwen3-max" ]]
    [[ "$(jq -r '.round1["openrouter-1"].response' <<<"$output")" == *"seat=openrouter-1 model=deepseek/deepseek-v3.2"* ]]
    [[ "$(jq -r '.round1["openrouter-2"].response' <<<"$output")" == *"seat=openrouter-2 model=z-ai/glm-5.3"* ]]
    [[ "$(jq -r '.round1["openrouter-3"].response' <<<"$output")" == *"seat=openrouter-3 model=qwen/qwen3-max"* ]]
}

@test "query-council: --providers can name a single roster seat" {
    write_router_stub
    run --separate-stderr env PROVIDERS_DIR="$STUB_DIR" \
        COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        OPENROUTER_API_KEY=k \
        OPENROUTER_MODELS="deepseek/deepseek-v3.2,z-ai/glm-5.3" \
        "$HOST_BASH" "${SCRIPTS_DIR}/query-council.sh" --providers=openrouter-2 --no-cache "hi"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.round1["openrouter-2"].model' <<<"$output")" == "z-ai/glm-5.3" ]]
    [[ "$(jq -r '.round1 | keys | length' <<<"$output")" -eq 1 ]]
    # The label is stamped by coerce_result_json even when no script ran, so the
    # response is what proves the seat actually resolved to a script.
    [[ "$(jq -r '.round1["openrouter-2"].status' <<<"$output")" == "success" ]]
    [[ "$(jq -r '.round1["openrouter-2"].response' <<<"$output")" == *"seat=openrouter-2 model=z-ai/glm-5.3"* ]]
}
