#!/bin/bash
# ABOUTME: Turns a Claude Code session JSONL into markdown for an external reviewer
# ABOUTME: Takes an explicit transcript path — it never resolves "the current session"

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required (macOS: brew install jq)." >&2
    exit 1
}

usage() {
    cat >&2 << 'EOF'
Usage: transcript-digest.sh [OPTIONS] [--] <transcript.jsonl>

Options:
  --turns SPEC   Window over human turns: last:N or all (default: last:25)
  --help, -h     This message

Takes a path to a session JSONL. It does not resolve a session id and does not
discover "the current session": inside a subagent the ambient session id names
the PARENT conversation, so auto-resolution is how a subagent would digest a
conversation it was never shown. Resolving it belongs to a caller that can ask.

Output: markdown on stdout.
EOF
    exit 1
}

TRANSCRIPT=""
TURNS="last:25"

while [[ $# -gt 0 ]]; do
    case $1 in
        --turns=*)
            TURNS="${1#*=}"
            shift
            ;;
        --turns)
            TURNS="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        --)
            shift
            TRANSCRIPT="${1:-}"
            if [[ $# -gt 0 ]]; then shift; fi
            ;;
        -*)
            echo "Error: Unknown flag: $1" >&2
            usage
            ;;
        *)
            TRANSCRIPT="$1"
            shift
            ;;
    esac
done

if [[ -z "$TRANSCRIPT" ]]; then
    echo "Error: no transcript given." >&2
    usage
fi

# A bare uuid is the natural thing to reach for, and resolving one here is the
# mechanism by which a subagent would digest its parent: inside a subagent the
# ambient session id names the LEAD's conversation, whose content the subagent
# was never shown. Name the lookup rather than performing it.
if [[ "$TRANSCRIPT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "Error: that is a session id, not a transcript path." >&2
    echo "Resolve it in a turn that can ask a human, then pass the file:" >&2
    echo "  ls \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}\"/projects/*/${TRANSCRIPT}.jsonl" >&2
    exit 1
fi

if [[ ! -f "$TRANSCRIPT" ]]; then
    echo "Error: transcript not found: $TRANSCRIPT" >&2
    exit 1
fi

# A user line is a human turn only when origin says so. Tool results arrive as
# type "user" too and outnumber real turns roughly 34 to 1, so all four clauses
# carry weight: drop meta lines, drop anything holding a toolUseResult, and
# require the positive human marker rather than inferring one from absence.
# Without the isMeta clause, cross-session peer messages enter the digest as
# fabricated human turns — they carry another Claude's prose in message.content.
HUMAN_FILTER='.type == "user"
    and (.isMeta != true)
    and (has("toolUseResult") | not)
    and (.origin.kind == "human")'

# Emitted in file order. Walking the parentUuid chain back from the last prompt
# is the intuitive traversal and it silently begins at the most recent compact
# summary, recovering roughly a quarter of a compacted session.
EXTRACT="
    select(.type == \"user\" or .type == \"assistant\")
    | if .type == \"user\" then
          select($HUMAN_FILTER)
        | .message.content
        | if type == \"string\" then .
          else ([.[]? | select(.type == \"text\") | .text] | join(\"\n\"))
          end
        | select(length > 0)
        | \"## Human\n\n\" + .
      else
          .message.content
        | [.[]? | select(.type == \"text\") | .text]
        | join(\"\n\")
        | select(length > 0)
        | \"## Assistant\n\n\" + .
      end
"

START_LINE=""
case "$TURNS" in
    all)
        ;;
    last:*)
        n="${TURNS#last:}"
        case "$n" in
            ''|*[!0-9]*)
                echo "Error: --turns last:N needs a number, got: $n" >&2
                exit 1
                ;;
        esac
        # tail reads its whole input, so jq is never killed by an early-exiting
        # consumer the way `| head -1` would kill it on a large transcript.
        human_lines=$(jq -r "select($HUMAN_FILTER) | input_line_number" "$TRANSCRIPT" \
            | tr -d '\r' | tail -n "$n")
        if [[ -n "$human_lines" ]]; then
            START_LINE="${human_lines%%$'\n'*}"
        fi
        ;;
    *)
        echo "Error: --turns takes last:N or all, got: $TURNS" >&2
        exit 1
        ;;
esac

if [[ -n "$START_LINE" ]]; then
    tail -n "+${START_LINE}" "$TRANSCRIPT" | jq -r "$EXTRACT" | tr -d '\r'
else
    jq -r "$EXTRACT" "$TRANSCRIPT" | tr -d '\r'
fi
