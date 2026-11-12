#!/bin/bash
# ABOUTME: Packs the Claude Desktop extension (.mcpb) from the committed tree into dist/
# ABOUTME: Stages the council scripts under plugin/, stamps the plugin's version, validates and packs with mcpb

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pinned: the packer decides what lands in users' hands, so a new release of it
# is adopted deliberately, never picked up by a build.
MCPB_PACKAGE="@anthropic-ai/mcpb@2.1.2"
PLUGIN_PATHS=(scripts config prompts schemas)
EXTENSION_PATHS=(extension/manifest.json extension/server)

cd "$REPO_ROOT"

# The package is cut from HEAD. Uncommitted changes to anything it carries
# would make it differ from the tree that was tested, so they stop the build.
dirty=$(git status --porcelain -- "${PLUGIN_PATHS[@]}" "${EXTENSION_PATHS[@]}" .claude-plugin/plugin.json assets/icon.png)
if [[ -n "$dirty" ]]; then
    echo "Error: uncommitted changes in files the extension packs; commit or discard them first:" >&2
    echo "$dirty" >&2
    exit 1
fi

VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/stage"
OUTPUT="${DIST}/council-${VERSION}.mcpb"

rm -rf "$STAGE" "$OUTPUT"
mkdir -p "${STAGE}/plugin"
git archive HEAD "${PLUGIN_PATHS[@]}" | tar -x -C "${STAGE}/plugin"
# Developer tools only; the extension never runs them.
rm -rf "${STAGE}/plugin/scripts/dev"
git archive HEAD "${EXTENSION_PATHS[@]}" | tar -x -C "$STAGE" --strip-components=1
git show HEAD:assets/icon.png > "${STAGE}/icon.png"
jq --arg version "$VERSION" '.version = $version' "${STAGE}/manifest.json" > "${STAGE}/manifest.json.next"
mv "${STAGE}/manifest.json.next" "${STAGE}/manifest.json"

npx --yes "$MCPB_PACKAGE" validate "${STAGE}/manifest.json" >&2
npx --yes "$MCPB_PACKAGE" pack "$STAGE" "$OUTPUT" >&2
echo "$OUTPUT"
