#!/bin/bash
# ABOUTME: Opt-in Stop hook asking a council provider to review the uncommitted diff
# ABOUTME: Emits {"decision":"block"} only when enabled, loop-guarded, and the reviewer says BLOCK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVENT=$(cat)

# Off unless the project explicitly opts in
CONFIG=".claude/council-stop-gate.json"
[[ -f "$CONFIG" ]] || exit 0
jq -e '.enabled == true' "$CONFIG" >/dev/null 2>&1 || exit 0

# Guard 1: never re-gate a continuation already triggered by a stop hook
if [[ "$(echo "$EVENT" | jq -r '.stop_hook_active // false')" == "true" ]]; then
    exit 0
fi

# Guard 2: hard cap on blocks per session, persisted in the job state dir
SESSION_ID=$(echo "$EVENT" | jq -r '.session_id // "unknown"')
MAX_ITER=$(jq -r '.max_iterations // 1' "$CONFIG")
source "${SCRIPT_DIR}/lib/jobs.sh"
COUNTER="$(jobs_state_dir)/stop-gate-${SESSION_ID}.count"
COUNT=0
[[ -f "$COUNTER" ]] && COUNT=$(cat "$COUNTER")
if (( COUNT >= MAX_ITER )); then
    exit 0
fi

# Nothing to review on a clean tree
DIFF=$(git diff HEAD 2>/dev/null || true)
[[ -z "$DIFF" ]] && exit 0

PROVIDER=$(jq -r '.provider // "codex"' "$CONFIG")
PROVIDER_SCRIPT="${SCRIPT_DIR}/providers/${PROVIDER}.sh"
[[ -f "$PROVIDER_SCRIPT" ]] || exit 0

source "${SCRIPT_DIR}/lib/prompts.sh"
TEMPLATE=$(load_prompt_template stop-review-gate)
PROMPT=$(interpolate_template "$TEMPLATE" "DIFF=$DIFF")

# A reviewer failure must never trap the user at the stop
REVIEW=$(bash "$PROVIDER_SCRIPT" "$PROMPT" 2>/dev/null) || exit 0

FIRST_LINE=$(echo "$REVIEW" | head -1)
if [[ "$FIRST_LINE" == BLOCK:* ]]; then
    echo $((COUNT + 1)) > "$COUNTER"
    REASON=$(echo "$REVIEW" | head -c 1500)
    jq -n --arg r "Council stop-gate reviewer (${PROVIDER}): ${REASON}" \
        '{decision: "block", reason: $r}'
fi

exit 0
