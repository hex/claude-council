#!/usr/bin/env bats
# ABOUTME: Classifier + fallback-pair + verdict-cache tests for reactive model fallback
# ABOUTME: Bodies are real vendor responses captured live; verdicts come from vendor semantics

load test_helper
bats_require_minimum_version 1.5.0

RETRY_LIB="${LIB_DIR}/retry.sh"

# Classify a body through a stamped ensure_error_body, exactly as curl_with_retry does.
classify() {
    run env bash -c "
        set -euo pipefail
        source '${RETRY_LIB}'
        body=\$(printf '%s' '$2' | ensure_error_body '$1')
        is_model_unavailable_error \"\$body\"
    "
}

# --- positives: a different model would help -------------------------------

@test "classifier: xAI 403 region block is model-unavailable" {
    classify 403 '{"code":"permission-denied","error":"The model grok-4.5 is not available in your region."}'
    [ "$status" -eq 0 ]
}

@test "classifier: xAI 400 model-not-found is model-unavailable" {
    classify 400 '{"code":"invalid-argument","error":"Model not found: grok-does-not-exist-9"}'
    [ "$status" -eq 0 ]
}

@test "classifier: OpenAI 404 model_not_found is model-unavailable" {
    classify 404 '{"error":{"message":"The model gpt-does-not-exist-9 does not exist or you do not have access to it.","code":"model_not_found"}}'
    [ "$status" -eq 0 ]
}

@test "classifier: Perplexity 400 invalid model is model-unavailable" {
    classify 400 '{"error":{"message":"Invalid model \"sonar-does-not-exist-9\". Permitted models can be found in the documentation.","type":"invalid_model","code":400}}'
    [ "$status" -eq 0 ]
}

@test "classifier: Gemini 404 NOT_FOUND is model-unavailable" {
    classify 404 '{"error":{"code":404,"message":"models/gemini-does-not-exist-9 is not found for API version v1beta.","status":"NOT_FOUND"}}'
    [ "$status" -eq 0 ]
}

# --- negatives: a different model would NOT help ---------------------------

@test "classifier: OpenAI 401 bad key is not model-unavailable" {
    classify 401 '{"error":{"message":"Incorrect API key provided.","code":"invalid_api_key"}}'
    [ "$status" -ne 0 ]
}

@test "classifier: a 400 unsupported reasoning effort is not model-unavailable" {
    # The message names the model and says "is not supported" — it must not match.
    classify 400 '{"error":{"message":"Unsupported value: \"low\" is not supported with the \"gpt-5.5-pro\" model.","param":"reasoning.effort","code":"unsupported_value"}}'
    [ "$status" -ne 0 ]
}

@test "classifier: 429 rate limit is not model-unavailable" {
    classify 429 '{"error":{"message":"Rate limit reached."}}'
    [ "$status" -ne 0 ]
}

@test "classifier: 500 server error is not model-unavailable" {
    classify 500 '{"error":{"message":"Internal server error."}}'
    [ "$status" -ne 0 ]
}

@test "classifier: a synthesised network/timeout body has no status and is not model-unavailable" {
    run env bash -c "
        set -euo pipefail
        source '${RETRY_LIB}'
        body=\$(retry_error_body 'Request timed out after 300 seconds')
        is_model_unavailable_error \"\$body\"
    "
    [ "$status" -ne 0 ]
}

@test "classifier: a 200 success body is not model-unavailable" {
    classify 200 '{"choices":[{"message":{"content":"hi"}}]}'
    [ "$status" -ne 0 ]
}

@test "classifier: a 400 thread-not-found message is not model-unavailable" {
    classify 400 '{"error":{"message":"Thread thread_abc123 does not exist."}}'
    [ "$status" -ne 0 ]
}

@test "classifier: a 400 file-not-found message is not model-unavailable" {
    classify 400 '{"error":{"message":"The requested file file-xyz does not exist or you do not have access to it."}}'
    [ "$status" -ne 0 ]
}

@test "classifier: a bare JSON array body is not model-unavailable" {
    classify 400 '[1,2,3]'
    [ "$status" -ne 0 ]
}

@test "classifier: a 400 bare-string error not naming a model is not model-unavailable" {
    classify 400 '{"error":"Invalid request: temperature must be between 0 and 2"}'
    [ "$status" -ne 0 ]
}

# ============================================================================
# model_fallback_for — the preferred→fallback map
# ============================================================================

MF_LIB="${LIB_DIR}/model_fallback.sh"

mf() {
    run env bash -c "set -euo pipefail; source '${MF_LIB}'; $*"
}

@test "model_fallback_for: each API provider has its verified fallback" {
    mf 'model_fallback_for openai'
    [ "$output" = "gpt-5.5-pro" ]
    mf 'model_fallback_for grok'
    [ "$output" = "grok-4.20-reasoning" ]
    mf 'model_fallback_for perplexity'
    [ "$output" = "sonar-pro" ]
    mf 'model_fallback_for gemini'
    [ "$output" = "gemini-pro-latest" ]
}

@test "model_fallback_for: a CLI provider has no fallback of its own" {
    # codex/antigravity degrade to their API sibling, which then gets model fallback.
    mf 'model_fallback_for codex'
    [ -z "$output" ]
    mf 'model_fallback_for antigravity'
    [ -z "$output" ]
}

@test "model_fallback_for: an unknown provider has no fallback" {
    mf 'model_fallback_for nosuchprovider'
    [ -z "$output" ]
}
