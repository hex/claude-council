#!/bin/bash
# ABOUTME: Condenses a CLI provider's captured stderr into a one-line error excerpt
# ABOUTME: Keeps the end of the stream, where a CLI states why it failed

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
