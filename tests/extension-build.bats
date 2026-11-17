#!/usr/bin/env bats
# ABOUTME: Builds the Claude Desktop extension package and runs the packed server from it
# ABOUTME: Needs npm and network for the pinned mcpb packer; skips with a reason without them

# Failure modes covered:
#  - uncommitted changes in a packed file: the build stops and names the file
#  - the package misses what the council needs at run time, or carries the developer tools
#  - the package's version drifts from the plugin's
#  - mcpb rejects the staged manifest: the build stops with mcpb's reason and packs nothing
#  - the staging directory left in dist/ after a build, whether it passed or failed
#  - the packed server cannot find the scripts packed beside it: council_status and
#    council_ask are run from the unpacked package, outside any checkout

load test_helper
load fixtures/fake-clis
bats_require_minimum_version 1.5.0

NODE="$(command -v node)"
CLIENT="${BATS_TEST_DIRNAME}/fixtures/mcp-client.js"
INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'

setup() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) skip "the Desktop extension supports macOS and Linux only" ;;
    esac
    command -v npx >/dev/null || skip "npx is not installed, so the mcpb packer cannot run"
    command -v unzip >/dev/null || skip "unzip is not installed"
    npm view @anthropic-ai/mcpb@2.1.2 version --fetch-timeout=30000 --fetch-retries=1 >/dev/null 2>&1 \
        || skip "the npm registry is unreachable, so the mcpb packer cannot be fetched"
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    # The build packs HEAD, so it runs in a clone of the committed tree.
    REPO="${BATS_TEST_TMPDIR}/repo"
    git clone -q "$PROJECT_ROOT" "$REPO"
}

@test "extension build: uncommitted changes in a packed file stop the build, naming the file" {
    printf '# local edit\n' >> "${REPO}/scripts/run-council.sh"
    run --separate-stderr bash "${REPO}/extension/build.sh"
    [ "$status" -eq 1 ]
    assert_eq "$stderr" "$(printf '%s\n' 'Error: uncommitted changes in files the extension packs; commit or discard them first:' ' M scripts/run-council.sh')"
    [ ! -e "${REPO}/dist" ]
}

@test "extension build: a manifest mcpb rejects stops the build with mcpb's reason, leaving nothing in dist" {
    jq 'del(.author)' "${REPO}/extension/manifest.json" > "${BATS_TEST_TMPDIR}/manifest.json"
    cp "${BATS_TEST_TMPDIR}/manifest.json" "${REPO}/extension/manifest.json"
    git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -qam "manifest without an author"
    run --separate-stderr bash "${REPO}/extension/build.sh"
    [ "$status" -eq 1 ]
    assert_eq "$output" ''
    [[ "$stderr" == *$'ERROR: Manifest validation failed:\n\n  - author: Required'* ]]
    assert_eq "$(ls -A "${REPO}/dist")" ''
}

@test "extension build: the package holds the server and the council scripts at the plugin's version, and runs" {
    run --separate-stderr bash "${REPO}/extension/build.sh"
    [ "$status" -eq 0 ]
    local version package
    version=$(jq -r '.version' "${REPO}/.claude-plugin/plugin.json")
    package="${REPO}/dist/council-${version}.mcpb"
    assert_eq "$output" "$package"

    local unpacked="${BATS_TEST_TMPDIR}/unpacked"
    unzip -q "$package" -d "$unpacked"
    assert_eq "$(jq -r '.version' "${unpacked}/manifest.json")" "$version"
    local file
    for file in icon.png server/index.js server/council.js server/models.js server/settings.html server/answers.html server/pick.html \
        server/panel-style.css server/panel-host.js server/panel-page.js server/marks.js server/markdown.js server/seat-cards.js server/seat-cards.css \
        server/model-list.js server/model-list.css server/THIRD-PARTY-NOTICES.md \
        plugin/scripts/run-council.sh plugin/scripts/check-status.sh plugin/scripts/providers/openrouter.sh \
        plugin/config/roles.json plugin/prompts/synthesis.md plugin/schemas/agent-analysis.schema.json; do
        [ -f "${unpacked}/${file}" ] || { echo "missing from the package: $file" >&2; return 1; }
    done
    [ ! -e "${unpacked}/plugin/scripts/dev" ]
    [ ! -e "${unpacked}/tests" ]
    assert_eq "$(ls -A "${REPO}/dist")" "council-${version}.mcpb"

    install_fake_clis
    isolate_seat_dirs
    unset_provider_keys
    export COUNCIL_FAKE_BEHAVIOR=valid XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/config"
    local requests="${BATS_TEST_TMPDIR}/requests.jsonl"
    printf '%s\n' "$INIT" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"council_status","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"council_ask","arguments":{"question":"q","providers":["codex"]}}}' \
        > "$requests"
    run --separate-stderr "$NODE" "$CLIENT" "${unpacked}/server/index.js" "$requests"
    [ "$status" -eq 0 ]
    assert_eq "$(printf '%s\n' "$output" | jq -c 'select(.id == 0) | .result.serverInfo')" "{\"name\":\"council\",\"version\":\"${version}\"}"
    assert_eq "$(printf '%s\n' "$output" | jq -r 'select(.id == 1) | .result.isError')" false
    [[ "$(printf '%s\n' "$output" | jq -r 'select(.id == 1) | .result.content[0].text')" == "Provider Status:"* ]]
    assert_eq "$(printf '%s\n' "$output" | jq -r 'select(.id == 2) | .result.isError')" false
    [[ "$(printf '%s\n' "$output" | jq -r 'select(.id == 2) | .result.content[0].text')" == *"FAKE-CODEX-RESPONSE: deterministic answer"* ]]
}
