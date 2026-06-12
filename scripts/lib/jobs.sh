#!/bin/bash
# ABOUTME: Persistent job store for background council runs
# ABOUTME: One <id>.json + <id>.log per job in a per-workspace state directory

# State directory resolution: explicit override, else plugin data dir, else
# tmp - namespaced by a hash of the workspace root so concurrent projects
# never share job state.
jobs_state_dir() {
    local dir="${COUNCIL_JOBS_DIR:-}"
    if [[ -z "$dir" ]]; then
        local root="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/claude-council}"
        local hash
        hash=$(pwd | shasum -a 256 | cut -c1-16)
        dir="${root}/jobs/${hash}"
    fi
    mkdir -p "$dir"
    echo "$dir"
}

job_file() { echo "$(jobs_state_dir)/$1.json"; }
job_log()  { echo "$(jobs_state_dir)/$1.log"; }

jobs_generate_id() {
    echo "council-$(date +%s)-$$-${RANDOM}"
}

# Create or update a job record. Sets status and updated_at; created_at is
# written once and preserved on later calls.
# Usage: job_write <id> <status>
job_write() {
    local id="$1" status="$2"
    local file now tmp
    file=$(job_file "$id")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp)
    local existing='{}'
    [[ -f "$file" ]] && existing=$(cat "$file")
    echo "$existing" | jq --arg id "$id" --arg status "$status" --arg now "$now" '
        . + {id: $id, status: $status, updated_at: $now}
        | if .created_at then . else . + {created_at: $now} end
    ' > "$tmp" && mv "$tmp" "$file"
}

# Set one string field on an existing job record.
# Usage: job_set <id> <key> <value>
job_set() {
    local id="$1" key="$2" value="$3"
    local file tmp
    file=$(job_file "$id")
    tmp=$(mktemp)
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

job_status() {
    local file
    file=$(job_file "$1")
    [[ -f "$file" ]] || return 1
    jq -r '.status' "$file"
}

# One line per job: id, status, created_at - newest first.
jobs_list() {
    local dir f
    dir=$(jobs_state_dir)
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        jq -r '[.id, .status, .created_at // ""] | @tsv' "$f"
    done | sort -t $'\t' -k3 -r
}

# Drop the oldest terminal-status jobs beyond COUNCIL_MAX_JOBS. Queued and
# running jobs are never pruned regardless of age.
jobs_prune() {
    local max="${COUNCIL_MAX_JOBS:-20}"
    local dir f status
    dir=$(jobs_state_dir)
    ls -t "$dir"/*.json 2>/dev/null | tail -n +$((max + 1)) | while read -r f; do
        status=$(jq -r '.status' "$f" 2>/dev/null || echo "")
        case "$status" in
            queued|running) continue ;;
        esac
        rm -f "$f" "${f%.json}.log"
    done
}

# Terminate a process and all of its descendants, leaves first.
kill_tree() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}
