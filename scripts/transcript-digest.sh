#!/bin/bash
# ABOUTME: Turns a Claude Code session JSONL into markdown for an external reviewer
# ABOUTME: Takes an explicit transcript path — it never resolves "the current session"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required (macOS: brew install jq)." >&2
    exit 1
}

TRANSCRIPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --)
            shift
            TRANSCRIPT="${1:-}"
            shift || true
            ;;
        -*)
            echo "Error: Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            TRANSCRIPT="$1"
            shift
            ;;
    esac
done

if [[ -z "$TRANSCRIPT" ]]; then
    echo "Error: no transcript given." >&2
    exit 1
fi

if [[ ! -f "$TRANSCRIPT" ]]; then
    echo "Error: transcript not found: $TRANSCRIPT" >&2
    exit 1
fi

# A user line is a human turn only when origin says so. Tool results arrive as
# type "user" too and outnumber real turns ~34:1, so all four clauses carry
# weight: drop meta lines, drop anything holding a toolUseResult, and require
# the positive human marker rather than inferring one from what is absent.
#
# Emitted in file order. Walking the parentUuid chain from the last prompt is
# the intuitive traversal and it silently starts at the most recent compact
# summary, recovering roughly a quarter of a compacted session.
jq -r '
    select(.type == "user" or .type == "assistant")
    | if .type == "user" then
          select(.isMeta != true)
        | select(has("toolUseResult") | not)
        | select(.origin.kind == "human")
        | .message.content
        | if type == "string" then .
          else ([.[]? | select(.type == "text") | .text] | join("\n"))
          end
        | select(length > 0)
        | "## Human\n\n" + .
      else
          .message.content
        | [.[]? | select(.type == "text") | .text]
        | join("\n")
        | select(length > 0)
        | "## Assistant\n\n" + .
      end
' "$TRANSCRIPT" | tr -d '\r'
