#!/bin/bash
# ABOUTME: The error line a CLI provider reports when its CLI times out or fails
# ABOUTME: A failure is quoted from the end of the CLI's stderr, where it states why

# The last 500 bytes of a stderr capture, on one line, with terminal colour
# codes removed. A CLI leads its stderr with a banner, hook chatter and
# (codex) the whole prompt echoed back, and states the cause last, so the end
# is the part worth showing; codex and agy colour it, and the codes would
# otherwise take a third of the excerpt and reach the pane as text. The codes
# go before the cut, so the cut never severs one and leaves its tail behind.
# Every stage drains the one before it to the end, so none is cut off by a
# reader that has stopped reading — a pipeline status the callers' pipefail
# would turn into a silent exit.
# Usage: stderr_excerpt <file>
stderr_excerpt() {
    sed $'s/\e\\[[0-9;]*m//g' "$1" | tail -c 500 | tr '\n' ' '
}

# The line a CLI provider reports when its CLI did not answer: a timeout when
# the deadline ended it (status 143, see deadline.sh), otherwise what the CLI
# said on stderr, or "non-zero exit" when it said nothing.
# Usage: cli_failure_message <cli label> <status> <deadline seconds> <stderr file>
cli_failure_message() {
    local label="$1" status="$2" deadline="$3" excerpt
    if [[ "$status" -eq 143 ]]; then
        echo "Error from ${label} CLI: timed out after ${deadline}s"
        return
    fi
    excerpt=$(stderr_excerpt "$4")
    echo "Error from ${label} CLI: ${excerpt:-non-zero exit}"
}
