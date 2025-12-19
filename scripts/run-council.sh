#!/bin/bash
# ABOUTME: Wrapper script that runs council query and saves to timestamped file
# ABOUTME: Returns the output filename for Claude to read

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate timestamped filename
OUTDIR=".claude/cache"
OUTFILE="${OUTDIR}/council-$(date +%s).txt"

# Ensure output directory exists
mkdir -p "$OUTDIR"

# Run query and format, passing all arguments to query-council.sh
bash "${SCRIPT_DIR}/query-council.sh" "$@" 2>/dev/null | bash "${SCRIPT_DIR}/format-output.sh" > "$OUTFILE"

# Output the filename for Claude to read
echo "$OUTFILE"
