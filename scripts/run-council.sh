#!/bin/bash
# ABOUTME: Wrapper script that runs council query and saves to timestamped file
# ABOUTME: Sync by default; --async detaches a tracked job with --result/--jobs/--cancel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/jobs.sh"

# Resolve the jobs state dir once in this process so the command-substitution
# subshells in job_file/job_log inherit the memoized value instead of re-forking
# a hash on every call.
jobs_state_dir >/dev/null

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
# On success echoes the output file path for Claude to read. On failure prints
# query-council's real diagnostics (captured to a log, not discarded), removes
# the empty transcript, and returns non-zero so callers — including the async
# worker's `outfile=$(run_sync ...)` under set -e — don't mistake failure for a
# completed run with an empty artifact.
run_sync() {
    local name="${1:-council-$(date +%s)}"
    local outdir=".claude/council-cache"
    local outfile="${outdir}/${name}.md"
    local logfile="${outdir}/${name}.log"
    mkdir -p "$outdir"
    # Guarded by `if` so pipefail-driven failure is handled here rather than
    # tripping set -e before we can surface the cause.
    if bash "${SCRIPT_DIR}/query-council.sh" "${PASS[@]+"${PASS[@]}"}" 2>"$logfile" \
        | bash "${SCRIPT_DIR}/format-output.sh" > "$outfile"; then
        rm -f "$logfile"
        echo "$outfile"
    else
        echo "Council query failed:" >&2
        tail -n 20 "$logfile" >&2 2>/dev/null || true
        rm -f "$outfile" "$logfile"
        return 1
    fi
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
    # Read fields individually: an empty middle field (no outfile yet) would be
    # swallowed by read's collapsing of consecutive tab (IFS-whitespace) delimiters.
    local status outfile pid
    status=$(jq -r '.status' "$file")
    outfile=$(jq -r '.outfile // ""' "$file")
    pid=$(jq -r '.pid // ""' "$file")
    case "$status" in
        completed)
            echo "$outfile"
            ;;
        queued|running)
            # A worker killed by SIGKILL/reboot never ran its EXIT trap, so the
            # record is stuck at running with a dead pid. Reap it to failed so
            # /result doesn't poll a zombie forever and jobs_prune can reclaim it.
            if [[ "$status" == running && -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                job_write "$JOB_ID" failed
                echo "Job $JOB_ID failed: worker (pid $pid) is no longer running." >&2
                tail -5 "$(job_log "$JOB_ID")" >&2 2>/dev/null || true
                exit 1
            fi
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
