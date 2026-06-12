#!/usr/bin/env bats
# ABOUTME: Tests for the opt-in Stop-hook review gate
# ABOUTME: Gate is off by default, loop-guarded, and reviews the uncommitted diff

load test_helper
load fixtures/fake-clis

GATE="${SCRIPTS_DIR}/stop-review-gate.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    export COUNCIL_JOBS_DIR="${BATS_TEST_TMPDIR}/jobs"
    # Isolated git repo so diff content is under test control
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "$REPO/.claude"
    cd "$REPO"
    git init -q
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

stop_event() {
    local active="${1:-false}"
    jq -n --argjson a "$active" \
        '{session_id: "test-session", stop_hook_active: $a, transcript_path: "/dev/null"}'
}

enable_gate() {
    jq -n '{enabled: true, provider: "codex", max_iterations: 1}' \
        > "$REPO/.claude/council-stop-gate.json"
}

dirty_diff() {
    echo "tracked" > file.txt
    git add file.txt
    git -c user.email=t@t -c user.name=t commit -q -m add
    echo "changed" > file.txt
}

@test "stop-gate: silent no-op when no config exists" {
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "stop-gate: silent no-op when config disables it" {
    jq -n '{enabled: false}' > "$REPO/.claude/council-stop-gate.json"
    dirty_diff
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "stop-gate: allows when stop_hook_active is true" {
    enable_gate
    dirty_diff
    export COUNCIL_FAKE_BEHAVIOR=block-verdict
    run bash "$GATE" <<< "$(stop_event true)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision"'* ]]
}

@test "stop-gate: allows without querying the provider when diff is clean" {
    enable_gate
    export COUNCIL_FAKE_BEHAVIOR=block-verdict
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision"'* ]]
    # Provider must not have been called
    [[ ! -f "$COUNCIL_FAKE_STATE_DIR/calls.jsonl" ]]
}

@test "stop-gate: blocks with reason when reviewer says BLOCK" {
    enable_gate
    dirty_diff
    export COUNCIL_FAKE_BEHAVIOR=block-verdict
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    assert_json_eq "$output" '.decision' "block"
    [[ "$(echo "$output" | jq -r '.reason')" == *"tests are failing"* ]]
}

@test "stop-gate: allows when reviewer verdict is not BLOCK" {
    enable_gate
    dirty_diff
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision"'* ]]
}

@test "stop-gate: provider failure allows the stop (never traps the user)" {
    enable_gate
    dirty_diff
    export COUNCIL_FAKE_BEHAVIOR=error
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision"'* ]]
}

@test "stop-gate: per-session iteration cap stops repeat blocks" {
    enable_gate
    dirty_diff
    export COUNCIL_FAKE_BEHAVIOR=block-verdict
    run bash "$GATE" <<< "$(stop_event)"
    assert_json_eq "$output" '.decision' "block"
    # Second stop in the same session: cap of 1 reached, must allow
    run bash "$GATE" <<< "$(stop_event)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision"'* ]]
}
