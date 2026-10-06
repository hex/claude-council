#!/bin/bash
# ABOUTME: Queries Claude Code itself in a blind headless session using subscription auth
# ABOUTME: Never seated by discovery; it joins only when named in --providers or COUNCIL_PROVIDERS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"
source "$SCRIPT_DIR/../lib/cli-stderr.sh"

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

if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# The seat must answer the prompt every other seat gets and nothing else, so
# it starts blind to the user's setup:
# --safe-mode: no CLAUDE.md, skills, plugins, hooks or MCP servers, so neither
# the user's memory nor any plugin's Stop hook (this one's included) runs.
# --setting-sources "": safe mode still reads the user's settings.json
# (language and the like); this drops every settings file. Admin policy and
# an org's server-side instructions still apply, and no flag removes them.
# --tools "": the prompt can carry --file contents or another seat's answer,
# so the seat gets no tool to act on them with.
# --no-session-persistence: nothing of the run lands in the user's history.
# A bare -p reads the prompt from stdin, which keeps the whole prompt off argv
# (see cursor-cli.sh for the argument limit this avoids).
ARGS=(-p --safe-mode --setting-sources "" --tools "" --no-session-persistence --output-format text)
# --model only on an explicit override, so an unset CLAUDE_CLI_MODEL defers to
# the account's default model (mirrors codex.sh and cursor-cli.sh).
[[ -n "${CLAUDE_CLI_MODEL:-}" ]] && ARGS+=(--model "$CLAUDE_CLI_MODEL")

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-claude-cli-err.XXXXXX")
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/council-claude-cli-out.XXXXXX")
trap 'rm -f "$ERR_TMP" "$OUT_TMP"' EXIT

if printf '%s' "$FULL_PROMPT" | run_with_deadline "$COUNCIL_TIMEOUT" claude "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then
    if ! grep -q '[^[:space:]]' "$OUT_TMP"; then
        echo "Error from claude CLI: no answer in response" >&2
        exit 1
    fi
    cat "$OUT_TMP"
else
    cli_failure_message "claude" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
