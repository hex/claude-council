#!/bin/bash
# ABOUTME: Captures the script-only tmux pane and builds its SVG.
# ABOUTME: Selects fake or real seats and zooms the side pane to 110 columns.
set -euo pipefail
python3 "$(dirname "$0")/capture.py" tmux-pane
