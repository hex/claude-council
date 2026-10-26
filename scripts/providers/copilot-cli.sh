#!/bin/bash
# ABOUTME: Queries the GitHub Copilot CLI in a headless, tool-less session using subscription auth
# ABOUTME: Never seated by discovery; it joins only when named in --providers or COUNCIL_PROVIDERS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"
source "$SCRIPT_DIR/../lib/cli-stderr.sh"
source "$SCRIPT_DIR/../lib/usage.sh"
source "$SCRIPT_DIR/../lib/seat-isolation.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

PROMPT="${1:-}"
# A large prompt (e.g. a big --file) arrives via a temp file to stay off
# the process argv, where the OS would reject it as "argument list too long".
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT=$(cat "${2:?--prompt-file requires a path}")
fi

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

if ! command -v copilot >/dev/null 2>&1; then
    echo "Error: copilot CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# The seat must answer the prompt every other seat gets and nothing else, and
# the CLI has no single switch for that, so it is built from flags:
# --no-custom-instructions: no AGENTS.md or related instruction files, so a
# project's instructions never reach the seat.
# --disable-builtin-mcps: the GitHub MCP server never connects.
# --available-tools=none: an allowlist naming no real tool leaves the model
# with none, built-in or MCP; the prompt can carry --file contents or another
# seat's answer, so the seat gets no tool to act on them with. An empty list
# is read as no allowlist at all. The CLI notes the unknown name on stdout,
# which the parse below skips.
# --no-auto-update: a seat run never downloads a CLI update.
# --output-format json: JSONL events; the answer is the assistant.message
# content, which is what tells an answer from a run that printed none.
# The prompt arrives on stdin, which keeps the whole prompt off argv (see
# cursor-cli.sh for the argument limit this avoids).
# What no flag removes: MCP servers in the user's mcp-config.json still start,
# though the model is handed none of their tools, and each run is saved in the
# user's session history. An empty COPILOT_HOME would drop both, but it also
# drops the login a machine without a credential store keeps as a plain file
# there, so the seat keeps the user's COPILOT_HOME. The login itself may be the
# GitHub CLI's, which copilot reads by running gh from PATH.
ARGS=(--output-format json --no-auto-update --no-custom-instructions --disable-builtin-mcps --available-tools=none)
# --model only on an explicit override, so an unset COPILOT_CLI_MODEL defers to
# the CLI's own choice (mirrors claude-cli.sh and cursor-cli.sh). A plan may
# offer no model by name, and the CLI's own message then says so.
[[ -n "${COPILOT_CLI_MODEL:-}" ]] && ARGS+=(--model "$COPILOT_CLI_MODEL")
# The scratch working directory (lib/seat-isolation.sh) keeps out the
# project's skills, hooks and .github files, which --no-custom-instructions
# leaves in. The skills under the user's ~/.copilot and ~/.agents still load
# (see above for why the seat keeps the user's home).
seat_enter_scratch || exit 1

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-copilot-cli-err.XXXXXX")
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/council-copilot-cli-out.XXXXXX")
trap 'rm -f "$ERR_TMP" "$OUT_TMP"' EXIT

if printf '%s' "$FULL_PROMPT" | run_with_deadline "$COUNCIL_TIMEOUT" copilot "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then rc=0; else rc=$?; fi
# One assistant.usage event per model request, summed. Its inputTokens count
# the cache reads and writes; reasoningTokens are part of outputTokens.
emit_usage -nR 'def total(f): [.[] | f | numbers] | if length == 0 then null else add end;
    [inputs | fromjson? | objects | select(.type == "assistant.usage") | .data | objects]
    | select(length > 0)
    | {input: total(.inputTokens), cached: total(.cacheReadTokens), output: total(.outputTokens), reasoning: total(.reasoningTokens)}' "$OUT_TMP"
if [[ $rc -eq 0 ]]; then
    # One event per line, the last assistant message with content being the
    # answer. A line that is not a JSON object is skipped rather than aborting
    # under set -e.
    RESPONSE=$(jq -R -n -r '[inputs | fromjson? | objects | select(.type == "assistant.message")
                             | .data.content | strings | select(test("\\S"))]
                             | last // empty' "$OUT_TMP" 2>/dev/null || true)
    if [[ ! "$RESPONSE" =~ [^[:space:]] ]]; then
        echo "Error from copilot CLI: no answer in response" >&2
        exit 1
    fi
    echo "$RESPONSE"
else
    # A logged-out CLI exits 1 with "Error: No authentication information
    # found." and the ways to log in; that stderr is what this reports.
    cli_failure_message "copilot" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
