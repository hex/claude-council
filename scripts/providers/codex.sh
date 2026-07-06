#!/bin/bash
# ABOUTME: Queries the OpenAI Codex CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the codex binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

PROMPT="${1:-}"

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

MODEL=$(get_model codex)
# --skip-git-repo-check: codex refuses to run from non-trusted dirs as a
# safety guard for interactive sessions; for headless `exec` we only read
# stdout, so the check is pure friction.
# -s read-only: the council only reads stdout, so pin a read-only sandbox
# rather than inherit a permissive ~/.codex/config.toml default — a defense
# against model-generated shell from an adversarial prompt (mirrors agy's
# --sandbox guard).
ARGS=(exec --skip-git-repo-check -s read-only -m "$MODEL" "$FULL_PROMPT")

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" codex "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 142 ]]; then
        echo "Error from codex CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from codex CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
