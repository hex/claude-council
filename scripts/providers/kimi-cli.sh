#!/bin/bash
# ABOUTME: Queries the Kimi Code CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the kimi binary being on PATH, not an API key

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

if ! command -v kimi >/dev/null 2>&1; then
    echo "Error: kimi CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# --output-format stream-json, not the default text: the text renderer prefixes
# every line with "• ", interleaves the model's visible reasoning with the
# answer, and appends a "To resume this session: …" footer. All three would end
# up quoted verbatim in the council's synthesis. The JSONL stream separates them
# cleanly — role "assistant" is the answer, role "meta" is the session hint.
# Restrict the agent to no tools at all. This matters more here than for the
# other CLIs: `kimi -p` runs under the auto permission policy, so every tool
# call — file writes, shell — is approved with no prompt. codex merely
# inherited whatever ~/.codex/config.toml defaulted to; this grants execution
# unconditionally, on a prompt that can carry --file contents or, in debate
# mode, another provider's answer. Same intent as codex's -s read-only and
# grok-cli's --sandbox read-only.
#
# --agent-file rather than --plan: kimi's read-only plan mode is the obvious
# candidate but the CLI rejects it outright here — "error: Cannot combine
# --prompt with --plan" (verified against kimi-code 0.31.1). An agent file is
# the mechanism that does compose with -p, and its tools/disallowedTools are
# enforced before execution rather than only shaping what the model is offered.
AGENT_FILE="$SCRIPT_DIR/../../prompts/kimi-cli-agent.md"
ARGS=(-p "$FULL_PROMPT" --output-format stream-json --agent-file "$AGENT_FILE")
# -m only on an explicit override, so an unset KIMI_CLI_MODEL defers to the
# CLI's own default_model in config.toml (mirrors codex.sh and grok-cli.sh).
[[ -n "${KIMI_CLI_MODEL:-}" ]] && ARGS+=(-m "$KIMI_CLI_MODEL")

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

ERR_TMP=$(mktemp)
OUT_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP" "$OUT_TMP"' EXIT

# Only the reaping shell's own stderr is silenced, not the CLI's: when the
# alarm kills the child, bash reports the signal itself ("Alarm clock: 14",
# with the PID and the whole command line) on this script's stderr, and the
# council stores provider stderr verbatim as the error text — so that report
# would reach the pane in place of the timeout message below. The child keeps
# its own redirections, so its output still lands in the temp files.
{ if perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" kimi "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then rc=0; else rc=$?; fi; } 2>/dev/null
if [[ $rc -eq 0 ]]; then
    # Concatenate every assistant chunk; a long answer may arrive in several.
    # Read line by line (-nR + inputs) rather than slurping: `jq -s` parses the
    # whole stream as one value sequence, so a single unstructured line — an
    # upgrade notice, a warning — aborts the parse and discards a complete
    # answer. `fromjson?` drops what won't parse and keeps the rest.
    #
    # Two shapes beyond the plain string chunk have to be handled, because both
    # fail silently: content may arrive as a [{type,text}] array, and adding an
    # array to a string is a jq type error that the `|| true` below swallows
    # into "no content"; and an assistant message carrying tool_calls narrates
    # the call rather than answering, so its text would otherwise be spliced
    # into the synthesis — the very interleaving reading stream-json avoids.
    RESPONSE=$(jq -rnR '
        [ inputs
          | fromjson?
          | select(type == "object" and .role == "assistant" and (has("tool_calls") | not))
          | .content
          | if   type == "array"  then map(select(.type == "text") | .text // empty) | join("")
            elif type == "string" then .
            else empty end
        ] | join("")' "$OUT_TMP" 2>/dev/null || true)
    if [[ -z "${RESPONSE//[[:space:]]/}" ]]; then
        echo "Error from kimi CLI: no assistant content in response" >&2
        exit 1
    fi
    echo "$RESPONSE"
else
    if [[ $rc -eq 142 ]]; then
        echo "Error from kimi CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from kimi CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
