#!/usr/bin/env bats
# ABOUTME: Tests for heads-up.sh, the detached side-check runner the council pane forks
# ABOUTME: One seat is asked once; its outcome, note or none or failure, lands in result.json

load test_helper
load fixtures/fake-clis
bats_require_minimum_version 1.5.0

RUNNER="${SCRIPTS_DIR}/heads-up.sh"
SESSION_ID="0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/claude-config"
    TRANSCRIPT="${CLAUDE_CONFIG_DIR}/projects/-tmp-example/${SESSION_ID}.jsonl"
    mkdir -p "$(dirname "$TRANSCRIPT")"
    RUN_DIR="${BATS_TEST_TMPDIR}/run"
    mkdir -p "$RUN_DIR"
    AVOID="${BATS_TEST_TMPDIR}/avoid.txt"
    printf '%s\n' "flaky network test" > "$AVOID"
    export COUNCIL_HEADS_UP_SEAT_SECONDS=20
    write_transcript
}

# A forked worker must never outlive its test: bats would hold the file open
# for it, and a later test would find its files.
teardown() {
    local pid
    pid=$(cat "$RUN_DIR/pid" 2>/dev/null) || return 0
    kill "$pid" 2>/dev/null || true
}

# One human turn, one Bash call and its result, in the shapes Claude Code writes.
write_transcript() {
    {
        jq -nc '{type:"user", isMeta:false, origin:{kind:"human"},
                 message:{content:"migrate the orders table"}}'
        jq -nc '{type:"assistant", message:{id:"msg_1", content:[
                 {type:"tool_use", id:"toolu_1", name:"Bash", input:{command:"run tests"}}]}}'
        jq -nc --arg r "${1:-12 passed against fixtures/empty.db}" \
            '{type:"user", toolUseResult:{stdout:$r},
              message:{content:[{type:"tool_result", tool_use_id:"toolu_1", content:$r}]}}'
    } > "$TRANSCRIPT"
}

# $1 the seat; any further words are passed as they are (--model FILE).
start_runner() {
    local seat="$1"
    shift
    run "$HOST_BASH" "$RUNNER" --run-dir "$RUN_DIR" --session "$SESSION_ID" \
        --seat "$seat" --avoid-file "$AVOID" "$@"
}

# Polls for the worker's .done, up to $1 seconds (default 30).
# Git Bash hands a path to a program as C:/... while the shell's own paths look
# POSIX, and jq ends every line there with CRLF; one spelling for both sides of
# an argv comparison, elsewhere a no-op.
same_paths() {
    local word out=()
    for word in "$@"; do
        word=${word%$'\r'}
        if command -v cygpath >/dev/null 2>&1 && [[ "$word" == /* || "$word" =~ ^[A-Za-z]:/ ]]; then word=$(cygpath -m "$word"); fi
        out+=("$word")
    done
    printf '%s\n' "${out[*]}"
}

wait_done() {
    local ticks=$(( ${1:-30} * 10 ))
    while (( ticks-- > 0 )); do
        [[ -f "$RUN_DIR/.done" ]] && return 0
        sleep 0.1
    done
    echo "no .done in $RUN_DIR after ${1:-30}s" >&2
    ls -la "$RUN_DIR" >&2
    return 1
}

result() {
    jq -r "$1" "$RUN_DIR/result.json"
}

@test "heads-up: a seat name that is not a provider exits 1 before anything forks" {
    start_runner "../../evil"
    [ "$status" -eq 1 ]
    [ "$output" = "Error: not a council seat: ../../evil" ]
    [ ! -f "$RUN_DIR/pid" ]
    [ ! -f "$COUNCIL_FAKE_STATE_DIR/calls.jsonl" ]
}

@test "heads-up: two seats are not one seat and exit 1 before anything forks" {
    start_runner "codex,antigravity"
    [ "$status" -eq 1 ]
    [ "$output" = "Error: not a council seat: codex,antigravity" ]
    [ ! -f "$RUN_DIR/pid" ]
}

@test "heads-up: the call returns with the worker's pid before the seat answers" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-slow-note COUNCIL_FAKE_SLEEP=3
    local before after
    before=$(date +%s)
    start_runner codex
    after=$(date +%s)
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$RUN_DIR/pid")" ]
    [ $(( after - before )) -lt 3 ]
    [ ! -f "$RUN_DIR/.done" ]
    wait_done
    [ "$(result .kind)" = "note" ]
}

@test "heads-up: a codex note lands in result.json" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    export CODEX_MODEL=gpt-test
    start_runner codex
    [ "$status" -eq 0 ]
    wait_done
    [ "$(result .kind)" = "note" ]
    [ "$(result .seat)" = "codex" ]
    [ "$(result .topic)" = "backfill never ran" ]
    [ "$(result .headline)" = "The migration test used an empty fixture, so the backfill path never ran." ]
    # A backslash in the seat's text arrives single, as the seat wrote it.
    [ "$(result .title)" = "The backfill path never ran" ]
    [ "$(result '.points | length')" = "2" ]
    [ "$(result '.points[0]')" = "The fixture had no rows, so the loop had nothing to do." ]
    [ "$(result '.points[1]')" = 'Seed one row in C:\fixtures\empty.db and rerun the migration test.' ]
    [ "$(result '.ms | type')" = "number" ]
    # The model the seat ran, as get_model resolves it, so the band can name it.
    [ "$(result .model)" = "gpt-test" ]
    [ "$(result .tag)" = "Heads up" ]
    [ "$(result '.seats | length')" = "1" ]
    [ "$(result '.seats[0].seat + " " + .seats[0].outcome')" = "codex note" ]
    [ "$(jq -r .bin "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")" = "codex" ]
}

@test "heads-up: a text seat's NOTE lines become the note" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner antigravity
    wait_done
    [ "$(result .kind)" = "note" ]
    [ "$(result .seat)" = "antigravity" ]
    [ "$(result .headline)" = "The retry loop never backs off, so a 429 storm hammers the API." ]
    [ "$(result .tag)" = "You should know" ]
    [ "$(result .topic)" = "retry without backoff" ]
    [ "$(result .title)" = "Retries without backoff" ]
    [ "$(result '.points | join("|")')" = "Each retry fires at once.|Add a growing delay." ]
    [ "$(result '[.seats[] | .seat + " " + .outcome] | join(",")')" = "antigravity note" ]
}

@test "heads-up: codex is asked through the schema with the prompt on stdin" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    wait_done
    local args dir expected
    # shellcheck disable=SC2207  # the fake records one argv word per line, none with spaces
    args=$(same_paths $(jq -r '.args[]' "$COUNCIL_FAKE_STATE_DIR/calls.jsonl"))
    dir=$(cd "$SCRIPTS_DIR" && pwd)
    expected=$(same_paths exec --json --skip-git-repo-check -s read-only --output-schema "${dir}/heads-up.schema.json" -o "${RUN_DIR}/seat.out" -)
    echo "recorded: $args"
    echo "expected: $expected"
    [ "$args" = "$expected" ]
    cmp "$RUN_DIR/prompt.md" "$COUNCIL_FAKE_STATE_DIR/codex-stdin.txt"
}

@test "heads-up: bytes is the size of prompt.md, the payload that left the machine" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    wait_done
    [ -s "$RUN_DIR/prompt.md" ]
    [ "$(result .bytes)" = "$(wc -c < "$RUN_DIR/prompt.md" | tr -d ' ')" ]
}

@test "heads-up: a secret in a tool result reaches prompt.md, on purpose" {
    write_transcript "AWS_SECRET_TOKEN=hunter2"
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    wait_done
    grep -q "AWS_SECRET_TOKEN=hunter2" "$RUN_DIR/prompt.md"
    grep -q "## Tool result · Bash" "$RUN_DIR/prompt.md"
    grep -q "migrate the orders table" "$RUN_DIR/prompt.md"
    grep -q "flaky network test" "$RUN_DIR/prompt.md"
    # Tool inputs stay out even here.
    run ! grep -q "run tests" "$RUN_DIR/prompt.md"
}

@test "heads-up: .done is written after result.json is complete" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    wait_done
    jq -e . "$RUN_DIR/result.json" > /dev/null
    [ ! -e "$RUN_DIR/result.json.tmp" ]
    # Modification order, to the nanosecond where stat offers it.
    [ ! "$RUN_DIR/.done" -ot "$RUN_DIR/result.json" ]
}

@test "heads-up: codex says none and the check is none" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-none
    start_runner codex
    wait_done
    [ "$(result .kind)" = "none" ]
    [ "$(result '[.seats[] | .seat + " " + .outcome] | join(",")')" = "codex none" ]
    [ "$(result 'has("headline") or has("seat")')" = "false" ]
    [ "$(result .bytes)" = "$(wc -c < "$RUN_DIR/prompt.md" | tr -d ' ')" ]
}

@test "heads-up: a text seat says NONE. and the check is none" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-none
    start_runner antigravity
    wait_done
    [ "$(result .kind)" = "none" ]
    [ "$(result '[.seats[] | .seat + " " + .outcome] | join(",")')" = "antigravity none" ]
}

@test "heads-up: codex hangs past the seat deadline, the timeout is recorded and codex is ended" {
    # An odd sleep length, so the check below cannot match another test's fake.
    export COUNCIL_HEADS_UP_SEAT_SECONDS=2 COUNCIL_FAKE_SLEEP=297
    export COUNCIL_FAKE_BEHAVIOR=hang
    start_runner codex
    wait_done 20
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats | length')" = "1" ]
    [ "$(result '.seats[0] | .seat + " " + .outcome + " " + .detail')" = "codex timeout no answer in 2s" ]
    run ! pgrep -f "sleep 297"
}

@test "heads-up: a seat whose wrapper obeys TERM but whose child ignores it is still ended by the deadline" {
    export COUNCIL_HEADS_UP_SEAT_SECONDS=2 COUNCIL_FAKE_SLEEP=311
    export COUNCIL_FAKE_BEHAVIOR=hang-orphan
    start_runner codex
    wait_done 20
    [ "$(result '.seats[0] | .seat + " " + .outcome')" = "codex timeout" ]
    run ! pgrep -f "sleep 311"
}

@test "heads-up: codex exiting 0 without turn.completed is an error, never a note" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-no-turn
    start_runner codex
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats[0] | .outcome + " " + .detail')" = "error exit 0 without turn.completed: codex: interrupted" ]
    [ "$(result 'has("headline")')" = "false" ]
}

@test "heads-up: a codex answer that fits the schema but says nothing is an error" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-blank
    start_runner codex
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats[0] | .outcome + " " + .detail')" = "error none false with an empty topic or headline" ]
}

@test "heads-up: codex erroring is kind failed, with its reason" {
    export COUNCIL_FAKE_BEHAVIOR=error
    start_runner codex
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats[0] | .seat + " " + .outcome + " " + .detail')" = "codex error exit 1 without turn.completed: Error: fake provider failure" ]
}

@test "heads-up: a text seat erroring is kind failed, with its exit status and the end of its stderr" {
    export COUNCIL_FAKE_BEHAVIOR=error
    start_runner antigravity
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats[0] | .seat + " " + .outcome')" = "antigravity error" ]
    [ "$(result '.seats[0].detail | startswith("exit 1: ")')" = "true" ]
    [ "$(result '.seats[0].detail | length > 8')" = "true" ]
}

@test "heads-up: an off-contract text reply is an error, never a note, even holding a NOTE: line" {
    export COUNCIL_FAKE_BEHAVIOR=off-contract
    start_runner antigravity
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result '.seats[0] | .outcome + " " + .detail')" = "error off contract: Here is a thought worth raising." ]
    [ "$(result 'has("headline")')" = "false" ]
}

@test "heads-up: a session with no transcript is kind failed, saying so" {
    rm -f "$TRANSCRIPT"
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    [ "$status" -eq 0 ]
    wait_done
    [ "$(result .kind)" = "failed" ]
    [ "$(result .bytes)" = "0" ]
    [ "$(result '.seats | length')" = "0" ]
    [ "$(result '.detail | startswith("transcript: ")')" = "true" ]
    [ ! -f "$COUNCIL_FAKE_STATE_DIR/calls.jsonl" ]
}

@test "heads-up: a transcript with nothing to review is kind skipped, saying so, and asks no seat" {
    # A teammate pane or an SDK-driven session: nobody typed, nothing to warn.
    jq -nc '{type:"assistant", message:{id:"msg_1", content:[{type:"text", text:"working"}]}}' > "$TRANSCRIPT"
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    [ "$status" -eq 0 ]
    wait_done
    [ "$(result .kind)" = "skipped" ]
    [ "$(result .detail)" = "digest: nothing in the window to review" ]
    [ "$(result .bytes)" = "0" ]
    [ "$(result '.seats | length')" = "0" ]
    [ ! -f "$COUNCIL_FAKE_STATE_DIR/calls.jsonl" ]
}

@test "heads-up: a conversation a mod opened for the person is checked like a typed one" {
    {
        jq -nc '{type:"user", isMeta:false, origin:{kind:"plugin", name:"cs"},
                 message:{content:"<command-name>/clear</command-name>"}}'
        jq -nc '{type:"assistant", message:{id:"msg_1", content:[{type:"text", text:"migrating the orders table"}]}}'
    } > "$TRANSCRIPT"
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    start_runner codex
    wait_done
    [ "$(result .kind)" = "note" ]
    [[ "$(cat "$RUN_DIR/digest.md")" == *"migrating the orders table"* ]]
}

@test "heads-up: a malformed deadline is refused before the fork" {
    export COUNCIL_HEADS_UP_SEAT_SECONDS=60s
    start_runner codex
    [ "$status" -eq 1 ]
    [ "$output" = "Error: COUNCIL_HEADS_UP_SEAT_SECONDS needs a whole number, got: 60s" ]
    [ ! -f "$RUN_DIR/pid" ]
}

@test "heads-up: --model sets the seat's model through its own variable and codex's effort through -c" {
    export COUNCIL_FAKE_BEHAVIOR=heads-up-note
    printf '%s\n' '{"model": "gpt-test-pick", "effort": "high"}' > "$RUN_DIR/model.json"
    start_runner codex --model "$RUN_DIR/model.json"
    [ "$status" -eq 0 ]
    wait_done
    [ "$(result .kind)" = "note" ]
    [ "$(result .model)" = "gpt-test-pick" ]
    local codex_args
    codex_args=$(jq -c '.args' "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    [ "$(jq -r 'index("-m") as $i | .[$i + 1]' <<< "$codex_args")" = "gpt-test-pick" ]
    [ "$(jq -r 'index("-c") as $i | .[$i + 1]' <<< "$codex_args")" = 'model_reasoning_effort="high"' ]
}

@test "heads-up: a --model effort that is not lowercase letters is refused before the fork" {
    printf '%s\n' '{"effort": "hi gh"}' > "$RUN_DIR/model.json"
    start_runner codex --model "$RUN_DIR/model.json"
    [ "$status" -eq 1 ]
    [ "$output" = "Error: --model: effort must be lowercase letters, got: hi gh" ]
    [ ! -f "$RUN_DIR/pid" ]
}
