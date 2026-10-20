#!/bin/bash
# ABOUTME: Captures a five-seat council in Claude Code and builds its SVG.
# ABOUTME: Runs the shared capture driver with fixture providers in both themes.
set -euo pipefail
python3 "$(dirname "$0")/capture.py" council-run
