#!/bin/bash
# ABOUTME: Bumps the plugin version, commits, tags, and refreshes the plugin cache.
# ABOUTME: Reads current version from plugin.json and increments the patch number.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_JSON="${SCRIPT_DIR}/../.claude-plugin/plugin.json"

if [[ ! -f "$PLUGIN_JSON" ]]; then
    echo "Error: plugin.json not found at $PLUGIN_JSON" >&2
    exit 1
fi

# Operate from the repo root, and refuse to run with a pre-staged index before
# mutating anything: the version-bump commit below carries the whole index, so
# any unrelated staged change would be swept into it.
cd "${SCRIPT_DIR}/.."
if ! git diff --cached --quiet; then
    echo "Error: staged changes present. Commit or unstage them before releasing." >&2
    exit 1
fi

# Never tag a release on a red suite. (Skipped only where the runner is absent,
# e.g. a minimal checkout.)
if [[ -f tests/run_tests.sh ]]; then
    echo "Running test suite before release..."
    if ! bash tests/run_tests.sh; then
        echo "Error: test suite failed; aborting release." >&2
        exit 1
    fi
fi

# Read current version
CURRENT_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
echo "Current version: $CURRENT_VERSION"

# Compute new version: BUILD resets to 1 when the month rolls over.
TODAY_YEAR=$(date +%Y)
TODAY_MONTH=$(date +%-m)
IFS='.' read -r YEAR MONTH PATCH <<< "$CURRENT_VERSION"
if [[ "$YEAR.$MONTH" == "$TODAY_YEAR.$TODAY_MONTH" ]]; then
    NEW_VERSION="${YEAR}.${MONTH}.$((PATCH + 1))"
else
    NEW_VERSION="${TODAY_YEAR}.${TODAY_MONTH}.1"
fi

echo "New version: $NEW_VERSION"

# Update plugin.json
jq --arg v "$NEW_VERSION" '.version = $v' "$PLUGIN_JSON" > "${PLUGIN_JSON}.tmp"
mv "${PLUGIN_JSON}.tmp" "$PLUGIN_JSON"

# Commit and tag
git add .claude-plugin/plugin.json
git commit -m "Bump version to ${NEW_VERSION}"
git tag "v${NEW_VERSION}"

echo ""
echo "Released v${NEW_VERSION}"
echo "  - plugin.json updated"
echo "  - Committed and tagged v${NEW_VERSION}"
echo ""
echo "Refreshing plugin cache..."
claude plugin update claude-council@hex-plugins-dev
echo "Done. Plugin cache is now at v${NEW_VERSION}."
