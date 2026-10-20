#!/bin/bash
# ABOUTME: Builds the hand-written council title card at the cs banner proportions.
# ABOUTME: Uses the shared SVG writer and records the checkout revision.
set -euo pipefail
python3 "$(dirname "$0")/render.py" --banner "$(dirname "$0")/../banner.svg"
