#!/bin/bash
# ABOUTME: Queries the xAI Grok CLI in headless single-turn mode using subscription auth
# ABOUTME: Availability is gated on the grok binary being on PATH, not an API key

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

if ! command -v grok >/dev/null 2>&1; then
    echo "Error: grok CLI not found on PATH" >&2
    exit 1
fi

# grok narrates a plan and goes exploring the workspace unless pinned inline —
# see INLINE_ANSWER_GUARD in lib/verbosity.sh.
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${INLINE_ANSWER_GUARD}

${SYSTEM}

${PROMPT}"

# -p: single-turn prompt — grok prints the answer to stdout and exits, no TUI.
# --output-format plain: bare text, so the response needs no JSON unwrapping.
# --deny '*' --no-subagents: every tool call is refused at grok's permission
# layer and no subagent can be spawned, so a model-generated file write or
# shell from an adversarial prompt has nowhere to go; the council only reads
# stdout. (--tools '' and --permission-mode plan do not stop a tool call.)
# --sandbox read-only: grok's own read-only OS profile on top of that, as
# codex's -s read-only and agy's --sandbox. grok refuses to start at all when
# it cannot apply the profile (1.0.46 does while /var/run/docker.sock is a
# symlink, which Docker Desktop makes it), and that refusal alone ("could not
# apply the ... sandbox profile ... Refusing to start") earns one retry on the
# deny rules only, below. A sandbox warning beside any other failure does not.
# --no-plan disables plan mode structurally: without it grok can answer a
# complex prompt with only its plan narration. The prompt guard still covers
# non-plan tool use.
ARGS=(-p "$FULL_PROMPT" --output-format plain --no-plan --deny '*' --no-subagents)
SANDBOX=(--sandbox read-only)
# grok imports the user's Claude Code and Cursor configuration unless told
# otherwise: their hooks run inside the seat (a Claude SessionStart hook then
# rebinds the user's session state to grok's session id), their CLAUDE.md
# and rules shape the answer, and their skills, agents and MCP servers load.
# No flag turns that off; grok 1.0.46 reads these variables (`grok inspect`
# then lists each surface as disabled by env). grok's own ~/.grok config
# still applies. Exported, not set on argv, so they bind the retry below too.
for vendor in CLAUDE CURSOR; do
    for surface in SKILLS RULES AGENTS MCPS HOOKS SESSIONS; do
        export "GROK_${vendor}_${surface}_ENABLED=0"
    done
done
# -m only on an explicit override: the CLI's default model differs by auth
# mode, and a pinned id is rejected ("unknown model id") under XAI_API_KEY
# env auth, so an unset GROK_CLI_MODEL defers to the CLI's own default.
[[ -n "${GROK_CLI_MODEL:-}" ]] && ARGS+=(-m "$GROK_CLI_MODEL")

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-grok-cli-err.XXXXXX")
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(run_with_deadline "$COUNCIL_TIMEOUT" grok "${ARGS[@]}" "${SANDBOX[@]}" 2>"$ERR_TMP"); then rc=0; else rc=$?; fi
if [[ $rc -ne 0 && $rc -ne 143 ]] && grep -q "sandbox profile.*Refusing to start" "$ERR_TMP"; then
    if RESPONSE=$(run_with_deadline "$COUNCIL_TIMEOUT" grok "${ARGS[@]}" 2>"$ERR_TMP"); then rc=0; else rc=$?; fi
fi
if [[ $rc -eq 0 ]]; then
    echo "$RESPONSE"
else
    cli_failure_message "grok" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
