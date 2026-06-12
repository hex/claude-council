#!/usr/bin/env bats
# ABOUTME: Tests for validate-analysis.sh enforcement of the agent-analysis contract
# ABOUTME: Valid docs pass; malformed docs fail loudly naming each violation

load test_helper

VALIDATOR="${SCRIPTS_DIR}/validate-analysis.sh"
SCHEMA="${PROJECT_ROOT}/schemas/agent-analysis.schema.json"

valid_doc() {
    jq -n '{
        quality: "good",
        retried: false,
        confidence: "high",
        key_recommendations: ["Use X", "Avoid Y"],
        unique_perspective: "Brings infra cost angle.",
        blind_spots: "Ignores migration risk.",
        full_response: "The complete provider text."
    }'
}

@test "validate-analysis: accepts a valid document" {
    run bash "$VALIDATOR" <<< "$(valid_doc)"
    [ "$status" -eq 0 ]
}

@test "validate-analysis: rejects non-JSON input naming the problem" {
    run bash "$VALIDATOR" <<< "### Quality: good (markdown, not JSON)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "validate-analysis: rejects unknown quality value" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq '.quality = "excellent"')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"quality"* ]]
}

@test "validate-analysis: rejects missing confidence" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq 'del(.confidence)')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confidence"* ]]
}

@test "validate-analysis: rejects non-boolean retried" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq '.retried = "yes"')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"retried"* ]]
}

@test "validate-analysis: rejects empty key_recommendations" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq '.key_recommendations = []')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"key_recommendations"* ]]
}

@test "validate-analysis: rejects empty full_response" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq '.full_response = ""')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"full_response"* ]]
}

@test "validate-analysis: reports all violations at once" {
    run bash "$VALIDATOR" <<< "$(valid_doc | jq '.quality = "bad" | del(.blind_spots)')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"quality"* ]]
    [[ "$output" == *"blind_spots"* ]]
}

@test "schema: declares the same required fields the validator enforces" {
    run jq -r '.required | sort | join(",")' "$SCHEMA"
    [ "$status" -eq 0 ]
    [[ "$output" == "blind_spots,confidence,full_response,key_recommendations,quality,retried,unique_perspective" ]]
}
