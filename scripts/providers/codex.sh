#!/bin/bash
# ABOUTME: Queries the OpenAI Codex CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the codex binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/deadline.sh"
source "$SCRIPT_DIR/../lib/cli-stderr.sh"
source "$SCRIPT_DIR/../lib/providers.sh"
source "$SCRIPT_DIR/../lib/codex-home.sh"
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

# codex runs under a CODEX_HOME of its own (lib/codex-home.sh), so none of
# the user's plugins, hooks, AGENTS.md, skills, memories or MCP servers ride
# along, with their login linked in and their model and effort copied. One
# home per run, removed with it: codex saves each session there, and the
# prompt can carry --file contents. The scratch working directory
# (lib/seat-isolation.sh) keeps a project's AGENTS.md and skills out too.
USER_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/council-codex-err.XXXXXX")
SEAT_CODEX_HOME=""
trap 'rm -rf "$ERR_TMP" ${SEAT_CODEX_HOME:+"$SEAT_CODEX_HOME"}' EXIT

# A login in the system keyring cannot follow codex into a home of its own:
# codex 0.164.0 names the keyring entry after a hash of the CODEX_HOME path
# (compute_store_key in its login/src/auth/storage.rs). With no file login and
# no API key to carry over, such a seat runs under the user's own home, as it
# did before seats were isolated, and says so on stderr, which the council
# shows above the answer. Any other missing login is refused below.
STORE=""
if [[ ! -f "${USER_CODEX_HOME}/auth.json" && -z "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ]]; then
    STORE=$(toml_value "${USER_CODEX_HOME}/config.toml" "" cli_auth_credentials_store)
fi
if [[ "$STORE" == keyring || "$STORE" == auto ]]; then
    echo "note: codex: login is in the system keyring, which a separate CODEX_HOME cannot read; running under your own ${USER_CODEX_HOME} (personal config loads, more tokens). Set cli_auth_credentials_store = \"file\" and run codex login again to isolate this seat." >&2
else
    SEAT_CODEX_HOME=$(mktemp -d "${TMPDIR:-/tmp}/council-codex-home.XXXXXX")
    if ! REASON=$(codex_seat_home "$SEAT_CODEX_HOME" "$USER_CODEX_HOME" "$ERR_TMP" stderr_excerpt); then
        echo "Error: $REASON" >&2
        exit 1
    fi
    export CODEX_HOME="$SEAT_CODEX_HOME"
fi
seat_enter_scratch || exit 1

# The prompt rides argv, and `codex exec` reads stdin whenever it is not a
# TTY: launched from a shell whose stdin stays open it would wait on it until
# the deadline, so it gets none.
if RESPONSE=$(run_with_deadline "$COUNCIL_TIMEOUT" codex "${ARGS[@]}" 2>"$ERR_TMP" </dev/null); then
    echo "$RESPONSE"
else
    rc=$?
    cli_failure_message "codex" "$rc" "$COUNCIL_TIMEOUT" "$ERR_TMP" >&2
    exit 1
fi
