#!/usr/bin/env bats
# ABOUTME: Tests for lib/jobs.sh job store and run-council.sh async execution
# ABOUTME: Hermetic: fake CLIs serve the providers, COUNCIL_JOBS_DIR isolates state

load test_helper
load fixtures/fake-clis

RUN_COUNCIL="${SCRIPTS_DIR}/run-council.sh"
JOBS_LIB="${LIB_DIR}/jobs.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    export COUNCIL_JOBS_DIR="${BATS_TEST_TMPDIR}/jobs"
    unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY XAI_API_KEY PERPLEXITY_API_KEY
    # run-council writes its outfile relative to CWD
    cd "$BATS_TEST_TMPDIR"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# Poll a job until it reaches a terminal status or the deadline passes
wait_for_job() {
    local id="$1" deadline=$((SECONDS + 20)) status
    while (( SECONDS < deadline )); do
        status=$(jq -r .status "${COUNCIL_JOBS_DIR}/${id}.json" 2>/dev/null || echo "")
        case "$status" in
            completed|failed|cancelled) echo "$status"; return 0 ;;
        esac
        sleep 0.5
    done
    echo "timeout:$status"
    return 1
}

# ============================================================================
# lib/jobs.sh unit behavior
# ============================================================================

@test "jobs: generated ids are unique" {
    source "$JOBS_LIB"
    local a b
    a=$(jobs_generate_id)
    b=$(jobs_generate_id)
    [[ -n "$a" && "$a" != "$b" ]]
}

@test "jobs: job_write creates record with status and timestamps" {
    source "$JOBS_LIB"
    job_write myjob queued
    run jq -r '.status' "${COUNCIL_JOBS_DIR}/myjob.json"
    [ "$output" == "queued" ]
    run jq -e '.created_at and .updated_at' "${COUNCIL_JOBS_DIR}/myjob.json"
    [ "$status" -eq 0 ]
}

@test "jobs: job_write preserves created_at across status updates" {
    source "$JOBS_LIB"
    job_write myjob queued
    local created
    created=$(jq -r '.created_at' "${COUNCIL_JOBS_DIR}/myjob.json")
    job_write myjob running
    run jq -r '.created_at' "${COUNCIL_JOBS_DIR}/myjob.json"
    [ "$output" == "$created" ]
    run jq -r '.status' "${COUNCIL_JOBS_DIR}/myjob.json"
    [ "$output" == "running" ]
}

@test "jobs: job_set stores arbitrary string fields" {
    source "$JOBS_LIB"
    job_write myjob queued
    job_set myjob outfile "/some/path.md"
    run jq -r '.outfile' "${COUNCIL_JOBS_DIR}/myjob.json"
    [ "$output" == "/some/path.md" ]
}

@test "jobs: jobs_prune keeps newest records and never prunes running jobs" {
    source "$JOBS_LIB"
    export COUNCIL_MAX_JOBS=2
    job_write old1 completed; sleep 1
    job_write old2 running;   sleep 1
    job_write new1 completed
    job_write new2 completed
    jobs_prune
    # old1 (oldest terminal) pruned; old2 survives because it is running
    [[ ! -f "${COUNCIL_JOBS_DIR}/old1.json" ]]
    [[ -f "${COUNCIL_JOBS_DIR}/old2.json" ]]
    [[ -f "${COUNCIL_JOBS_DIR}/new1.json" ]]
    [[ -f "${COUNCIL_JOBS_DIR}/new2.json" ]]
}

# ============================================================================
# run-council.sh async lifecycle
# ============================================================================

@test "run-council --async: prints a job id and detaches" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$RUN_COUNCIL" --async --providers=codex -- "test question"
    [ "$status" -eq 0 ]
    local id
    id=$(echo "$output" | head -1)
    [[ "$id" == council-* ]]
    [[ -f "${COUNCIL_JOBS_DIR}/${id}.json" ]]
}

@test "run-council --async: job completes and result returns the outfile" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    local id
    id=$(bash "$RUN_COUNCIL" --async --providers=codex -- "test question" | head -1)
    run wait_for_job "$id"
    [ "$output" == "completed" ]
    run bash "$RUN_COUNCIL" --result="$id"
    [ "$status" -eq 0 ]
    local outfile="$output"
    [[ -f "$outfile" ]]
    grep -q "FAKE-CODEX-RESPONSE" "$outfile"
}

@test "run-council --result: still-running job exits 2" {
    export COUNCIL_FAKE_BEHAVIOR=slow
    export COUNCIL_FAKE_SLEEP=15
    local id
    id=$(bash "$RUN_COUNCIL" --async --providers=codex -- "test question" | head -1)
    run bash "$RUN_COUNCIL" --result="$id"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still"* ]]
    bash "$RUN_COUNCIL" --cancel="$id" || true
}

@test "run-council --result: unknown job errors clearly" {
    run bash "$RUN_COUNCIL" --result=council-doesnotexist
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown job"* ]]
}

@test "run-council --jobs: lists job ids with status" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    local id
    id=$(bash "$RUN_COUNCIL" --async --providers=codex -- "test question" | head -1)
    wait_for_job "$id"
    run bash "$RUN_COUNCIL" --jobs
    [ "$status" -eq 0 ]
    [[ "$output" == *"$id"* ]]
    [[ "$output" == *"completed"* ]]
}

@test "run-council --cancel: kills a running job and marks it cancelled" {
    export COUNCIL_FAKE_BEHAVIOR=slow
    export COUNCIL_FAKE_SLEEP=30
    local id
    id=$(bash "$RUN_COUNCIL" --async --providers=codex -- "test question" | head -1)
    sleep 1
    run bash "$RUN_COUNCIL" --cancel="$id"
    [ "$status" -eq 0 ]
    run jq -r '.status' "${COUNCIL_JOBS_DIR}/${id}.json"
    [ "$output" == "cancelled" ]
    # The worker process must actually be gone
    local pid
    pid=$(jq -r '.pid // empty' "${COUNCIL_JOBS_DIR}/${id}.json")
    if [[ -n "$pid" ]]; then
        sleep 1
        ! kill -0 "$pid" 2>/dev/null
    fi
}

@test "run-council: sync mode without flags is unchanged" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run bash "$RUN_COUNCIL" --providers=codex -- "test question"
    [ "$status" -eq 0 ]
    [[ -f "$output" ]]
    grep -q "FAKE-CODEX-RESPONSE" "$output"
}
