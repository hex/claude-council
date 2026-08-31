#!/bin/bash
# ABOUTME: Queries the OpenAI Codex CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the codex binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"

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

if ! command -v codex >/dev/null 2>&1; then
    echo "Error: codex CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# --skip-git-repo-check: codex refuses to run from non-trusted dirs as a
# safety guard for interactive sessions; for headless `exec` we only read
# stdout, so the check is pure friction.
# -s read-only: the council only reads stdout, so pin a read-only sandbox
# rather than inherit a permissive ~/.codex/config.toml default — a defense
# against model-generated shell from an adversarial prompt (mirrors agy's
# --sandbox guard).
ARGS=(exec --skip-git-repo-check -s read-only)
# -m only on an explicit override: a pinned id would override the model the
# user configured in ~/.codex/config.toml, so an unset CODEX_MODEL defers to
# the CLI's own resolution (mirrors grok-cli.sh).
[[ -n "${CODEX_MODEL:-}" ]] && ARGS+=(-m "$CODEX_MODEL")
ARGS+=("$FULL_PROMPT")

# Bound the CLI the way API providers are bounded by curl --max-time:
# run_with_deadline ends it after COUNCIL_TIMEOUT seconds, surfacing as exit
# 143 (128 + SIGTERM).
# One attempt, where the API providers retry — see COUNCIL_CLI_TIMEOUT in
# docs/ARCHITECTURE.md for why the two defaults differ.
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-${COUNCIL_CLI_TIMEOUT:-1200}}"

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(run_with_deadline "$COUNCIL_TIMEOUT" codex "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 143 ]]; then
        echo "Error from codex CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from codex CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
