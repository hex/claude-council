#!/bin/bash
# ABOUTME: Queries the Cursor agent CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the cursor-agent binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"
source "$SCRIPT_DIR/../lib/cli-stderr.sh"
source "$SCRIPT_DIR/../lib/usage.sh"
source "$SCRIPT_DIR/../lib/providers.sh"
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

# cursor-agent, not the bare `agent` the installer links beside it: the grok
# CLI ships an `agent` too, so that name could be either vendor.
if ! command -v cursor-agent >/dev/null 2>&1; then
    echo "Error: cursor-agent CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# --output-format json: one object, the answer in .result. The default text
# format is the same answer without the envelope, but the envelope is what
# tells a complete answer from a run that printed nothing.
# --mode ask: the read-only mode; -p on its own "has access to all tools,
# including write and shell", and would run them on a prompt that can carry
# --file contents or another provider's answer. Same intent as codex's
# -s read-only and kimi-cli's no-tools agent file. --force is never passed.
# --trust: headless runs otherwise stop to ask whether the workspace is trusted.
# A bare -p reads the prompt from stdin, which keeps the whole prompt off argv:
# a big --file would otherwise be handed to the orchestrator's --prompt-file
# only to land back on the command line, past the OS limit on Linux at about
# 128 KiB per argument. Verified against the real CLI with a 300 KB prompt.
ARGS=(-p --output-format json --mode ask --trust)
# The seat runs under a home of its own (lib/seat-isolation.sh): cursor-agent
# loads skills from ~/.cursor, ~/.claude (plugins included), ~/.codex, ~/.grok
# and ~/.agents, hooks from ~/.cursor/hooks.json and Claude's settings.json,
# MCP servers from ~/.cursor/mcp.json, and every root resolves through HOME.
# No flag or variable turns that off. The home holds only the login: macOS
# keeps it in the login keychain, found through ~/Library/Keychains; Linux in
# ${XDG_CONFIG_HOME:-~/.config}/cursor/auth.json (read from the CLI's bundle,
# not run on Linux). The scratch working directory keeps out the project's
# .cursor rules and MCP servers, AGENTS.md, CLAUDE.md and CLAUDE.local.md.
# The model picked in the CLI lives in the real home's ~/.cursor/cli-config.json,
# so it is read here first and passed as --model; with no pick and no
# CURSOR_CLI_MODEL, no --model at all: a free plan rejects every named model,
# and the CLI's own message says so.
MODEL="$(get_model cursor-cli)"
[[ "$MODEL" != default ]] && ARGS+=(--model "$MODEL")
case "$(seat_platform)" in
    macos) SEAT_HOME=$(seat_home cursor-cli Library/Keychains "$HOME/Library/Keychains") || exit 1 ;;
    linux) SEAT_HOME=$(seat_home cursor-cli .config/cursor "${XDG_CONFIG_HOME:-$HOME/.config}/cursor") || exit 1 ;;
    windows) SEAT_HOME="$HOME" ;;
esac
export HOME="$SEAT_HOME"
seat_enter_scratch || exit 1

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-cursor-cli-err.XXXXXX")
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/council-cursor-cli-out.XXXXXX")
trap 'rm -f "$ERR_TMP" "$OUT_TMP"' EXIT

if printf '%s' "$FULL_PROMPT" | run_with_deadline "$COUNCIL_TIMEOUT" cursor-agent "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then rc=0; else rc=$?; fi
# The result envelope's usage, line by line as the answer is read. Its
# inputTokens leave out the cache reads and writes, which are input too.
emit_usage -nR '[inputs | fromjson? | objects | select(.type == "result")] | last | .usage
    | select(.inputTokens != null)
    | {input: (.inputTokens + (.cacheReadTokens // 0) + (.cacheWriteTokens // 0)),
       cached: .cacheReadTokens, output: .outputTokens, reasoning: null}' "$OUT_TMP"
if [[ $rc -eq 0 ]]; then
    # Line by line rather than slurped, so an upgrade notice beside the
    # envelope cannot abort the parse and discard a complete answer.
    RESPONSE=$(jq -rnR '
        [ inputs
          | fromjson?
          | select(type == "object" and .type == "result")
          | .result // empty
        ] | join("")' "$OUT_TMP" 2>/dev/null || true)
    if [[ ! "$RESPONSE" =~ [^[:space:]] ]]; then
        echo "Error from cursor-agent CLI: no result in response" >&2
        exit 1
    fi
    echo "$RESPONSE"
else
    cli_failure_message "cursor-agent" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
