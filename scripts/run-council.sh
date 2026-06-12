#!/bin/bash
# ABOUTME: Wrapper script that runs council query and saves to timestamped file
# ABOUTME: Sync by default; --async detaches a tracked job with --result/--jobs/--cancel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/jobs.sh"

MODE=sync
JOB_ID=""
PASS=()
seen_dashdash=false
for arg in "$@"; do
    if [[ "$seen_dashdash" == true ]]; then
        PASS+=("$arg")
        continue
    fi
    case "$arg" in
        --)             seen_dashdash=true; PASS+=("$arg") ;;
        --async)        MODE=async ;;
        --job-worker=*) MODE=worker; JOB_ID="${arg#*=}" ;;
        --result=*)     MODE=result; JOB_ID="${arg#*=}" ;;
        --jobs)         MODE=list ;;
        --cancel=*)     MODE=cancel; JOB_ID="${arg#*=}" ;;
        *)              PASS+=("$arg") ;;
    esac
done

# Run query and format, saving to the named file under the cache dir.
# Echoes the output file path for Claude to read.
run_sync() {
    local name="${1:-council-$(date +%s)}"
    local outdir=".claude/council-cache"
    local outfile="${outdir}/${name}.md"
    mkdir -p "$outdir"
    bash "${SCRIPT_DIR}/query-council.sh" "${PASS[@]+"${PASS[@]}"}" 2>/dev/null \
        | bash "${SCRIPT_DIR}/format-output.sh" > "$outfile"
    echo "$outfile"
}

# Detach a worker for the same query and return immediately. Stdout is the
# job id (machine-readable); the fetch hint goes to stderr.
run_async() {
    JOB_ID=$(jobs_generate_id)
    job_write "$JOB_ID" queued
    job_set "$JOB_ID" args "${PASS[*]+"${PASS[*]}"}"
    nohup bash "$0" --job-worker="$JOB_ID" "${PASS[@]+"${PASS[@]}"}" \
        </dev/null >> "$(job_log "$JOB_ID")" 2>&1 &
    job_set "$JOB_ID" pid "$!"
    jobs_prune
    echo "$JOB_ID"
    echo "Background council job started. Fetch with: run-council.sh --result=${JOB_ID}" >&2
}

# Detached worker: runs the query under job tracking. Any exit while the
# record still says running (crash, kill) flips it to failed.
run_worker() {
    job_write "$JOB_ID" running
    job_set "$JOB_ID" pid "$$"
    trap 'if [[ "$(job_status "$JOB_ID" 2>/dev/null)" == "running" ]]; then job_write "$JOB_ID" failed; fi' EXIT
    local outfile
    outfile=$(run_sync "$JOB_ID")
    job_set "$JOB_ID" outfile "$outfile"
    job_write "$JOB_ID" completed
}

# Print the outfile path of a completed job (same contract as sync mode).
# Exit 2 while the job is in flight, exit 1 on unknown/failed/cancelled.
run_result() {
    local file
    file=$(job_file "$JOB_ID")
    if [[ ! -f "$file" ]]; then
        echo "Error: unknown job: $JOB_ID" >&2
        exit 1
    fi
    local status outfile
    IFS=$'\t' read -r status outfile < <(jq -r '[.status, .outfile // ""] | @tsv' "$file")
    case "$status" in
        completed)
            echo "$outfile"
            ;;
        queued|running)
            echo "Job $JOB_ID is still ${status}." >&2
            exit 2
            ;;
        *)
            echo "Job $JOB_ID ${status}." >&2
            tail -5 "$(job_log "$JOB_ID")" >&2 2>/dev/null || true
            exit 1
            ;;
    esac
}

run_list() {
    jobs_list
}

run_cancel() {
    local file
    file=$(job_file "$JOB_ID")
    if [[ ! -f "$file" ]]; then
        echo "Error: unknown job: $JOB_ID" >&2
        exit 1
    fi
    local status pid
    IFS=$'\t' read -r status pid < <(jq -r '[.status, .pid // ""] | @tsv' "$file")
    case "$status" in
        queued|running)
            # Mark first so the worker's exit trap sees a terminal status
            # and does not race it back to failed
            job_write "$JOB_ID" cancelled
            [[ -n "$pid" ]] && kill_tree "$pid"
            echo "Cancelled $JOB_ID"
            ;;
        *)
            echo "Job $JOB_ID is already ${status}."
            ;;
    esac
}

case "$MODE" in
    sync)   run_sync ;;
    async)  run_async ;;
    worker) run_worker ;;
    result) run_result ;;
    list)   run_list ;;
    cancel) run_cancel ;;
esac
