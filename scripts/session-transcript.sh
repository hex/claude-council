#!/bin/bash
# ABOUTME: Resolves a Claude Code session id to the transcript file on disk
# ABOUTME: Kept separate from the digest so the privacy gate has a seam to sit in

set -euo pipefail

usage() {
    cat >&2 << 'EOF'
Usage: session-transcript.sh [--projects-dir DIR] <session-id>

Prints the path of the transcript for that session id, or fails saying why.

  --projects-dir DIR  Where to look (default: $CLAUDE_CONFIG_DIR/projects,
                      falling back to ~/.claude/projects)
  --help, -h          This message

Resolution is a glob over every project directory rather than a computed
directory name: the name is a lossy encoding of the working directory, and two
different directories can legitimately encode to the same name. The session id
is what carries the uniqueness.
EOF
    exit "${1:-1}"
}

PROJECTS_DIR=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --projects-dir=*) PROJECTS_DIR="${1#*=}"; shift ;;
        --projects-dir)
            if [[ $# -lt 2 ]]; then
                echo "Error: --projects-dir needs a value." >&2
                usage
            fi
            PROJECTS_DIR="$2"; shift 2 ;;
        --help|-h) usage 0 ;;
        --) shift; SESSION_ID="${1:-$SESSION_ID}"; if [[ $# -gt 0 ]]; then shift; fi ;;
        -*) echo "Error: Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -n "$SESSION_ID" ]]; then
                echo "Error: give one session id, got a second: $1" >&2
                usage
            fi
            SESSION_ID="$1"; shift ;;
    esac
done

if [[ -z "$SESSION_ID" ]]; then
    echo "Error: no session id given." >&2
    usage
fi

# Shape-checked before it reaches a glob: the id becomes part of a path, and a
# value carrying slashes or dots would walk out of the projects directory.
if [[ ! "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "Error: that is not a session id: $SESSION_ID" >&2
    exit 1
fi

if [[ -z "$PROJECTS_DIR" ]]; then
    PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
fi

if [[ ! -d "$PROJECTS_DIR" ]]; then
    echo "Error: no projects directory at $PROJECTS_DIR" >&2
    exit 1
fi

matches=()
for candidate in "$PROJECTS_DIR"/*/"${SESSION_ID}.jsonl"; do
    [[ -f "$candidate" ]] && matches+=("$candidate")
done

# "${arr[@]}" on an empty array aborts under set -u on bash 3.2, which is the
# floor the suite runs against.
count=${#matches[@]}

if [[ "$count" -eq 0 ]]; then
    echo "Error: no transcript for session $SESSION_ID under $PROJECTS_DIR" >&2
    exit 1
fi

if [[ "$count" -gt 1 ]]; then
    echo "Error: session $SESSION_ID matches more than one transcript:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    echo "Pass the one you mean to the digest directly." >&2
    exit 1
fi

printf '%s\n' "${matches[0]}"
