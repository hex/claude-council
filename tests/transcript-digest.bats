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

# A cross-session peer message carries another Claude's first-person prose in
# both origin.body and message.content. Nothing about the text distinguishes it
# from a human turn — only isMeta does. Regression lock on that clause.
peer_message() {
    jq -nc --arg text "$1" \
        '{type:"user", isMeta:true, promptSource:"system",
          origin:{kind:"peer", from:"other-session", body:$text},
          message:{content:$text}}'
}

# Compaction leaves the summarised turns present verbatim earlier in the same
# file, so emitting the summary too would double-count that span.
compact_summary() {
    jq -nc --arg text "$1" \
        '{type:"user", isCompactSummary:true, isVisibleInTranscriptOnly:true,
          message:{content:$text}}'
}

@test "digest: a peer message is never emitted as a human turn" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "my own question"
        peer_message "I reviewed the design and it looks sound to me."
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"my own question"* ]]
    [[ "$output" != *"looks sound to me"* ]]
}

@test "digest: a compact summary is not emitted as conversation" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "the real turn"
        compact_summary "This session is being continued from a previous conversation."
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the real turn"* ]]
    [[ "$output" != *"being continued from a previous"* ]]
}

@test "digest: thinking blocks are not emitted" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "a question"
        jq -nc '{type:"assistant", message:{id:"m1", content:[
            {type:"thinking", thinking:"private chain of reasoning", signature:"AAAA"}]}}'
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" "$t"
    [ "$status" -eq 0 ]
    [[ "$output" != *"private chain of reasoning"* ]]
    [[ "$output" != *"AAAA"* ]]
}

@test "digest: --turns last:N keeps only the most recent human turns" {
    local t="${BATS_TEST_TMPDIR}/session.jsonl"
    {
        human_turn "oldest question"
        assistant_text "oldest answer" "m1"
        human_turn "middle question"
        assistant_text "middle answer" "m2"
        human_turn "newest question"
        assistant_text "newest answer" "m3"
    } > "$t"

    run "$HOST_BASH" "$SCRIPT" --turns last:2 "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"newest question"* ]]
    [[ "$output" == *"middle question"* ]]
    [[ "$output" != *"oldest question"* ]]
    [[ "$output" != *"oldest answer"* ]]
}

# Passing a session id is the natural mistake, and resolving it is exactly the
# behaviour that lets a subagent digest its parent's conversation. The refusal
# has to say what to do instead, or the caller will just reimplement the lookup.
@test "digest: a bare session id is refused with guidance, not resolved" {
    run "$HOST_BASH" "$SCRIPT" 8a8907bc-ee8c-46ee-ac12-dbeb35057a10
    [ "$status" -ne 0 ]
    [[ "$output" == *"session id"* ]]
    [[ "$output" == *"projects"* ]]
}
