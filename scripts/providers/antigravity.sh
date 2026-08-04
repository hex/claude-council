#!/bin/bash
# ABOUTME: Queries Google's Antigravity CLI (agy) in print mode using subscription auth
# ABOUTME: Availability is gated on the agy binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"

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

if ! command -v agy >/dev/null 2>&1; then
    echo "Error: agy CLI not found on PATH" >&2
    exit 1
fi

# agy answers by writing a report artifact to disk unless pinned inline —
# see INLINE_ANSWER_GUARD in lib/verbosity.sh.
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

# MATERIAL_GUARD comes from verbosity.sh. It matters most here because agy has
# no allowed-tools flag and --sandbox restricts only the terminal, leaving its
# file tools live, so the framing is all that stands between an embedded
# "ignore your instructions" and them. It rides both the argv and the spill
# path: the same material arrives either way, and which side of the size limit
# it lands on says nothing about how far it can be trusted.
FULL_PROMPT="${INLINE_ANSWER_GUARD}

${SYSTEM}

${MATERIAL_GUARD}

${PROMPT}"

# Flags must precede the prompt: agy uses Go's flag package, which stops
# parsing at the first positional argument, so flags after the prompt get
# folded into the prompt text. --sandbox restricts terminal access as
# defense-in-depth alongside the guard.
ARGS=(--sandbox)
# --model only on an explicit override: a pinned label would override the
# model selected in the Antigravity app, so an unset ANTIGRAVITY_MODEL defers
# to agy's own selection (mirrors codex.sh and grok-cli.sh).
[[ -n "${ANTIGRAVITY_MODEL:-}" ]] && ARGS+=(--model "$ANTIGRAVITY_MODEL")

ERR_TMP=$(mktemp)
SPILL_DIR=""
# One rm, not two statements: under `set -e` a trap body stops at its first
# failing command, and removing ERR_TMP can fail on Windows when agy still holds
# it open — the platform the spill exists for. Chained, that would strand a file
# holding the whole prompt in a temp directory nothing ever cleans.
trap 'rm -rf "$ERR_TMP" ${SPILL_DIR:+"$SPILL_DIR"}' EXIT

# The prompt is the value of -p, and agy cannot take it any other way: `--print`
# with no value prints the help rather than reading stdin. That puts the whole
# prompt on the command line, which Windows caps at 32k — a --file-sized prompt
# fails CreateProcess with error 206 before agy ever starts. Past the limit the
# prompt goes to a file and agy is told to read it; --add-dir is required
# because the spill lives outside the workspace agy can see.
PROMPT_ARG="$FULL_PROMPT"
if [[ ${#FULL_PROMPT} -gt ${COUNCIL_ARGV_LIMIT:-24000} ]]; then
    # A directory of its own rather than the temp root. --add-dir is the only
    # lever that widens --sandbox (agy has no allowed-tools flag), so it grants
    # the agent exactly one file instead of every other process's scratch space.
    SPILL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/council-agy.XXXXXX")
    SPILL="$SPILL_DIR/council-agy-prompt.txt"
    # Only the question goes to the file. Spilling the guard, the system prompt
    # and the verbosity directive alongside it would bury the council's own
    # instructions inside the one object the next sentence tells agy to treat as
    # material — a `--verbosity brief` run would lose its directive that way —
    # and it leaves the file holding exactly the untrusted half.
    printf '%s' "$PROMPT" > "$SPILL"
    SPILL_PATH="$SPILL"
    WORKSPACE_DIR="$SPILL_DIR"
    # agy is a native Windows binary under Git Bash: it cannot resolve a
    # /tmp-style path, so hand it the Windows form when cygpath is available.
    if command -v cygpath >/dev/null 2>&1; then
        SPILL_PATH=$(cygpath -w "$SPILL")
        WORKSPACE_DIR=$(cygpath -w "$SPILL_DIR")
    fi
    ARGS+=(--add-dir "$WORKSPACE_DIR")
    PROMPT_ARG="${SPILLED_ANSWER_GUARD}

${SYSTEM}

${MATERIAL_GUARD}

The question is in the file at ${SPILL_PATH} — read it in full and answer it
directly, without pausing to confirm."
fi

# Flags must precede the prompt (see above), so -p goes on last.
ARGS+=(-p "$PROMPT_ARG")

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

if RESPONSE=$(perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" agy "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 142 ]]; then
        echo "Error from antigravity CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from antigravity CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
