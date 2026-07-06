#!/usr/bin/env bats
# ABOUTME: Tests for lib/prompts.sh template loading and {{VAR}} interpolation
# ABOUTME: Missing variables collapse to empty; values may contain any characters

load test_helper

PROMPTS_LIB="${LIB_DIR}/prompts.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR"
    source "$PROMPTS_LIB"
}

@test "load_prompt_template: returns template file content" {
    run load_prompt_template role-injection
    [ "$status" -eq 0 ]
    [[ "$output" == *"{{ROLE_NAME}}"* ]]
    [[ "$output" == *"{{QUESTION}}"* ]]
}

@test "load_prompt_template: fails loudly for unknown template" {
    run load_prompt_template no-such-template
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "interpolate_template: replaces a {{VAR}} slot" {
    run interpolate_template "Hello {{NAME}}!" "NAME=world"
    [ "$status" -eq 0 ]
    [[ "$output" == "Hello world!" ]]
}

@test "interpolate_template: replaces repeated slots" {
    run interpolate_template "{{X}} and {{X}}" "X=twice"
    [ "$status" -eq 0 ]
    [[ "$output" == "twice and twice" ]]
}

@test "interpolate_template: missing variables collapse to empty" {
    run interpolate_template "before {{UNSET_VAR}} after"
    [ "$status" -eq 0 ]
    [[ "$output" == "before  after" ]]
}

@test "interpolate_template: values may contain slashes, ampersands, newlines" {
    local val=$'a/b &c\nsecond line'
    run interpolate_template "X: {{VAL}}" "VAL=$val"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a/b &c"* ]]
    [[ "$output" == *"second line"* ]]
}

@test "interpolate_template: value containing equals sign survives" {
    run interpolate_template "{{KV}}" "KV=key=value"
    [ "$status" -eq 0 ]
    [[ "$output" == "key=value" ]]
}

@test "interpolate_template: {{...}} inside a value is preserved, not stripped" {
    # A diff containing mustache/Jinja braces must survive interpolation intact
    local diff=$'+ render({{ user.name }})\n- render({{ old }})'
    run interpolate_template "DIFF:\n{{DIFF}}" "DIFF=$diff"
    [ "$status" -eq 0 ]
    [[ "$output" == *"{{ user.name }}"* ]]
    [[ "$output" == *"{{ old }}"* ]]
}

@test "interpolate_template: an unprovided slot is removed but same-named braces in a value stay" {
    # {{Q}} is provided (its value contains {{X}}); {{X}} is NOT a provided slot
    run interpolate_template "{{Q}} then {{X}}" "Q=ask {{X}} now"
    [ "$status" -eq 0 ]
    # the {{X}} from the value is preserved; the standalone {{X}} slot is removed
    [[ "$output" == "ask {{X}} now then " ]]
}

@test "build_prompt_with_role: renders through the role-injection template" {
    source "${LIB_DIR}/roles.sh"
    local result
    result=$(build_prompt_with_role "user question" "security")
    [[ "$result" == *"[ROLE: Security Auditor]"* ]]
    [[ "$result" == *"[USER QUESTION]"* ]]
    [[ "$result" == *"user question"* ]]
}

@test "prompts: synthesis template exists with calibration rules" {
    run load_prompt_template synthesis
    [ "$status" -eq 0 ]
    [[ "$output" == *"Consensus"* ]]
    [[ "$output" == *"Divergence"* ]]
    [[ "$output" == *"Recommendation"* ]]
}
