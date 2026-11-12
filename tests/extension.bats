#!/usr/bin/env bats
# ABOUTME: Drives the Claude Desktop extension's MCP server over stdio, as Desktop does
# ABOUTME: Real council scripts behind it; fake CLIs and a fake curl stand in for the providers

# The ways the server can fail, each with the test that covers it:
#  protocol
#   - a line that is not JSON: parse error, id null, and the next request still served
#   - JSON that is not a request (null, a number, an array): invalid request, still served
#   - an unknown method: method not found, naming it
#   - a notification, known or unknown: never answered
#   - an unknown tool: invalid params, naming it
#   - initialize: answers the version Desktop asked for when supported, offers tools and resources
#   - input ends: the server exits 0, and a council run still in flight dies with it
#   - a listening socket, ever: none (the fence refuses and records any attempt)
#  tools and the panel resource
#   - tools/list: the two panel tools carry the app-only visibility key, the settings tool the panel uri
#   - resources/read: the panel with mimeType text/html;profile=mcp-app; an unknown uri is an error naming it
#  council_ask
#   - an empty or blank question, an unknown or malformed provider, a bad verbosity, an unknown
#     argument: refused with a sentence, nothing run
#   - the result path the script prints is relative to its working directory: the answer still returns
#   - a failed run: the scripts' own error comes back as the tool error
#   - a seat whose error text carries the key: the key is replaced in the reply, and is in no state file
#   - openrouter-N past the saved roster: refused before any run
#   - the saved roster reaches the run as one seat per model
#   - a model variable inherited from Desktop's environment: dropped, the scripts' default is used
#   - Desktop's minimal PATH: a CLI seat installed in ~/.local/bin is still found
#   - two questions at once: each gets its own answer
#  keys
#   - a key field left empty arrives as an empty string or as the literal ${user_config.x}: no key
#  saved model choices
#   - a malformed models file: runs use the defaults, and the settings text says the file was ignored
#   - a bad model id on save: refused naming the provider, the file left as it was
#   - a save: the file is 0600 in a 0700 directory, no temporary file left behind, and a state
#     directory found with looser permissions is tightened
#  settings and status
#   - council_status: the scripts' report, then where keys go in Desktop
#   - council_settings: each provider's model in plain text, defaults as the scripts resolve them
#   - panel data: a provider with no key is never contacted; one with a key is, and only its own
#     endpoint, and a failed list says so without the key
# Model-list parsing is in extension-models.bats, the package build in extension-build.bats.

load test_helper
load fixtures/fake-clis
bats_require_minimum_version 1.5.0

# Resolved before setup narrows PATH: node may share a directory with a CLI.
NODE="$(command -v node)"
SERVER="${PROJECT_ROOT}/extension/server/index.js"
CLIENT="${BATS_TEST_DIRNAME}/fixtures/mcp-client.js"
FENCE="${BATS_TEST_DIRNAME}/fixtures/extension-fence.js"
INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}},"clientInfo":{"name":"test","version":"0"}}}'
SENTINEL_KEY="sk-test-placeholder-7f3a9c2e5b1d4068a1b2c3d4e5f60718"

setup() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) skip "the Desktop extension supports macOS and Linux only" ;;
    esac
    mkdir -p "$TEST_TMP_DIR" "$TEST_CACHE_DIR"
    install_fake_clis
    isolate_seat_dirs
    unset_provider_keys
    export COUNCIL_FENCE_LOG="${BATS_TEST_TMPDIR}/fence.jsonl"
    : > "$COUNCIL_FENCE_LOG"
    export NODE_OPTIONS="--require ${FENCE}"
    STATE_DIR="${HOME}/.config/council-extension"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# Runs one server session with the given request lines; leaves the server's
# stdout in $output, its stderr in $stderr, its exit code in $status.
mcp() {
    local requests="${BATS_TEST_TMPDIR}/requests.jsonl"
    printf '%s\n' "$@" > "$requests"
    run --separate-stderr "$NODE" "$CLIENT" "$SERVER" "$requests"
}

# A tools/call request line.
call() {
    local args="${3:-"{}"}"
    jq -cn --argjson id "$1" --arg name "$2" --argjson args "$args" \
        '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $name, arguments: $args}}'
}

# The reply carrying the given id, as one compact JSON line.
reply() {
    printf '%s\n' "$output" | jq -c --argjson id "$1" 'select(.id == $id)'
}

# The text of a tool result.
result_text() {
    reply "$1" | jq -r '.result.content[0].text'
}

# The isError flag of a tool result.
result_error() {
    reply "$1" | jq -r '.result.isError'
}

# Writes the saved model choices file.
save_choices() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" > "${STATE_DIR}/models.json"
}

# ============================================================================
# Protocol
# ============================================================================

@test "extension: a line that is not JSON is a parse error, and the next request is still served" {
    mcp 'this is not json' '{"jsonrpc":"2.0","id":7,"method":"ping"}'
    [ "$status" -eq 0 ]
    assert_eq "$(printf '%s\n' "$output" | sed -n 1p)" '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error: the line is not JSON"}}'
    assert_eq "$(reply 7)" '{"jsonrpc":"2.0","id":7,"result":{}}'
}

@test "extension: JSON that is not a request object is an invalid request, and serving goes on" {
    mcp 'null' '42' '[]' '{"jsonrpc":"2.0","id":3,"method":"ping"}'
    [ "$status" -eq 0 ]
    assert_eq "$(printf '%s\n' "$output" | jq -c 'select(.id == null) | .error' | sort -u)" '{"code":-32600,"message":"invalid request: expected a JSON-RPC request object"}'
    assert_eq "$(printf '%s\n' "$output" | jq -c 'select(.id == null)' | wc -l | tr -d ' ')" 3
    assert_eq "$(reply 3)" '{"jsonrpc":"2.0","id":3,"result":{}}'
}

@test "extension: an unknown method is answered with method not found, naming it" {
    mcp '{"jsonrpc":"2.0","id":1,"method":"sampling/fly"}'
    assert_eq "$(reply 1)" '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found: sampling/fly"}}'
}

@test "extension: notifications, known or not, are never answered" {
    mcp "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","method":"notifications/made-up"}' '{"jsonrpc":"2.0","id":2,"method":"ping"}'
    [ "$status" -eq 0 ]
    assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" 2
    assert_eq "$(printf '%s\n' "$output" | jq -c '.id' | paste -sd, -)" '0,2'
}

@test "extension: an unknown tool is invalid params, naming it" {
    mcp "$INIT" "$(call 1 council_fly)"
    assert_eq "$(reply 1)" '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"unknown tool: council_fly"}}'
}

@test "extension: initialize answers Desktop's protocol version and offers tools and resources" {
    mcp "$INIT"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 0 | jq -c '.result | {protocolVersion, capabilities, name: .serverInfo.name}')" \
        '{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"resources":{}},"name":"council"}'
}

@test "extension: input ending makes the server exit 0" {
    mcp "$INIT"
    [ "$status" -eq 0 ]
    assert_blank "$stderr"
}

# ============================================================================
# Tools and the panel resource
# ============================================================================

@test "extension: tools/list hides the two panel tools from the model and ties settings to the panel" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    assert_eq "$(reply 1 | jq -c '[.result.tools[] | {name, ui: ._meta.ui}]')" \
        '[{"name":"council_ask","ui":null},{"name":"council_status","ui":null},{"name":"council_settings","ui":{"resourceUri":"ui://council/settings"}},{"name":"council_models_data","ui":{"visibility":["app"]}},{"name":"council_models_save","ui":{"visibility":["app"]}}]'
}

@test "extension: the panel resource is served as an MCP App page" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' \
        '{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"ui://council/settings"}}'
    assert_eq "$(reply 1 | jq -c '.result.resources')" \
        '[{"uri":"ui://council/settings","name":"Council models","mimeType":"text/html;profile=mcp-app"}]'
    assert_eq "$(reply 2 | jq -c '.result.contents[0] | {uri, mimeType}')" \
        '{"uri":"ui://council/settings","mimeType":"text/html;profile=mcp-app"}'
    assert_eq "$(reply 2 | jq -r '.result.contents[0].text')" "$(cat "${PROJECT_ROOT}/extension/server/panel.html")"
}

@test "extension: an unknown resource uri is an error naming it" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"ui://council/nope"}}'
    assert_eq "$(reply 1)" '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"resource not found: ui://council/nope"}}'
}
