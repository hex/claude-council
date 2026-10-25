#!/bin/bash
# ABOUTME: Queries the OpenCode CLI in a blind headless run on whichever provider the user logged it in to
# ABOUTME: Never seated by discovery; it joins only when named in --providers or COUNCIL_PROVIDERS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"
source "$SCRIPT_DIR/../lib/cli-stderr.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

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

if ! command -v opencode >/dev/null 2>&1; then
    echo "Error: opencode CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-opencode-err.XXXXXX")
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/council-opencode-out.XXXXXX")
CONFIG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/council-opencode-config.XXXXXX")
SESSION_ID=""
# The CLI saves every run in the user's session history and no flag stops it,
# so the seat deletes its own session: the prompt can carry --file contents or
# a transcript digest. Best effort and bounded; it never changes the exit code.
remove_run() {
    if [[ -n "$SESSION_ID" ]]; then
        run_with_deadline 30 opencode session delete --standalone "$SESSION_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$ERR_TMP" "$OUT_TMP" "$CONFIG_TMP"
}
trap remove_run EXIT

# The seat must answer the prompt every other seat gets and nothing else, so
# it starts blind to the user's setup:
# OPENCODE_CONFIG_DIR, an empty directory: none of the user's global config,
# MCP servers, plugins, agents or commands load. The login in auth.json lives
# under XDG_DATA_HOME, not here, so the seat keeps it.
# OPENCODE_DISABLE_PROJECT_CONFIG: no opencode.json or AGENTS.md from the
# working directory reaches the seat.
# OPENCODE_CONFIG_CONTENT denying every permission: the CLI then sends the
# model no tool at all, and the prompt can carry --file contents or another
# seat's answer, so the seat gets no tool to act on them with. OPENCODE_PERMISSION
# is ignored by 2.1.3, so the deny rides the inline config instead. A model that
# asks for a tool anyway fails (Gemini answers UNEXPECTED_TOOL_CALL), and that
# arrives as an error event, reported below.
# The council's environment scrub keeps only the OPENCODE_ family here, so no
# vendor's API key reaches the seat and it runs on the `opencode auth login`
# credentials; COUNCIL_PASS_ENV names any key it should keep.
# The empty config dir also hides the model the user picked, so get_model reads
# it first and the seat passes it as -m below.
# OPENCODE_CONFIG, a config file the CLI loads on top of any config dir, is
# unset for the same reason as the empty dir.
MODEL="$(get_model opencode)"
unset OPENCODE_CONFIG
export OPENCODE_CONFIG_DIR="$CONFIG_TMP"
export OPENCODE_DISABLE_PROJECT_CONFIG=1
export OPENCODE_CONFIG_CONTENT='{"permission":{"*":"deny"}}'

# --standalone: a private server for this run. Without it the run goes to the
# user's background service, which holds the environment and config it was
# started with, so neither the isolation above nor the council's environment
# scrub would reach it, and parallel seats would share one process.
# --format json: one event per line, the answer in each "text" event's
# .part.text; the default format adds a "> build · provider/model" header.
# No message argument: the prompt arrives on stdin, which keeps the whole
# prompt off argv (see cursor-cli.sh for the argument limit this avoids).
ARGS=(run --standalone --format json)
# -m carries OPENCODE_MODEL, else the model in the user's own config; with
# neither, get_model says "default" and the CLI picks its built-in model. The
# value is provider/model, as the CLI names models.
[[ "$MODEL" != default ]] && ARGS+=(-m "$MODEL")

if printf '%s' "$FULL_PROMPT" | run_with_deadline "$COUNCIL_TIMEOUT" opencode "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then rc=0; else rc=$?; fi
# Every event names the run's session; the first one is enough. Only a plain
# word is kept, so nothing the stream says can reach the delete as a flag.
SESSION_ID=$(jq -rnR 'first(inputs | fromjson? | objects | .sessionID // empty
                            | strings | select(test("^[A-Za-z0-9_]+$")))' "$OUT_TMP" 2>/dev/null || true)
# A provider error or an unknown model exits 1 with stderr empty: the cause is
# an error event on stdout. Line by line rather than slurped, so a notice line
# that is not JSON cannot abort the parse. The .error type is checked before
# it is indexed, so an error event of another shape still reads as an error.
STREAM_ERROR=$(jq -rnR '
    [ inputs
      | fromjson?
      | select(type == "object" and .type == "error")
      | (.error | if type == "object" then (.message // .type) else . end)
        // "error event with no message"
      | tostring
    ] | join(" ") | gsub("[\\r\\n]+"; " ")' "$OUT_TMP" 2>/dev/null || true)
if [[ $rc -eq 0 && -z "$STREAM_ERROR" ]]; then
    RESPONSE=$(jq -rnR '
        [ inputs
          | fromjson?
          | select(type == "object" and .type == "text")
          | .part.text // empty
        ] | join("")' "$OUT_TMP" 2>/dev/null || true)
    if [[ ! "$RESPONSE" =~ [^[:space:]] ]]; then
        echo "Error from opencode CLI: no answer in response" >&2
        exit 1
    fi
    echo "$RESPONSE"
elif [[ $rc -ne 143 && -n "$STREAM_ERROR" ]]; then
    echo "Error from opencode CLI: ${STREAM_ERROR}" >&2
    exit 1
else
    cli_failure_message "opencode" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
