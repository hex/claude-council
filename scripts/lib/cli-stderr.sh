#!/bin/bash
# ABOUTME: The error line a CLI provider reports when its CLI times out or fails
# ABOUTME: A failure is quoted from the end of the CLI's stderr, where it states why

# The last 500 bytes of a stderr capture, on one line, with terminal control
# sequences removed. A CLI leads its stderr with a banner, hook chatter and
# (codex) the whole prompt echoed back, and states the cause last, so the end
# is the part worth showing; codex and agy colour it, clear a progress line or
# hide the cursor first, and those sequences (CSI ones, and OSC ones ended by
# BEL) would otherwise take a third of the excerpt and reach the pane as text.
# They go before the cut, so the cut never severs one and leaves its tail
# behind. Both filters run byte-wise (LC_ALL=C): under a UTF-8 locale BSD sed
# and tr refuse a byte that is not valid UTF-8, which an echoed prompt can
# hold. Every stage drains the one before it to the end, so none is cut off by
# a reader that has stopped reading — a pipeline status the callers' pipefail
# would turn into a silent exit.
# Usage: stderr_excerpt <file>
stderr_excerpt() {
    LC_ALL=C sed -e $'s|\e\\[[0-?]*[ -/]*[@-~]||g' -e $'s|\e\\][^\a]*\a||g' "$1" | tail -c 500 | LC_ALL=C tr '\n' ' '
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
    # The excerpt's last newline became a space; the line ends on its text.
    excerpt="${excerpt%"${excerpt##*[![:space:]]}"}"
    echo "Error from ${label} CLI: ${excerpt:-non-zero exit}"
}
