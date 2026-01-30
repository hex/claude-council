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

# Read current version
CURRENT_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
echo "Current version: $CURRENT_VERSION"

# Parse YYYY.M.PATCH and increment patch
IFS='.' read -r YEAR MONTH PATCH <<< "$CURRENT_VERSION"
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="${YEAR}.${MONTH}.${NEW_PATCH}"

echo "New version: $NEW_VERSION"

# Update plugin.json
jq --arg v "$NEW_VERSION" '.version = $v' "$PLUGIN_JSON" > "${PLUGIN_JSON}.tmp"
mv "${PLUGIN_JSON}.tmp" "$PLUGIN_JSON"

# Commit and tag
cd "${SCRIPT_DIR}/.."
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
