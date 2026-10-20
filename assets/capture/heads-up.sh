#!/bin/bash
# ABOUTME: Captures the heads-up intro, note, details, and unsent prompt draft.
# ABOUTME: Uses the E2E fixture note and real host turns in both themes.
set -euo pipefail
python3 "$(dirname "$0")/capture.py" heads-up
