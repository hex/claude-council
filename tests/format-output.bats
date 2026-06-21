#!/usr/bin/env bats
# ABOUTME: Tests for format-output.sh defensive parsing of council JSON
# ABOUTME: Malformed or empty provider output must surface raw, never vanish

load test_helper

SCRIPT="${SCRIPTS_DIR}/format-output.sh"

# Build a council envelope with one provider entry supplied as raw JSON
envelope_with_entry() {
    local entry_json="$1"
    jq -n --argjson entry "$entry_json" \
        '{metadata: {quiet_mode: false, debate_mode: false}, round1: {testprov: $entry}}'
}

@test "format-output: valid response renders verbatim" {
    local json
    json=$(envelope_with_entry '{"status":"success","model":"m1","response":"The actual answer"}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"The actual answer"* ]]
}

@test "format-output: error status renders the error message" {
    local json
    json=$(envelope_with_entry '{"status":"error","model":"m1","error":"boom"}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Error: boom"* ]]
}

@test "format-output: empty response is marked, not silently blank" {
    local json
    json=$(envelope_with_entry '{"status":"success","model":"m1","response":""}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[empty response]"* ]]
}

@test "format-output: whitespace-only response is marked as empty" {
    local json
    json=$(envelope_with_entry '{"status":"success","model":"m1","response":"  \n  "}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[empty response]"* ]]
}

@test "format-output: missing response field surfaces raw entry in fenced block" {
    local json
    json=$(envelope_with_entry '{"status":"success","model":"m1"}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[unparseable response]"* ]]
    [[ "$output" == *'```json'* ]]
    [[ "$output" == *'"m1"'* ]]
}

@test "format-output: non-string response surfaces raw entry instead of garbage" {
    local json
    json=$(envelope_with_entry '{"status":"success","model":"m1","response":{"nested":"object"}}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[unparseable response]"* ]]
    [[ "$output" == *'"nested"'* ]]
}

@test "format-output: error status without error message still shows a marker" {
    local json
    json=$(envelope_with_entry '{"status":"error","model":"m1"}')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Error: Unknown error"* ]]
}

@test "format-output: missing round1 preserves raw input instead of crashing" {
    local json='{"metadata":{"quiet_mode":false},"some_other_key":true}'
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[unparseable council output]"* ]]
    [[ "$output" == *"some_other_key"* ]]
}

@test "format-output: invalid JSON input still errors loudly" {
    run bash "$SCRIPT" '{"not json'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "format-output: fallback note appears when fallback field is set" {
    local json
    json=$(jq -n '{
        metadata: {quiet_mode: false, debate_mode: false},
        round1: {antigravity: {status: "success", model: "gemini-3.1-pro-preview", response: "hi", fallback: "gemini"}}
    }')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fell back to gemini API"* ]]
}

@test "format-output: fallback note absent when fallback field is not set" {
    local json
    json=$(jq -n '{
        metadata: {quiet_mode: false, debate_mode: false},
        round1: {antigravity: {status: "success", model: "gemini-3.1-pro-preview", response: "hi"}}
    }')
    run bash "$SCRIPT" "$json"
    [ "$status" -eq 0 ]
    [[ "$output" != *"fell back"* ]]
}
