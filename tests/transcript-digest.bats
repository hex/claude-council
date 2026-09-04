#!/usr/bin/env bats
# ABOUTME: Tests for transcript-digest.sh, which turns a session JSONL into markdown
# ABOUTME: A user line is only a human turn when origin says so — tool results are not

load test_helper

SCRIPT="${SCRIPTS_DIR}/transcript-digest.sh"

# A real human turn. Content is a bare string, which is how 336 of the 367
# human turns in the reference corpus actually store it.
human_turn() {
    jq -nc --arg text "$1" \
        '{type:"user", isMeta:false, origin:{kind:"human"}, message:{content:$text}}'
}

# A tool result. These arrive as type "user" too, and outnumber human turns
# roughly 34 to 1, so the filter that separates them is the whole extractor.
tool_result_line() {
    jq -nc --arg text "$1" \
        '{type:"user", toolUseResult:{stdout:$text},
          message:{content:[{type:"tool_result", content:$text}]}}'
}

@test "digest: emits a human turn and drops a tool result" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "deploy the staging box"
        tool_result_line "AWS_SECRET_TOKEN=hunter2"
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deploy the staging box"* ]]
    [[ "$output" != *"hunter2"* ]]
}

# Assistant content is ALWAYS an array, and is fragmented one content-block per
# line with all fragments sharing a message.id. Two lines here share an id on
# purpose: they are two halves of one reply, not a duplicate to be deduped.
assistant_text() {
    jq -nc --arg text "$1" --arg id "$2" \
        '{type:"assistant", message:{id:$id, content:[{type:"text", text:$text}]}}'
}

@test "digest: emits assistant replies interleaved with human turns in file order" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "first question"
        assistant_text "first answer" "msg_a"
        human_turn "second question"
        assistant_text "second answer" "msg_b"
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"first answer"* ]]
    [[ "$output" == *"second answer"* ]]

    # File order is the only ordering that survives compaction. Walking the
    # parentUuid chain instead starts at the last compact summary and recovers
    # about a quarter of the session, so order is asserted, not assumed.
    local first_q second_q
    first_q=$(echo "$output" | grep -n "first question" | cut -d: -f1)
    second_q=$(echo "$output" | grep -n "second answer" | cut -d: -f1)
    [ "$first_q" -lt "$second_q" ]
}
