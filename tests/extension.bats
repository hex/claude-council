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
#   - input ends, or SIGTERM or SIGINT arrives, during a council run: the run's whole process
#     group is stopped, a seat that ignores SIGTERM too (SIGKILL after a grace period), before
#     the server exits
#   - the app closes the server's output during a council run, so a reply cannot be written:
#     the run's whole group is stopped the same way before the server exits 1
#   - a council run past its time limit: stopped the same way, and the tool says so
#   - notifications/cancelled for a council question in flight: its run is stopped and the
#     request never answered, while a question asked beside it is answered
#   - a cancelled call whose tool then fails with an error of the server's own (a picker's ask
#     whose picker was removed under it): still never answered, and the error is logged
#   - a request line over 1 MiB: dropped with one invalid request error, serving goes on
#   - a question over 100000 bytes (one argv entry): refused before any run
#   - a run writing more than 8 MiB to stdout, or 1 MiB to stderr: stopped, and the tool says so
#   - bash that cannot be started (the machine out of file descriptors): the tool says so, and
#     the run that never began does not break the stop of every run at the server's exit
#   - a listening socket, ever: none (the fence refuses and records any attempt)
#  tools and the panel resource
#   - tools/list: the three panel tools carry the app-only visibility key, each panel's tool its uri,
#     council_result neither
#   - resources/read: the three panels (settings, answers, picker) with mimeType text/html;profile=mcp-app, the
#     shared parts inlined (the vendor marks in all three, the model list in settings and picker); an unknown
#     uri is an error naming it
#   - a panel's address: carries the first 12 hex digits of the sha256 of the page as served, the same in
#     tools/list, resources/list and resources/read, so a changed page is never shown from Desktop's cache;
#     the address without the hash is not found
#   - council_ask's description: where the app draws the answers panel it asks for the synthesis
#     without repeating the answers, elsewhere it asks for the answers to be shown first
#   - council_ask's description and question field: the user's question as they asked it, never
#     "self-contained", which a model reads as leave to rewrite it
#   - council_ask's and council_pick's descriptions: council_ask when the user named the seats or a
#     verbosity or said to just ask everyone, council_pick for every other question
#  council_ask
#   - an empty or blank question, an unknown or malformed provider, a bad verbosity, an unknown
#     argument: refused with a sentence, nothing run
#   - each seat's answer comes back twice: in the text for the model, and as structuredContent seats
#     in the order the council ran them for the answers panel
#   - a seat error reaches structuredContent as an error, never as an answer
#   - an answer too long for the panel: the model gets it whole, the panel its first 100000
#     characters with the full length beside them
#   - a key in a long answer where the panel's cut falls: replaced whole before the cut, so no
#     part of it reaches structuredContent
#   - every seat failing: still a result, with every seat's error, that the panel can draw
#   - ANSI colour codes in a seat's answer or error: none in the text or in structuredContent
#   - a failed run: the scripts' own error comes back as the tool error
#   - a seat whose error text carries the key: the key is replaced in the text and in
#     structuredContent, and is in no state file
#   - an answered run: the response cache is off, so neither the question nor an answer that
#     quotes the key is in any file under the state directory
#   - openrouter-N past the saved roster: refused before any run
#   - the saved roster reaches the run as one seat per model
#   - a model variable inherited from Desktop's environment: dropped, the scripts' default is used
#   - Desktop's minimal PATH: a CLI seat installed in ~/.local/bin is still found
#   - all six keys set: each seat, API or CLI, starts with its own vendor's key and no other
#   - two questions at once: each gets its own answer
#  keys
#   - a key field left empty arrives as an empty string or as the literal ${user_config.x}: no key
#   - a key field holding under 8 characters (2.0, x, test): no key, and council_status names the field
#   - a key that occurs in the server's own text (a tool name, the panel mimeType): the envelope,
#     tool list and panel pages come out byte for byte as with no key
#  saved model choices
#   - the state directory: under an absolute XDG_CONFIG_HOME, else under ~/.config
#   - a malformed or partly invalid models file: runs use the defaults, and the council_ask
#     answer, council_status and the settings text each say the file could not be read
#   - a bad model id on save: refused naming the provider, the file left as it was
#   - a model id with a `..`, `.` or empty part (gemini.sh puts the id in a URL path): refused,
#     while real ids with slashes, colons and a leading tilde save
#   - a save: the file is 0600 in a 0700 directory, no temporary file left behind, and a state
#     directory found with looser permissions is tightened
#   - a state directory that is a symbolic link: refused with a sentence, the target left as it was
#   - a models file that is a symbolic link: not read, and the answer says the defaults ran
#   - a settings save: only the providers it names change, or one model joins or leaves the saved
#     OpenRouter roster; a choice the picker saved since the panel loaded is kept; a roster change
#     past the seat limit, with a bad id, or naming no single model is refused, the file as it was
#   - one seat's model saved from the picker: only that provider's choice or that roster position
#     changes, every other choice and the roster order kept; Default clears the choice and the
#     answer names the scripts' default
#   - the first model chosen for the single openrouter seat: the roster starts with it, and the
#     seat is answered as openrouter-1, the name council_pick lists and a run uses
#   - a picker save the choices cannot take (a seat past the roster, a model already on another
#     seat, Default for a roster seat, openrouter beside a roster, a CLI or ollama seat, a bad id,
#     no model, seat and selections together): refused with a sentence, the file left as it was
#   - a picker save over a models file that cannot be read: refused, the file left for the settings
#   - a model saved from the picker: council_pick lists it and council_pick_ask sends it
#  settings and status
#   - council_status: the scripts' report, then where keys go in Desktop
#   - council_settings: each provider's model in plain text, defaults as the scripts resolve them,
#     every line saying "key set" or "no key"
#   - panel data: a provider with no key is never contacted; one with a key is, and only its own
#     endpoint, and a failed list says so without the key; the request follows no redirect,
#     since Gemini's key rides a header a redirect to another host would carry along
#   - a list failure that quotes a key longer than the error shown: the key is replaced whole
#     before the error is cut, so no part of it reaches the panel
#  the council picker
#   - council_pick: the panel gets the question, each seat with its model and the three
#     verbosities, standard chosen, and no agent is started; where no panel is drawn the text lists
#     the seats and says to ask in the chat; with no key and no agent, a sentence saying where keys
#     go; an empty question, one over the cap and an unknown argument are refused as council_ask
#     refuses them
#   - council_pick_ask, the tool the panel's Ask button calls: the same replies as council_ask for
#     every refusal and for an answer, a key in a seat's error removed, a cancel stopping its run
#   - council_pick's description and text: when the user asks for the synthesis of a council run,
#     call council_result; never a claim that the answers cannot be seen
#   - council_pick gives the panel how long to wait for council_pick_ask: the run's limit, the
#     formatting limit and a minute, so a call the host never answers cannot hold the panel for good
#  council_result, the picker's answers handed to the model
#   - a council_pick_ask run where a seat answered: a run id (6 hex digits, random, as a count would
#     restart and let an id from before a restart name a later run) comes back in structuredContent
#   - council_result with that id: council_ask's text for the same question, verbatim, not an error,
#     with no structuredContent and no panel
#   - council_result with no id: the latest run; with an unknown or malformed id: a sentence saying it
#     is not held and to ask the council again; before any run (as after a restart): the same sentence
#   - more than 5 runs: the oldest is forgotten, the rest kept
#   - a run where every seat failed and a refused run: no id, nothing stored, the latest run stays
#     the one before (a cancelled run ends as a refusal, and is never answered)
#   - a key quoted in a stored run's seat error: removed in council_result's text
#   - council_result with an argument it does not take, or a run that is not a string: refused
#  the synthesis in the turn that opened the picker
#   - council_pick mints the run id and gives it to the panel and, in its text, to Claude with the
#     words to call council_result with it now
#   - council_pick_ask with that id and nobody waiting: the run is held under it, and the result
#     says it was not awaited, so the panel drafts the message
#   - a second Ask with the same id, an id already held, or a well-formed id council_pick never
#     made: a fresh id, never awaited
#   - a run id that is not six hex digits: refused before anything is run or written
#   - council_result with a picked id, in one copy of the server, while another copy's
#     council_pick_ask runs it: it waits, gets the answers with the words to synthesise them
#     and the seats asked, and that ask's result says it was awaited
#   - every seat failing, a refused run: the waiter ends with what failed
#   - the wait running out: a sentence saying the user has not pressed Ask, and no marker left
#   - council_result for a run still going past its picker's deadline: a sentence saying to call
#     again shortly and not to ask again; once the run ends, its answers
#   - a waiting council_result cancelled: its marker removed at once, and never answered
#   - a waiter that died: its marker, untouched for just over 2 seconds, is not counted as waiting
#   - council_result for an id council_pick never made, or with no id while a picker is open:
#     answered at once (with no id, the latest held run), never waited on
#   - the panel's handoff (the picked run sent with each Ask until the server answers one; "Claude is writing the
#     synthesis" and no message when the ask was awaited; else one ui/message with no seat output,
#     a line saying to press Enter, the fallback line when the host refuses it) runs only in a
#     host; bats cannot reach it, and whether Desktop keeps the waiting call open is Desktop's
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
    # The server keeps its state under XDG_CONFIG_HOME when that is absolute;
    # one exported in the developer's shell would point it at their real one.
    export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/config"
    STATE_DIR="${XDG_CONFIG_HOME}/council-extension"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
    # A waiting session start_waiter left: its server exits when its input closes.
    if [[ -n "${WAITER_PID:-}" ]]; then kill "$WAITER_PID" 2>/dev/null || true; fi
    # The dead-waiter test's process keeping a marker old.
    if [[ -n "${AGER_PID:-}" ]]; then kill "$AGER_PID" 2>/dev/null || true; fi
    # The shutdown test's hung seat, should the server have failed to stop it.
    # SIGKILL, since some of them ignore SIGTERM.
    pkill -9 -f 'sleep 97.3[1-9]' || true
    # No test, whatever it calls, may open a listening socket.
    if grep -q '"listen"' "$COUNCIL_FENCE_LOG" 2>/dev/null; then
        echo "the server tried to listen on a socket" >&2
        return 1
    fi
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

@test "extension: a line over 1 MiB is dropped with an invalid request error, and serving goes on" {
    mcp "$(head -c 1048577 /dev/zero | tr '\0' x)" '{"jsonrpc":"2.0","id":7,"method":"ping"}'
    [ "$status" -eq 0 ]
    assert_eq "$(printf '%s\n' "$output" | sed -n 1p)" '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"invalid request: a line over 1048576 bytes was dropped"}}'
    assert_eq "$(reply 7)" '{"jsonrpc":"2.0","id":7,"result":{}}'
    assert_eq "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" 2
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

@test "extension: tools/list hides the three panel tools from the model and ties each panel to its tool" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    # Each address's hash is checked against its page in a test of its own.
    assert_eq "$(reply 1 | jq -c '[.result.tools[] | {name, ui: ._meta.ui} | if .ui.resourceUri then .ui.resourceUri |= sub("/[0-9a-f]{12}$"; "/<hash>") end]')" \
        '[{"name":"council_ask","ui":{"resourceUri":"ui://council/answers/<hash>"}},{"name":"council_pick","ui":{"resourceUri":"ui://council/pick/<hash>"}},{"name":"council_pick_ask","ui":{"visibility":["app"]}},{"name":"council_result","ui":null},{"name":"council_status","ui":null},{"name":"council_settings","ui":{"resourceUri":"ui://council/settings/<hash>"}},{"name":"council_models_data","ui":{"visibility":["app"]}},{"name":"council_models_save","ui":{"visibility":["app"]}}]'
}

@test "extension: the three panels are served as MCP App pages, the shared parts inlined" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' \
        '{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"{{1.result.resources.0.uri}}"}}' \
        '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"{{1.result.resources.1.uri}}"}}' \
        '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"{{1.result.resources.2.uri}}"}}'
    # Each address's hash is checked against its page in a test of its own.
    assert_eq "$(reply 1 | jq -c '[.result.resources[] | .uri |= sub("/[0-9a-f]{12}$"; "/<hash>")]')" \
        '[{"uri":"ui://council/settings/<hash>","name":"Council models","mimeType":"text/html;profile=mcp-app"},{"uri":"ui://council/answers/<hash>","name":"Council answers","mimeType":"text/html;profile=mcp-app"},{"uri":"ui://council/pick/<hash>","name":"Council picker","mimeType":"text/html;profile=mcp-app"}]'
    local at
    for at in 0 1 2; do
        assert_eq "$(reply $((at + 2)) | jq -r '.result.contents[0].mimeType')" 'text/html;profile=mcp-app'
    done
    local settings answers part
    settings=$(reply 2 | jq -r '.result.contents[0].text')
    answers=$(reply 3 | jq -r '.result.contents[0].text')
    [[ "$settings" == '<!doctype html>'* && "$answers" == '<!doctype html>'* ]] || false
    [[ "$settings" != *'@include'* && "$answers" != *'@include'* ]] || false
    for part in panel-style.css panel-host.js panel-page.js marks.js markdown.js seat-cards.js seat-cards.css model-list.js model-list.css; do
        [ -s "${PROJECT_ROOT}/extension/server/${part}" ]
    done
    for part in panel-style.css panel-host.js panel-page.js marks.js; do
        [[ "$settings" == *"$(cat "${PROJECT_ROOT}/extension/server/${part}")"* ]] || false
        [[ "$answers" == *"$(cat "${PROJECT_ROOT}/extension/server/${part}")"* ]] || false
    done
    local pick
    pick=$(reply 4 | jq -r '.result.contents[0].text')
    [[ "$pick" == '<!doctype html>'* && "$pick" != *'@include'* ]] || false
    for part in panel-style.css panel-host.js panel-page.js marks.js markdown.js seat-cards.js seat-cards.css model-list.js model-list.css; do
        [[ "$pick" == *"$(cat "${PROJECT_ROOT}/extension/server/${part}")"* ]] || false
    done
    for part in model-list.js model-list.css; do
        [[ "$settings" == *"$(cat "${PROJECT_ROOT}/extension/server/${part}")"* ]] || false
    done
    for part in markdown.js seat-cards.js seat-cards.css; do
        [[ "$answers" == *"$(cat "${PROJECT_ROOT}/extension/server/${part}")"* ]] || false
    done
}

@test "extension: council_ask's description fits whether or not the app draws the answers panel" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    [[ "$(reply 1 | jq -r '.result.tools[0].description')" == *"Claude Desktop shows every seat's answer in a panel above your reply, so do not repeat the answers"* ]]
    mcp '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"plain","version":"0"}}}' \
        '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    [[ "$(reply 1 | jq -r '.result.tools[0].description')" == *"Show the user each seat's answer as returned, then"* ]]
}

@test "extension: council_ask asks for the user's question as they asked it, never a rewrite" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    local sentence="Pass the user's question as they asked it, adding context only when their message depends on earlier conversation the council cannot see."
    [[ "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_ask") | .description')" == *"$sentence"* ]]
    assert_eq "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_ask") | .inputSchema.properties.question.description')" \
        "The user's question, as they asked it."
    [[ "$(reply 1)" != *'self-contained'* ]]
}

@test "extension: council_ask runs at once on named seats or a verbosity, and council_pick takes every other question" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    local ask="Use it when the user named the seats or a verbosity, or said to just ask everyone; it then runs at once with the seats and verbosity given, or with every default seat at standard. When the user asks without naming either, or asks to choose them, call council_pick instead."
    local pick="Use it when the user asks the council without naming the seats or a verbosity, or asks to choose them; when the user named them or said to just ask everyone, call council_ask instead."
    [[ "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_ask") | .description')" == *"$ask"* ]]
    [[ "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_pick") | .description')" == *"$pick"* ]]
    [[ "$(reply 1)" != *'council_seats'* ]]
    assert_eq "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_ask") | .inputSchema.properties.providers.description')" \
        'Seat names, such as codex or openrouter-2. Leave out to ask every default seat.'
}

@test "extension: each panel's address carries the hash of its page as served, the same wherever it is named" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' '{"jsonrpc":"2.0","id":2,"method":"resources/list"}' \
        '{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"{{2.result.resources.0.uri}}"}}' \
        '{"jsonrpc":"2.0","id":11,"method":"resources/read","params":{"uri":"{{2.result.resources.1.uri}}"}}' \
        '{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"{{2.result.resources.2.uri}}"}}' \
        '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"ui://council/pick"}}'
    source "${LIB_DIR}/hash.sh"
    local at uri page
    for at in 0 1 2; do
        uri=$(reply 2 | jq -r --argjson at "$at" '.result.resources[$at].uri')
        page=$(echo settings answers pick | cut -d' ' -f$((at + 1)))
        [[ "$uri" =~ ^ui://council/${page}/[0-9a-f]{12}$ ]] || false
        assert_eq "$(reply $((at + 10)) | jq -r '.result.contents[0].uri')" "$uri"
        assert_eq "ui://council/${page}/$(reply $((at + 10)) | jq -j '.result.contents[0].text' | sha256_hex | cut -c1-12)" "$uri"
    done
    assert_eq "$(reply 1 | jq -c '[.result.tools[] | ._meta.ui.resourceUri | values]')" \
        "$(reply 2 | jq -c '[.result.resources[1].uri, .result.resources[2].uri, .result.resources[0].uri]')"
    assert_eq "$(reply 3)" '{"jsonrpc":"2.0","id":3,"error":{"code":-32002,"message":"resource not found: ui://council/pick"}}'
}

@test "extension: an unknown resource uri is an error naming it" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"ui://council/nope"}}'
    assert_eq "$(reply 1)" '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"resource not found: ui://council/nope"}}'
}

# ============================================================================
# council_ask
# ============================================================================

# A curl that stands in for the provider APIs, first on PATH. "answer" replies
# to a chat request with the model it was asked for and appends that model to
# $COUNCIL_FAKE_SENT_MODELS; "leak" fails the transfer after printing its --config file,
# which holds the Authorization header, to stderr; "keyed" answers with
# $COUNCIL_FAKE_PAD characters, then the OpenRouter key it was started with.
install_fake_curl() {
    local dir="${BATS_TEST_TMPDIR}/curlbin"
    mkdir -p "$dir"
    export COUNCIL_FAKE_SENT_MODELS="${BATS_TEST_TMPDIR}/sent-models" COUNCIL_FAKE_CURL_MODE="$1"
    cat > "$dir/curl" <<'CURL'
#!/bin/bash
out="" prev="" payload=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "--config" && "$COUNCIL_FAKE_CURL_MODE" == leak ]] && cat "$arg" >&2
    [[ "$prev" == "--data-binary" && "$arg" == @* ]] && payload="${arg#@}"
    prev="$arg"
done
if [[ "$COUNCIL_FAKE_CURL_MODE" == leak ]]; then
    echo "curl: (7) Failed to connect" >&2
    printf '000'
    exit 7
fi
model=$(jq -r '.model' "$payload")
printf '%s\n' "$model" >> "$COUNCIL_FAKE_SENT_MODELS"
if [[ "$COUNCIL_FAKE_CURL_MODE" == echo ]]; then
    # Long enough that two runs asked together are both in flight.
    sleep 2
    jq -c '{choices: [{message: {content: ("asked: " + .messages[-1].content)}}]}' "$payload" > "$out"
elif [[ "$COUNCIL_FAKE_CURL_MODE" == huge ]]; then
    jq -cn '{choices: [{message: {content: ("x" * 9000000)}}]}' > "$out"
elif [[ "$COUNCIL_FAKE_CURL_MODE" == long ]]; then
    jq -cn '{choices: [{message: {content: ("start " + ("x" * 150000) + " end")}}]}' > "$out"
elif [[ "$COUNCIL_FAKE_CURL_MODE" == keyed ]]; then
    jq -cn --argjson pad "$COUNCIL_FAKE_PAD" --arg key "$OPENROUTER_API_KEY" \
        '{choices: [{message: {content: (("x" * $pad) + $key + " tail")}}]}' > "$out"
elif [[ "$COUNCIL_FAKE_CURL_MODE" == colour ]]; then
    jq -cn --arg m "$model" '{choices: [{message: {content: ("\u001b[1manswer\u001b[0m from " + $m)}}]}' > "$out"
else
    jq -cn --arg m "$model" '{choices: [{message: {content: ("answer from " + $m)}}]}' > "$out"
fi
printf '200'
CURL
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
}

@test "extension: council_ask refuses a question that is empty or blank, running nothing" {
    mcp "$INIT" "$(call 1 council_ask '{"question":""}')" "$(call 2 council_ask '{"question":"  \n "}')" "$(call 3 council_ask '{}')"
    for id in 1 2 3; do
        assert_eq "$(result_error $id)" true
        assert_eq "$(result_text $id)" 'The question is empty. Pass the question the user asked.'
    done
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

@test "extension: council_ask refuses a provider that does not exist, naming it and the real ones" {
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["../openai"]}')" \
        "$(call 2 council_ask '{"question":"q","providers":[]}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" '"../openai" is not a council provider. Known providers: antigravity, claude-cli, codex, copilot-cli, cursor-cli, gemini, grok, grok-cli, kimi, kimi-cli, ollama, openai, opencode, openrouter, perplexity, and openrouter-1 to openrouter-12 for saved OpenRouter seats.'
    assert_eq "$(result_text 2)" 'providers must list at least one provider name, or be left out to ask every configured provider'
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

@test "extension: council_ask refuses a question over 100000 bytes, which argv may not carry" {
    local over at_limit
    over=$(printf '%050001d' 0 | sed 's/0/é/g')
    at_limit=$(printf '%050000d' 0 | sed 's/0/é/g')
    mcp "$INIT" "$(call 1 council_ask "$(jq -cn --arg q "$over" '{question: $q}')")" \
        "$(call 2 council_ask "$(jq -cn --arg q "$at_limit" '{question: $q, providers: ["codex"]}')")"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'The question is 100002 bytes long; the council takes at most 100000. Shorten it, or say the rest in fewer words.'
    assert_eq "$(result_error 2)" false
    assert_eq "$(jq -s length "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl")" 1
}

@test "extension: a council run that writes more than 8 MiB is stopped, and says so" {
    install_fake_curl huge
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'The council run wrote more than 8 MiB, more than any set of answers needs, so it was stopped.'
}

@test "extension: council_ask refuses a bad verbosity and an argument it does not take" {
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","verbosity":"loud"}')" \
        "$(call 2 council_ask '{"question":"q","model":"x"}')"
    assert_eq "$(result_text 1)" 'verbosity must be brief, standard or detailed, not "loud"'
    assert_eq "$(result_text 2)" 'council_ask has no argument "model"; it takes question, providers and verbosity'
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

# A tool result's structuredContent, compact.
result_seats() {
    reply "$1" | jq -c '.result.structuredContent'
}

@test "extension: council_ask returns each seat's answer as text and as seats, in the order they ran" {
    install_fake_curl answer
    export COUNCIL_FAKE_BEHAVIOR=valid OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha"]}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"Which queue?","providers":["openrouter-1","codex"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_seats 1)" \
        '{"question":"Which queue?","seats":[{"provider":"openrouter-1","model":"vendor/alpha","answer":"answer from vendor/alpha"},{"provider":"codex","model":"default","answer":"FAKE-CODEX-RESPONSE: deterministic answer"}]}'
    # The text is format-output.sh's transcript, which orders seats by name.
    [[ "$(result_text 1)" == *"## ● Codex - default"*"FAKE-CODEX-RESPONSE: deterministic answer"*"## ● Openrouter-1 - vendor/alpha"*"answer from vendor/alpha"* ]]
}

@test "extension: a seat's error reaches the seats as an error, never as an answer" {
    install_fake_curl answer
    export COUNCIL_FAKE_BEHAVIOR=error OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex","openrouter"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_seats 1 | jq -c '[.seats[] | {provider, answer, error: (.error != null)}]')" \
        '[{"provider":"codex","answer":null,"error":true},{"provider":"openrouter","answer":"answer from anthropic/claude-fable-5.2","error":false}]'
    assert_eq "$(result_seats 1 | jq -r '.seats[0].error')" 'Error from codex CLI: Error: fake provider failure'
}

@test "extension: a long answer reaches the model whole, and the panel its first 100000 characters, marked shortened" {
    install_fake_curl long
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" false
    [[ "$(result_text 1)" == *"start xxx"*"xxx end"* ]]
    assert_eq "$(result_seats 1 | jq -c '.seats[0] | {length: (.answer | length), shortenedFrom, tail: .answer[-3:]}')" \
        '{"length":100000,"shortenedFrom":150010,"tail":"xxx"}'
}

@test "extension: a key where the panel's cut falls in a long answer is removed whole, no part of it left" {
    install_fake_curl keyed
    export OPENROUTER_API_KEY="$SENTINEL_KEY" COUNCIL_FAKE_PAD=99990
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" false
    # 99990 characters, then the 13 of "[key removed]" and " tail": 100008, cut at 100000.
    assert_eq "$(result_seats 1 | jq -c '.seats[0] | {length: (.answer | length), shortenedFrom, tail: .answer[-13:]}')" \
        '{"length":100000,"shortenedFrom":100008,"tail":"xxx[key remov"}'
}

@test "extension: colour codes in a seat's answer or error reach neither the text nor the seats" {
    install_fake_curl colour
    export COUNCIL_FAKE_BEHAVIOR=noisy-error OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha"]}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex","openrouter-1"]}')"
    assert_eq "$(result_error 1)" false
    [[ "$(result_seats 1 | jq -r '.seats[0].error')" == *'Error: cause after the noise' ]]
    assert_eq "$(result_seats 1 | jq -r '.seats[1].answer')" 'answer from vendor/alpha'
    [[ "$(result_text 1)" == *'Error: cause after the noise'*'answer from vendor/alpha'* ]]
    # JSON spells ESC as \u001b.
    [[ "$(reply 1)" != *'\u001b'* ]]
}

@test "extension: a run where every seat fails is still a result the panel can draw" {
    export COUNCIL_FAKE_BEHAVIOR=error
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex","grok-cli"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_seats 1 | jq -c '[.seats[] | [.provider, has("answer"), has("error")]]')" '[["codex",false,true],["grok-cli",false,true]]'
}

@test "extension: a failed council run returns the scripts' own error" {
    export COUNCIL_FAKE_BEHAVIOR=valid TMPDIR="${BATS_TEST_TMPDIR}/no-such-dir"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    assert_eq "$(result_error 1)" true
    # The second line is mktemp's own, worded differently by BSD and GNU.
    local text
    text=$(result_text 1)
    assert_eq "$(printf '%s\n' "$text" | sed -n 1p)" 'Council query failed:'
    [[ "$(printf '%s\n' "$text" | sed -n 2p)" == "mktemp: "*"${TMPDIR}/council-query."*": No such file or directory" ]]
}

@test "extension: a key quoted in a seat's error never leaves the server, nor lands in a state file" {
    install_fake_curl leak
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')" "$(call 2 council_settings)" "$(call 3 council_models_data)"
    [[ "$(result_text 1)" == *'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$(result_seats 1 | jq -r '.seats[0].error')" == *'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$output" != *"$SENTINEL_KEY"* ]]
    [[ "$stderr" != *"$SENTINEL_KEY"* ]]
    # grep exits 1 for no match, and 2 for a directory that is not there.
    [ -d "${STATE_DIR}/runs" ]
    run grep -rqF "$SENTINEL_KEY" "$STATE_DIR"
    [ "$status" -eq 1 ]
}

@test "extension: an answered run leaves neither its question nor a key its answer quoted under the state directory" {
    install_fake_curl keyed
    export OPENROUTER_API_KEY="$SENTINEL_KEY" COUNCIL_FAKE_PAD=0
    # As in Desktop, where nothing names a cache directory and the scripts'
    # own default is under the run's working directory.
    unset COUNCIL_CACHE_DIR
    mcp "$INIT" "$(call 1 council_ask '{"question":"Which ledger holds zebra-7431?","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_seats 1 | jq -r '.seats[0].answer')" '[key removed] tail'
    # grep exits 1 for no match, and 2 for a directory that is not there.
    [ -d "${STATE_DIR}/runs" ]
    run grep -rlF "$SENTINEL_KEY" "$STATE_DIR"
    assert_eq "$status $output" '1 '
    run grep -rlF 'zebra-7431' "$STATE_DIR"
    assert_eq "$status $output" '1 '
}

@test "extension: a seat past the saved OpenRouter roster is refused before anything runs" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha","vendor/beta"]}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter-1","openrouter-3"]}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'openrouter-3 is not a seat: the saved OpenRouter roster has 2 models. Choose OpenRouter models with the council_settings tool.'
    [ ! -e "$COUNCIL_FAKE_SENT_MODELS" ]
}

@test "extension: the saved OpenRouter roster reaches the run as one seat per model" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha","vendor/beta"]}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter-1","openrouter-2"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(sort "$COUNCIL_FAKE_SENT_MODELS" | paste -sd, -)" 'vendor/alpha,vendor/beta'
    [[ "$(result_text 1)" == *"answer from vendor/alpha"*"answer from vendor/beta"* ]]
}

@test "extension: model variables inherited from Desktop's environment are dropped" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY" COUNCIL_FAKE_BEHAVIOR=valid
    export OPENROUTER_MODEL=inherited/model OPENROUTER_1_MODEL=inherited/seat OPENROUTER_MODELS=inherited/roster
    # Nothing saved and no providers named: an inherited roster would add
    # its own seat to the council.
    mcp "$INIT" "$(call 1 council_ask '{"question":"q"}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(sort "$COUNCIL_FAKE_SENT_MODELS" | paste -sd, -)" "$(script_default openrouter)"
    # A saved roster: an inherited per-seat model would replace the saved one.
    rm "$COUNCIL_FAKE_SENT_MODELS"
    save_choices '{"openrouter":["vendor/alpha"]}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter-1"]}')"
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" vendor/alpha
}

@test "extension: a malformed models file is ignored for runs, and the answer and the status say so" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY" COUNCIL_FAKE_BEHAVIOR=valid
    save_choices '{"openai":"gpt-test-1","openrouter":"vendor/not-a-list"}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')" "$(call 2 council_status)"
    assert_eq "$(result_error 1)" false
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" "$(bash -c 'source "$1"; get_model openrouter' _ "${LIB_DIR}/providers.sh")"
    local notice="The saved model choices in ${STATE_DIR}/models.json could not be read (OpenRouter: expected a list of model ids, got \"vendor/not-a-list\"), so every provider uses its default model."
    assert_eq "$(result_text 1 | head -1)" "$notice"
    [[ "$(result_text 1)" == *"answer from "* ]]
    assert_eq "$(result_text 2 | tail -2 | head -1)" "$notice"
}

@test "extension: each seat, API or CLI, gets only its own vendor's key" {
    install_fake_curl answer
    export COUNCIL_FAKE_BEHAVIOR=valid
    local key
    for key in GEMINI_API_KEY OPENAI_API_KEY XAI_API_KEY PERPLEXITY_API_KEY KIMI_API_KEY OPENROUTER_API_KEY; do
        export "$key=placeholder-${key}"
    done
    # Keys the form never held, as a shell that started Desktop might export:
    # none may reach a seat, named in COUNCIL_PASS_ENV or not.
    export OPENAI_ADMIN_API_KEY=stray MOONSHOT_API_KEY=stray GROK_CLI_API_KEY=stray COUNCIL_PASS_ENV=OPENAI_ADMIN_API_KEY
    # Each seat's curl or CLI first records the *_API_KEY variables it was
    # started with, by the host it calls or its own name, then runs the fake
    # it stands in front of. A value that is not one of this test's
    # placeholders is recorded as such, so a failure never prints a real key.
    local spy="${BATS_TEST_TMPDIR}/spy" bin next
    export COUNCIL_SEAT_KEYS="${BATS_TEST_TMPDIR}/seat-keys.jsonl"
    mkdir -p "$spy"
    for bin in curl codex agy grok kimi cursor-agent claude copilot opencode ollama; do
        next=$(command -v "$bin")
        printf '#!/bin/bash\nwho=%s\nfor arg in "$@"; do [[ "$arg" == https://* ]] && who="${arg#https://}" && who="${who%%%%/*}"; done\njq -cn --arg who "$who" '"'"'{who: $who, keys: [env | to_entries[] | select(.key | endswith("_API_KEY")) | "\\(.key)=\\(if (.value | startswith("placeholder-")) then .value else "not-a-placeholder" end)"]}'"'"' >> "$COUNCIL_SEAT_KEYS"\nexec %q "$@"\n' \
            "$bin" "$next" > "${spy}/${bin}"
        chmod +x "${spy}/${bin}"
    done
    export PATH="${spy}:$PATH"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q"}')" "$(call 2 council_ask '{"question":"q","providers":["gemini","openai","grok","kimi","claude-cli","copilot-cli","opencode"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_error 2)" false
    # A CLI is preferred over its vendor's API, so the second question names
    # the API seats, and the CLI seats the first leaves out.
    assert_eq "$(jq -sc 'group_by(.who) | map({(.[0].who): (map(.keys) | add | unique)}) | add' "$COUNCIL_SEAT_KEYS")" \
        "$(jq -cn '{
            "agy": ["GEMINI_API_KEY=placeholder-GEMINI_API_KEY"],
            "api.moonshot.ai": ["KIMI_API_KEY=placeholder-KIMI_API_KEY"],
            "api.openai.com": ["OPENAI_API_KEY=placeholder-OPENAI_API_KEY"],
            "api.perplexity.ai": ["PERPLEXITY_API_KEY=placeholder-PERPLEXITY_API_KEY"],
            "api.x.ai": ["GROK_API_KEY=placeholder-XAI_API_KEY", "XAI_API_KEY=placeholder-XAI_API_KEY"],
            "claude": [],
            "codex": ["OPENAI_API_KEY=placeholder-OPENAI_API_KEY"],
            "copilot": [],
            "cursor-agent": [],
            "generativelanguage.googleapis.com": ["GEMINI_API_KEY=placeholder-GEMINI_API_KEY"],
            "grok": ["GROK_API_KEY=placeholder-XAI_API_KEY", "XAI_API_KEY=placeholder-XAI_API_KEY"],
            "kimi": ["KIMI_API_KEY=placeholder-KIMI_API_KEY"],
            "ollama": [],
            "opencode": [],
            "openrouter.ai": ["OPENROUTER_API_KEY=placeholder-OPENROUTER_API_KEY"]
        }')"
}

@test "extension: under Desktop's minimal PATH a CLI seat in ~/.local/bin is still found" {
    mkdir -p "${HOME}/.local/bin"
    cp "${FAKE_BIN_DIR}/codex" "${HOME}/.local/bin/codex"
    PATH=/usr/bin:/bin mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    assert_eq "$(result_error 1)" false
    [[ "$(result_text 1)" == *"FAKE-CODEX-RESPONSE: deterministic answer"* ]]
}

@test "extension: two questions asked at once each get their own answer" {
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    CLIENT_CONCURRENT=1 mcp "$INIT" "$(call 1 council_ask '{"question":"first question","providers":["openrouter"]}')" \
        "$(call 2 council_ask '{"question":"second question","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_error 2)" false
    local first second
    first=$(result_seats 1 | jq -r '.seats[0].answer')
    second=$(result_seats 2 | jq -r '.seats[0].answer')
    [[ "$first" == *"first question"* && "$first" != *"second question"* ]]
    [[ "$second" == *"second question"* && "$second" != *"first question"* ]]
}

# A codex seat that ignores SIGTERM, as a hung CLI can: it marks
# $STUBBORN_STARTED once running, then sleeps for the given seconds, a number
# no other process uses, so pgrep can find it.
stubborn_seat() {
    local dir="${BATS_TEST_TMPDIR}/stubborn"
    mkdir -p "$dir"
    STUBBORN_STARTED="${dir}/started"
    printf '#!/bin/bash\ntrap "" TERM\n: > "%s"\nexec sleep %s\n' "$STUBBORN_STARTED" "$1" > "${dir}/codex"
    chmod +x "${dir}/codex"
    export PATH="${dir}:$PATH"
}

# Runs one server session: writes the request lines, waits for a file matching
# the glob $1 to appear, then does $2 to the server: "cancel <id>" sends notifications/cancelled
# for that request and a ping with id 99, then holds the input open for
# DRIVE_HOLD_MS so a reply the server should not send has time to arrive,
# and just before closing it writes to $DRIVE_SEEN "there" or "gone": whether a process matching
# DRIVE_WATCH (a pgrep -f pattern) was still running, or with DRIVE_FILES set,
# whether a file matching that glob was still there; "signal <NAME>" sends the server that signal;
# "deafen" closes the reading end of the server's output and sends a ping, whose reply the server
# then cannot write. Leaves the server's stdout in
# $output and its exit code in $status, 128 plus the signal's number for a
# signal it died of.
drive() {
    local when="$1" action="$2"
    shift 2
    printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/requests.jsonl"
    DRIVE_SEEN="${BATS_TEST_TMPDIR}/seen"
    DRIVE_SEEN="$DRIVE_SEEN" run --separate-stderr "$NODE" -e '
        const { spawn } = require("node:child_process")
        const fs = require("node:fs")
        const os = require("node:os")
        const readline = require("node:readline")
        const [server, requests, when, action] = process.argv.slice(1)
        // Whether a file matches the absolute pattern, whose only wildcard is
        // *, matching within one path segment.
        const matched = pattern => pattern.split("/").slice(1).reduce((found, part) => found.flatMap(dir => {
          if (!part.includes("*")) return fs.existsSync(`${dir}/${part}`) ? [`${dir}/${part}`] : []
          if (!fs.statSync(dir).isDirectory()) return []
          const name = new RegExp(`^${part.split("*").map(piece => piece.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`)
          return fs.readdirSync(dir).filter(entry => name.test(entry)).map(entry => `${dir}/${entry}`)
        }), [""]).length > 0
        const child = spawn(process.execPath, [server], { stdio: ["pipe", "pipe", "inherit"] })
        readline.createInterface({ input: child.stdout }).on("line", line => process.stdout.write(`${line}\n`))
        for (const line of fs.readFileSync(requests, "utf8").split("\n").filter(Boolean)) child.stdin.write(`${line}\n`)
        const limit = setTimeout(() => {
          process.stderr.write(`no exit within 30 s; ${when} ${matched(when) ? "appeared" : "never appeared"}\n`)
          child.kill("SIGKILL")
          process.exit(124)
        }, 30000)
        const poll = setInterval(() => {
          if (!matched(when)) return
          clearInterval(poll)
          const [verb, argument] = action.split(" ")
          if (verb === "signal") return child.kill(argument)
          if (verb === "deafen") {
            child.stdout.destroy()
            return child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 99, method: "ping" })}\n`)
          }
          child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: Number(argument) } })}\n`)
          child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 99, method: "ping" })}\n`)
          setTimeout(() => {
            const there = process.env.DRIVE_FILES !== undefined
              ? matched(process.env.DRIVE_FILES)
              : require("node:child_process").spawnSync("pgrep", ["-f", process.env.DRIVE_WATCH]).status === 0
            fs.writeFileSync(process.env.DRIVE_SEEN, there ? "there" : "gone")
            child.stdin.end()
          }, Number(process.env.DRIVE_HOLD_MS))
        }, 50)
        child.on("exit", (code, signal) => {
          clearTimeout(limit)
          process.exit(code ?? 128 + os.constants.signals[signal])
        })
    ' "$SERVER" "${BATS_TEST_TMPDIR}/requests.jsonl" "$when" "$action"
}

@test "extension: input ending during a council run stops the run's whole group, a seat ignoring SIGTERM too" {
    stubborn_seat 97.31
    CLIENT_CLOSE_WHEN="$STUBBORN_STARTED" mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 1)" ''
    run ! pgrep -f 'sleep 97.31'
}

@test "extension: SIGTERM during a council run stops the run's whole group before the server exits" {
    stubborn_seat 97.33
    drive "$STUBBORN_STARTED" "signal SIGTERM" "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 143 ]
    assert_eq "$(reply 1)" ''
    run ! pgrep -f 'sleep 97.33'
}

@test "extension: SIGINT during a council run stops the run's whole group before the server exits" {
    stubborn_seat 97.34
    drive "$STUBBORN_STARTED" "signal SIGINT" "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 130 ]
    assert_eq "$(reply 1)" ''
    run ! pgrep -f 'sleep 97.34'
}

@test "extension: a reply that cannot be written, the server's output closed, stops the run's whole group before the server exits" {
    stubborn_seat 97.38
    drive "$STUBBORN_STARTED" "deafen" "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 1 ]
    run ! pgrep -f 'sleep 97.38'
}

@test "extension: a cancelled council question stops its run and is never answered; another goes on" {
    stubborn_seat 97.32
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    # Long enough for the stop's 2-second grace period and its SIGKILL.
    DRIVE_HOLD_MS=4000 DRIVE_WATCH='sleep 97.32' drive "$STUBBORN_STARTED" "cancel 1" "$INIT" \
        "$(call 1 council_ask '{"question":"first question","providers":["codex"]}')" \
        "$(call 2 council_ask '{"question":"second question","providers":["openrouter"]}')"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 1)" ''
    assert_eq "$(reply 99)" '{"jsonrpc":"2.0","id":99,"result":{}}'
    assert_eq "$(result_error 2)" false
    [[ "$(result_seats 2 | jq -r '.seats[0].answer')" == *"second question"* ]]
    # Seen while the server was still serving, so the cancel stopped the
    # run, not the server's exit.
    assert_eq "$(cat "$DRIVE_SEEN")" gone
    run ! pgrep -f 'sleep 97.32'
}

@test "extension: a status check writing more than 1 MiB to stderr is stopped, and says so" {
    # A plugin root whose status script floods stderr and then waits.
    local root="${BATS_TEST_TMPDIR}/flood"
    mkdir -p "${root}/scripts"
    printf '#!/bin/bash\nhead -c 1100000 /dev/zero | tr "\\0" x >&2\nexec sleep 97.36\n' > "${root}/scripts/check-status.sh"
    run --separate-stderr "$NODE" -e '
        const council = require(process.argv[1])
        const theCouncil = council.openCouncil({ root: process.argv[2], keys: new Map(), tooShort: [], redact: text => text })
        theCouncil.status({}, new AbortController().signal)
          .then(outcome => process.stdout.write(JSON.stringify(outcome)))
    ' "${PROJECT_ROOT}/extension/server/council.js" "$root"
    [ "$status" -eq 0 ]
    assert_eq "$output" '{"text":"The status check wrote more than 1 MiB of progress and errors, so it was stopped.","isError":true}'
    run ! pgrep -f 'sleep 97.36'
}

@test "extension: bash that cannot be started is a tool error saying so, and stopping every run still ends" {
    # Every file descriptor but two is taken, too few for a child's pipes.
    run --separate-stderr bash -c 'ulimit -n 64 && exec "$@"' _ "$NODE" -e '
        const fs = require("node:fs")
        const council = require(process.argv[1])
        const theCouncil = council.openCouncil({ root: process.argv[2], keys: new Map(), tooShort: [], redact: text => text })
        const taken = []
        try {
          for (;;) taken.push(fs.openSync("/dev/null", "r"))
        } catch (err) {
          if (err.code !== "EMFILE") throw err
        }
        fs.closeSync(taken.pop())
        fs.closeSync(taken.pop())
        theCouncil.status({}, new AbortController().signal).then(async outcome => {
          for (const fd of taken) fs.closeSync(fd)
          await theCouncil.stopRuns()
          process.stdout.write(JSON.stringify(outcome))
        })
    ' "${PROJECT_ROOT}/extension/server/council.js" "$PROJECT_ROOT"
    assert_eq "$status $output" '0 {"text":"could not start bash: spawn bash EMFILE\n\nIn Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure, not in exported variables. Models are chosen with the council_settings tool.","isError":true}'
}

@test "extension: a council run past its time limit is stopped, a seat ignoring SIGTERM too" {
    stubborn_seat 97.35
    run --separate-stderr "$NODE" -e '
        const council = require(process.argv[1])
        const { keys, tooShort } = council.readKeys(process.env)
        const theCouncil = council.openCouncil({ root: process.argv[2], keys, tooShort, redact: text => text, timeoutsMs: { ask: 4000, status: 4000, script: 30000 } })
        theCouncil.ask({ question: "q", providers: ["codex"] }, new AbortController().signal)
          .then(outcome => process.stdout.write(JSON.stringify(outcome)))
    ' "${PROJECT_ROOT}/extension/server/council.js" "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    assert_eq "$output" '{"text":"The council run took longer than 4 seconds and was stopped.","isError":true}'
    [ -e "$STUBBORN_STARTED" ]
    run ! pgrep -f 'sleep 97.35'
}

# ============================================================================
# Keys
# ============================================================================

# The model the scripts resolve for a provider with no override in force.
script_default() {
    env -u GEMINI_MODEL -u OPENAI_MODEL -u GROK_MODEL -u PERPLEXITY_MODEL -u KIMI_MODEL -u OPENROUTER_MODEL \
        bash -c 'source "$1"; get_model "$2"' _ "${LIB_DIR}/providers.sh" "$1"
}

@test "extension: a key field left empty, as an empty string or an unsubstituted placeholder, is no key" {
    export OPENROUTER_API_KEY='' GEMINI_API_KEY='${user_config.gemini_api_key}' KIMI_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(result_text 1 | jq -c '[.providers[] | {name, hasKey}]')" \
        '[{"name":"gemini","hasKey":false},{"name":"openai","hasKey":false},{"name":"grok","hasKey":false},{"name":"perplexity","hasKey":false},{"name":"kimi","hasKey":true},{"name":"openrouter","hasKey":false}]'
    assert_eq "$(jq -r '.fetch' "$COUNCIL_FENCE_LOG")" 'https://api.moonshot.ai/v1/models'
}

@test "extension: a key field holding under 8 characters is no key, and council_status names the field" {
    export GEMINI_API_KEY=1234567 OPENAI_API_KEY=2.0 XAI_API_KEY=x PERPLEXITY_API_KEY=' test ' COUNCIL_FAKE_BEHAVIOR=valid
    mcp "$INIT" "$(call 1 council_models_data)" "$(call 2 council_status)"
    assert_eq "$(result_text 1 | jq -c '[.providers[] | .hasKey] | unique')" '[false]'
    [ ! -s "$COUNCIL_FENCE_LOG" ]
    assert_eq "$(result_text 2 | tail -5)" 'The Gemini API key field holds under 8 characters, too short to be a key, so Gemini has no key.
The OpenAI API key field holds under 8 characters, too short to be a key, so OpenAI has no key.
The xAI API key (Grok) field holds under 8 characters, too short to be a key, so Grok has no key.
The Perplexity API key field holds under 8 characters, too short to be a key, so Perplexity has no key.
In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure, not in exported variables. Models are chosen with the council_settings tool.'
}

@test "extension: keys change nothing the server says about itself, even a key that occurs in its pages" {
    # Answered from the server alone: the envelope, tool names, schemas and
    # panel pages, none of which a key may change.
    local requests=("$INIT" '{"jsonrpc":"2.0","id":1,"method":"ping"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        '{"jsonrpc":"2.0","id":3,"method":"resources/list"}'
        '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"{{3.result.resources.0.uri}}"}}'
        '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"{{3.result.resources.1.uri}}"}}'
        '{"jsonrpc":"2.0","id":6,"method":"sampling/fly"}' "$(call 7 council_fly)")
    mcp "${requests[@]}"
    local keyless="$output"
    [[ "$keyless" == *'"jsonrpc":"2.0"'*'council_settings'*'text/html;profile=mcp-app'* ]] || false
    [[ "$(reply 4 | jq -r '.result.contents[0].text')" == '<!doctype html>'* ]] || false
    [[ "$(reply 5 | jq -r '.result.contents[0].text')" == '<!doctype html>'* ]] || false
    OPENAI_API_KEY=2.0 GEMINI_API_KEY=x KIMI_API_KEY=council_settings OPENROUTER_API_KEY=text/html mcp "${requests[@]}"
    [ "$status" -eq 0 ]
    assert_eq "$output" "$keyless"
}

# ============================================================================
# Panel data and saved choices
# ============================================================================

@test "extension: with no keys the panel data contacts no provider" {
    mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1 | jq -c '[.providers[] | [.hasKey, .models, .listError]] | unique')" '[[false,[],""]]'
    assert_eq "$(result_text 1 | jq -c '{rosterMax, problem}')" '{"rosterMax":12,"problem":""}'
    [ ! -s "$COUNCIL_FENCE_LOG" ]
}

@test "extension: a keyed provider's list is asked of its own endpoint only, following no redirect, and a failure says so" {
    export GEMINI_API_KEY="$SENTINEL_KEY" OPENROUTER_API_KEY="${SENTINEL_KEY}-router"
    mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(jq -sc 'sort_by(.fetch)' "$COUNCIL_FENCE_LOG")" \
        '[{"fetch":"https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000","authorized":true,"redirect":"error"},{"fetch":"https://openrouter.ai/api/v1/models","authorized":true,"redirect":"error"}]'
    assert_eq "$(result_text 1 | jq -c '[.providers[] | select(.hasKey) | {name, listError}]')" \
        '[{"name":"gemini","listError":"Could not load the model list (network fenced off in tests)"},{"name":"openrouter","listError":"Could not load the model list (network fenced off in tests)"}]'
}

@test "extension: a list failure quoting a key longer than the error shown leaves no part of the key in it" {
    # A line break inside a key makes the request's header invalid, and the
    # error for that quotes the header's whole value.
    local key
    key="sk-test-ab"$'\n'"$(printf '%0140d' 0)"
    GEMINI_API_KEY="$key" mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(result_text 1 | jq -r '.providers[] | select(.name == "gemini") | .listError')" \
        'Could not load the model list (Headers.append: "[key removed]" is an invalid header value.)'
}

@test "extension: panel data offers the scripts' default for each provider and the saved choice" {
    export GEMINI_MODEL=inherited-model
    save_choices '{"openai":"gpt-test-1","openrouter":["vendor/alpha"]}'
    mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(result_text 1 | jq -c '[.providers[] | [.name, .defaultModel, .selected]]')" \
        "$(jq -cn --arg g "$(script_default gemini)" --arg o "$(script_default openai)" --arg x "$(script_default grok)" \
            --arg p "$(script_default perplexity)" --arg k "$(script_default kimi)" --arg r "$(script_default openrouter)" \
            '[["gemini",$g,""],["openai",$o,"gpt-test-1"],["grok",$x,""],["perplexity",$p,""],["kimi",$k,""],["openrouter",$r,["vendor/alpha"]]]')"
}

# Octal permission bits of a file, on GNU or BSD stat.
mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

@test "extension: a state directory that is a symbolic link is refused, never followed" {
    local elsewhere="${BATS_TEST_TMPDIR}/elsewhere"
    mkdir -p "$elsewhere" "$XDG_CONFIG_HOME"
    chmod 755 "$elsewhere"
    ln -s "$elsewhere" "$STATE_DIR"
    mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openai":"gpt-test-1"}}')" \
        "$(call 2 council_ask '{"question":"q","providers":["codex"]}')"
    local refusal="The council's state directory ${STATE_DIR} is a symbolic link, which the extension does not follow. Remove the link and try again."
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" "$refusal"
    assert_eq "$(result_error 2)" true
    assert_eq "$(result_text 2)" "$refusal"
    assert_eq "$(mode_of "$elsewhere")" 755
    assert_eq "$(ls -A "$elsewhere")" ''
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

@test "extension: a models file that is a symbolic link is not read, and the answer says so" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    printf '%s\n' '{"openrouter":["vendor/alpha"]}' > "${BATS_TEST_TMPDIR}/planted.json"
    mkdir -p "$STATE_DIR"
    ln -s "${BATS_TEST_TMPDIR}/planted.json" "${STATE_DIR}/models.json"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(result_text 1 | head -1)" "The saved model choices in ${STATE_DIR}/models.json could not be read (the file is a symbolic link, which is not followed), so every provider uses its default model."
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" "$(script_default openrouter)"
}

@test "extension: a save writes every provider's choice, 0600 in a 0700 directory, nothing left behind" {
    mkdir -p "$STATE_DIR"
    chmod 755 "$STATE_DIR"
    mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openai":"gpt-test-1","openrouter":["vendor/alpha","~vendor/beta-latest"]}}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" '{"saved":true}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"","openai":"gpt-test-1","grok":"","perplexity":"","kimi":"","openrouter":["vendor/alpha","~vendor/beta-latest"]}'
    assert_eq "$(mode_of "${STATE_DIR}/models.json")" 600
    assert_eq "$(mode_of "$STATE_DIR")" 700
    assert_eq "$(ls -A "$STATE_DIR" | paste -sd, -)" 'models.json'
}

@test "extension: a model id shaped like a path that climbs or has an empty part is refused; real ids save" {
    mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openrouter":["a/../../../etc/x"]}}')" \
        "$(call 2 council_models_save '{"selections":{"gemini":"x:generateContent/../y"}}')" \
        "$(call 3 council_models_save '{"selections":{"openai":"gpt-6-astra/"}}')" \
        "$(call 4 council_models_save '{"selections":{"openrouter":["vendor//alpha"]}}')" \
        "$(call 5 council_models_save '{"selections":{"kimi":"./kimi-k3"}}')" \
        "$(call 6 council_models_save '{"selections":{"gemini":"gemini-3-pro","openai":"gpt-6-astra","perplexity":"xhigh","openrouter":["deepseek/deepseek-v4.1-flash","meta/llama-4:free","~vendor/beta-latest"]}}')"
    assert_eq "$(result_text 1)" 'Not saved: OpenRouter: "a/../../../etc/x" is not a model id.'
    assert_eq "$(result_text 2)" 'Not saved: Gemini: "x:generateContent/../y" is not a model id.'
    assert_eq "$(result_text 3)" 'Not saved: OpenAI: "gpt-6-astra/" is not a model id.'
    assert_eq "$(result_text 4)" 'Not saved: OpenRouter: "vendor//alpha" is not a model id.'
    assert_eq "$(result_text 5)" 'Not saved: Kimi: "./kimi-k3" is not a model id.'
    assert_eq "$(result_text 6)" '{"saved":true}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"gemini-3-pro","openai":"gpt-6-astra","grok":"","perplexity":"xhigh","kimi":"","openrouter":["deepseek/deepseek-v4.1-flash","meta/llama-4:free","~vendor/beta-latest"]}'
}

@test "extension: the state directory is under an absolute XDG_CONFIG_HOME, else under ~/.config" {
    mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openai":"gpt-test-1"}}')"
    assert_eq "$(jq -r .openai "${XDG_CONFIG_HOME}/council-extension/models.json")" gpt-test-1
    [ ! -e "${HOME}/.config" ]
    cd "$BATS_TEST_TMPDIR"
    XDG_CONFIG_HOME=relative-config mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openai":"gpt-test-2"}}')"
    assert_eq "$(jq -r .openai "${HOME}/.config/council-extension/models.json")" gpt-test-2
    [ ! -e "${BATS_TEST_TMPDIR}/relative-config" ]
}

@test "extension: a save with a bad model id is refused, naming it, and the file is left as it was" {
    save_choices '{"openai":"gpt-test-1"}'
    mcp "$INIT" "$(call 1 council_models_save '{"selections":{"openai":"gpt test; rm -rf ~"}}')" \
        "$(call 2 council_models_save '{"selections":{"openrouter":["a/1","a/2","a/3","a/4","a/5","a/6","a/7","a/8","a/9","a/10","a/11","a/12","a/13"]}}')" \
        "$(call 3 council_models_save '{"selections":{"mistral":"m"}}')" \
        "$(call 4 council_models_save '{"selections":{"openrouter":["a/1,a/2"]}}')"
    assert_eq "$(result_text 1)" 'Not saved: OpenAI: "gpt test; rm -rf ~" is not a model id.'
    assert_eq "$(result_text 2)" 'Not saved: OpenRouter: 13 models chosen, at most 12 seats.'
    assert_eq "$(result_text 3)" 'Not saved: "mistral" is not a provider the settings cover.'
    assert_eq "$(result_text 4)" 'Not saved: OpenRouter: "a/1,a/2" is not a model id.'
    for id in 1 2 3 4; do assert_eq "$(result_error $id)" true; done
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" '{"openai":"gpt-test-1"}'
}

@test "extension: a seat's model saved from the picker changes that seat alone, the rest and the roster order kept" {
    save_choices '{"openai":"gpt-test-1","perplexity":"sonar-test-1","openrouter":["vendor/alpha","vendor/beta","vendor/gamma"]}'
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"gemini","model":"gemini-3-pro"}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" '{"saved":true,"seat":"gemini","model":"gemini-3-pro"}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"gemini-3-pro","openai":"gpt-test-1","grok":"","perplexity":"sonar-test-1","kimi":"","openrouter":["vendor/alpha","vendor/beta","vendor/gamma"]}'
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter-2","model":"vendor/delta"}')"
    assert_eq "$(result_text 1)" '{"saved":true,"seat":"openrouter-2","model":"vendor/delta"}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"gemini-3-pro","openai":"gpt-test-1","grok":"","perplexity":"sonar-test-1","kimi":"","openrouter":["vendor/alpha","vendor/delta","vendor/gamma"]}'
    # Default: the saved choice is cleared, and the answer names the model the scripts fall back to.
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openai","model":""}')"
    assert_eq "$(result_text 1)" "$(jq -cn --arg m "$(script_default openai)" '{saved: true, seat: "openai", model: $m}')"
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"gemini-3-pro","openai":"","grok":"","perplexity":"sonar-test-1","kimi":"","openrouter":["vendor/alpha","vendor/delta","vendor/gamma"]}'
}

@test "extension: a settings save changes only the providers it names, a model the picker saved since the panel loaded kept" {
    save_choices '{"openai":"gpt-test-1","perplexity":"sonar-test-1","openrouter":["vendor/alpha","vendor/beta"]}'
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"gemini","model":"gemini-3-pro"}')" \
        "$(call 2 council_models_save '{"selections":{"openai":"gpt-test-2"}}')"
    assert_eq "$(result_text 2)" '{"saved":true}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"gemini-3-pro","openai":"gpt-test-2","grok":"","perplexity":"sonar-test-1","kimi":"","openrouter":["vendor/alpha","vendor/beta"]}'
}

@test "extension: a settings save adds one model to the end of the saved OpenRouter roster or takes one out, a seat the picker changed kept" {
    save_choices '{"openai":"gpt-test-1","openrouter":["vendor/alpha","vendor/beta","vendor/gamma"]}'
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter-2","model":"vendor/delta"}')" \
        "$(call 2 council_models_save '{"roster":{"remove":"vendor/gamma"}}')" \
        "$(call 3 council_models_save '{"roster":{"add":"vendor/epsilon"}}')" \
        "$(call 4 council_models_save '{"roster":{"add":"vendor/alpha"}}')" \
        "$(call 5 council_models_save '{"roster":{"remove":"vendor/never"}}')"
    local id
    for id in 2 3 4 5; do
        assert_eq "$(result_text "$id")" '{"saved":true}'
    done
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"","openai":"gpt-test-1","grok":"","perplexity":"","kimi":"","openrouter":["vendor/alpha","vendor/delta","vendor/epsilon"]}'
}

@test "extension: a settings save is refused when the saved choices cannot be opened, the file left as it was" {
    [ "$(id -u)" -ne 0 ] || skip "root opens a file of mode 000"
    save_choices '{"openai":"gpt-x"}'
    chmod 000 "${STATE_DIR}/models.json"
    mcp "$INIT" "$(call 1 council_models_save '{"roster":{"add":"a/3"}}')" \
        "$(call 2 council_models_save '{"selections":{"gemini":"gemini-x"}}')"
    chmod 600 "${STATE_DIR}/models.json"
    local id
    for id in 1 2; do
        assert_eq "$(result_error "$id")" true
        assert_eq "$(result_text "$id")" "Not saved: the saved model choices in ${STATE_DIR}/models.json could not be read (the file could not be opened: EACCES)."
    done
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" '{"openai":"gpt-x"}'
}

@test "extension: a roster change the choices cannot take is refused with a sentence, the file left as it was" {
    local full='{"openrouter":["a/1","a/2","a/3","a/4","a/5","a/6","a/7","a/8","a/9","a/10","a/11","a/12"]}'
    save_choices "$full"
    mcp "$INIT" "$(call 1 council_models_save '{"roster":{"add":"a/13"}}')" \
        "$(call 2 council_models_save '{"roster":{"remove":"a/1,a/2"}}')" \
        "$(call 3 council_models_save '{"roster":{"add":"a/13","remove":"a/1"}}')" \
        "$(call 4 council_models_save '{"roster":["a/13"]}')" \
        "$(call 5 council_models_save '{"roster":{"remove":7}}')" \
        "$(call 6 council_models_save '{"roster":{"remove":"a/1"},"selections":{}}')"
    assert_eq "$(result_text 1)" 'Not saved: OpenRouter: 13 models chosen, at most 12 seats.'
    assert_eq "$(result_text 2)" '{"saved":true}'
    assert_eq "$(result_text 3)" 'Not saved: expected one model id to add or one to remove, got {"add":"a/13","remove":"a/1"}.'
    assert_eq "$(result_text 4)" 'Not saved: expected one model id to add or one to remove, got ["a/13"].'
    assert_eq "$(result_text 5)" 'Not saved: expected one model id to add or one to remove, got {"remove":7}.'
    assert_eq "$(result_text 6)" 'Not saved: council_models_save takes selections, a roster change, or a seat and its model, one of them.'
    local id
    for id in 1 3 4 5 6; do
        assert_eq "$(result_error "$id")" true
    done
    assert_eq "$(jq -c '.openrouter' "${STATE_DIR}/models.json")" "$(jq -c '.openrouter' <<< "$full")"
    save_choices '{"openrouter":["a/1"]}'
    mcp "$INIT" "$(call 1 council_models_save '{"roster":{"add":"a/2,a/3"}}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'Not saved: OpenRouter: "a/2,a/3" is not a model id.'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" '{"openrouter":["a/1"]}'
}

@test "extension: with no roster saved, a model chosen for the openrouter seat starts the roster as openrouter-1" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"perplexity":"sonar-test-1"}'
    # Default on the single seat is what it already uses.
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter","model":""}')"
    assert_eq "$(result_text 1)" "$(jq -cn --arg m "$(script_default openrouter)" '{saved: true, seat: "openrouter", model: $m}')"
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter","model":"vendor/alpha"}')"
    assert_eq "$(result_text 1)" '{"saved":true,"seat":"openrouter-1","model":"vendor/alpha"}'
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" \
        '{"gemini":"","openai":"","grok":"","perplexity":"sonar-test-1","kimi":"","openrouter":["vendor/alpha"]}'
    mcp "$INIT" "$(call 1 council_pick '{"question":"q"}')" "$(call 2 council_pick_ask '{"question":"q","providers":["openrouter-1"]}')"
    assert_eq "$(result_seats 1 | jq -c '[.seats[] | select(.provider | startswith("openrouter"))]')" '[{"provider":"openrouter-1","model":"vendor/alpha"}]'
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" vendor/alpha
}

@test "extension: a seat's model the picker cannot save is refused with a sentence, the file left as it was" {
    local saved='{"openai":"gpt-test-1","openrouter":["vendor/alpha","vendor/beta"]}'
    save_choices "$saved"
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter-3","model":"vendor/gamma"}')" \
        "$(call 2 council_models_save '{"seat":"openrouter-1","model":"vendor/beta"}')" \
        "$(call 3 council_models_save '{"seat":"openrouter-1","model":""}')" \
        "$(call 4 council_models_save '{"seat":"openrouter","model":"vendor/gamma"}')" \
        "$(call 5 council_models_save '{"seat":"codex","model":"gpt-test-2"}')" \
        "$(call 6 council_models_save '{"seat":"ollama","model":"llama3"}')" \
        "$(call 7 council_models_save '{"seat":"gemini","model":"gemini 3; rm -rf ~"}')" \
        "$(call 8 council_models_save '{"seat":"openrouter-2","model":"a/1,a/2"}')" \
        "$(call 9 council_models_save '{"seat":"gemini"}')" \
        "$(call 10 council_models_save '{"seat":"gemini","model":"gemini-3-pro","selections":{}}')"
    assert_eq "$(result_text 1)" 'Not saved: openrouter-3 is not a seat: the saved OpenRouter roster has 2 models.'
    assert_eq "$(result_text 2)" 'Not saved: vendor/beta is already seat openrouter-2.'
    assert_eq "$(result_text 3)" 'Not saved: openrouter-1 needs a model; OpenRouter seats are removed in the council settings.'
    assert_eq "$(result_text 4)" 'Not saved: openrouter is not a seat while the saved OpenRouter roster has 2 models.'
    assert_eq "$(result_text 5)" 'Not saved: "codex" is not a seat whose model the council settings choose.'
    assert_eq "$(result_text 6)" 'Not saved: "ollama" is not a seat whose model the council settings choose.'
    assert_eq "$(result_text 7)" 'Not saved: Gemini: "gemini 3; rm -rf ~" is not a model id.'
    assert_eq "$(result_text 8)" 'Not saved: OpenRouter: "a/1,a/2" is not a model id.'
    assert_eq "$(result_text 9)" 'Not saved: expected a seat name and a model id, got "gemini" and undefined.'
    assert_eq "$(result_text 10)" 'Not saved: council_models_save takes selections, a roster change, or a seat and its model, one of them.'
    local id
    for id in 1 2 3 4 5 6 7 8 9 10; do assert_eq "$(result_error $id)" true; done
    assert_eq "$(jq -c . "${STATE_DIR}/models.json")" "$saved"
    # A file that cannot be read is not overwritten from the picker: the
    # choices it held would be lost to a set of one seat's model.
    save_choices '{"openrouter":"vendor/not-a-list"}'
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"gemini","model":"gemini-3-pro"}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" "Not saved: the saved model choices in ${STATE_DIR}/models.json could not be read (OpenRouter: expected a list of model ids, got \"vendor/not-a-list\"). Save a fresh set in the council settings."
    assert_eq "$(cat "${STATE_DIR}/models.json")" '{"openrouter":"vendor/not-a-list"}'
}

@test "extension: a model saved from the picker is the one council_pick then lists and council_pick_ask sends" {
    install_fake_curl answer
    pick_setup
    mcp "$INIT" "$(call 1 council_models_save '{"seat":"openrouter-2","model":"vendor/delta"}')"
    assert_eq "$(result_text 1)" '{"saved":true,"seat":"openrouter-2","model":"vendor/delta"}'
    mcp "$INIT" "$(call 1 council_pick '{"question":"q"}')" "$(call 2 council_pick_ask '{"question":"q","providers":["openrouter-2"]}')"
    assert_eq "$(result_seats 1 | jq -c '[.seats[] | select(.provider | startswith("openrouter"))]')" \
        '[{"provider":"openrouter-1","model":"vendor/alpha"},{"provider":"openrouter-2","model":"vendor/delta"}]'
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" vendor/delta
    assert_eq "$(result_seats 2 | jq -c '.seats')" '[{"provider":"openrouter-2","model":"vendor/delta","answer":"answer from vendor/delta"}]'
}

# ============================================================================
# Settings and status
# ============================================================================

@test "extension: council_settings lists each provider's model in plain text, and whether its key is set" {
    export OPENROUTER_API_KEY="$SENTINEL_KEY" XAI_API_KEY="${SENTINEL_KEY}-xai" KIMI_API_KEY="${SENTINEL_KEY}-kimi" OPENAI_MODEL=inherited-model
    save_choices '{"gemini":"gemini-test-1","grok":"grok-test-1","openrouter":["vendor/alpha","vendor/beta"]}'
    mcp "$INIT" "$(call 1 council_settings)"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" "Council models:
Gemini: gemini-test-1 (no key)
OpenAI: $(script_default openai) (default, no key)
Grok: grok-test-1 (key set)
Perplexity: $(script_default perplexity) (default, no key)
Kimi: $(script_default kimi) (default, key set)
OpenRouter: vendor/alpha, vendor/beta (2 seats, key set)

Change them in the panel shown with this result; a change applies to the next council question."
}

@test "extension: council_settings says a malformed models file was ignored, and where no panel is drawn" {
    save_choices '{"gemini":["not","a","string"]}'
    mcp '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"plain","version":"0"}}}' \
        "$(call 1 council_settings)"
    assert_eq "$(reply 0 | jq -r '.result.protocolVersion')" 2025-06-18
    assert_eq "$(result_text 1 | sed -n '9,$p')" "The saved model choices in ${STATE_DIR}/models.json could not be read (Gemini: [\"not\",\"a\",\"string\"] is not a model id), so every provider uses its default model.
This app does not show the settings panel, so these models cannot be changed here."
    assert_eq "$(result_text 1 | sed -n 2p)" "Gemini: $(script_default gemini) (default, no key)"
}

@test "extension: council_status gives the scripts' report, then where keys go in Desktop" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    mcp "$INIT" "$(call 1 council_status)"
    assert_eq "$(result_error 1)" false
    local text
    text=$(result_text 1)
    [[ "$text" == "Provider Status:"* ]]
    [[ "$(printf '%s\n' "$text" | grep '^  .*Gemini')" == *"API key not set"* ]]
    assert_eq "$(printf '%s\n' "$text" | tail -1)" 'In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure, not in exported variables. Models are chosen with the council_settings tool.'
}

# ============================================================================
# The council picker panel
# ============================================================================

# The seats the fake CLIs, a Perplexity key with a saved model and a saved
# OpenRouter roster of two make, as the scripts list them.
PICK_SEATS='[{"provider":"antigravity","model":"default"},{"provider":"codex","model":"default"},{"provider":"cursor-cli","model":"default"},{"provider":"grok-cli","model":"default"},{"provider":"kimi-cli","model":"default"},{"provider":"ollama","model":"local"},{"provider":"openrouter-1","model":"vendor/alpha"},{"provider":"openrouter-2","model":"vendor/beta"},{"provider":"perplexity","model":"sonar-test-1"}]'

pick_setup() {
    export OPENROUTER_API_KEY="$SENTINEL_KEY" PERPLEXITY_API_KEY="${SENTINEL_KEY}-pplx"
    save_choices '{"perplexity":"sonar-test-1","openrouter":["vendor/alpha","vendor/beta"]}'
}

@test "extension: council_pick gives its panel the question, each seat with its model and the verbosities, starting no agent" {
    pick_setup
    mcp "$INIT" "$(call 1 council_pick '{"question":"Which queue?"}')"
    assert_eq "$(result_error 1)" false
    # The panel waits 11.5 minutes for its run: the run's 10, formatting's half
    # minute, and one more for the stops and Desktop's relay.
    assert_eq "$(result_seats 1 | jq -c 'del(.run)')" "{\"question\":\"Which queue?\",\"seats\":${PICK_SEATS},\"verbosities\":[\"brief\",\"standard\",\"detailed\"],\"verbosity\":\"standard\",\"answerWithinMs\":690000}"
    local run
    run=$(result_seats 1 | jq -r '.run')
    [[ "$run" =~ ^[0-9a-f]{6}$ ]]
    assert_eq "$(result_text 1)" "The council picker is open in a panel with the question and 9 seats, as council run ${run}. Now, in this same turn and before you write anything, call council_result with run ${run}: it waits while the user picks the seats and the verbosity and presses Ask, and gives you the council's answers once they are in. Do not call council_ask for this question and do not answer it yourself. "'When the user then asks for the synthesis of a council run, as in "Synthesise the council'"'"'s answers (run 3f9a2c)", call council_result with that run id: it gives you the answers the panel shows. Never say you cannot see them.'
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

@test "extension: council_pick where no panel is drawn lists the seats and says to ask in the chat" {
    pick_setup
    mcp '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"plain","version":"0"}}}' \
        "$(call 1 council_pick '{"question":"Which queue?"}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" "This app does not draw the council picker. Ask the user in one short message which of these seats to use and which verbosity (standard, brief or detailed), offering all seats at standard as the default, then call council_ask with their choice.
antigravity: default
codex: default
cursor-cli: default
grok-cli: default
kimi-cli: default
ollama: local
openrouter-1: vendor/alpha
openrouter-2: vendor/beta
perplexity: sonar-test-1"
}

@test "extension: council_pick with no key and no agent says where keys go" {
    local dir
    for dir in "${HOME}/.local/bin" "${HOME}/bin" /opt/homebrew/bin /usr/local/bin; do
        for bin in codex agy grok kimi cursor-agent ollama; do
            [[ -x "${dir}/${bin}" ]] && skip "${dir}/${bin} is installed, and the server searches ${dir} as Desktop's does"
        done
    done
    PATH="$(dirname "$NODE"):/usr/bin:/bin" mcp "$INIT" "$(call 1 council_pick '{"question":"Which queue?"}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'No council seat is set up: no provider has a key and no CLI agent is installed. In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure.'
}

@test "extension: council_pick refuses an empty question, one over the cap and an unknown argument, as council_ask does" {
    local long
    long=$(head -c 100001 /dev/zero | tr '\0' q)
    mcp "$INIT" "$(call 1 council_pick '{"question":" "}')" "$(call 2 council_pick "$(jq -cn --arg q "$long" '{question: $q}')")" \
        "$(call 3 council_pick '{"question":"q","providers":["codex"]}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'The question is empty. Pass the question the user asked.'
    assert_eq "$(result_text 2)" 'The question is 100001 bytes long; the council takes at most 100000. Shorten it, or say the rest in fewer words.'
    assert_eq "$(result_text 3)" 'council_pick has no argument "providers"; it takes question'
}

@test "extension: council_pick_ask is council_ask: the same refusals and the same answer, with a run id beside it" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha"]}'
    local cases=('{"question":""}' '{"question":"q","providers":["nope"]}' '{"question":"q","providers":[]}'
        '{"question":"q","verbosity":"loud"}' '{"question":"q","model":"x"}' '{"question":"q","providers":["openrouter-2"]}'
        '{"question":"q","providers":["openrouter-1"],"verbosity":"brief"}')
    local requests=("$INIT") id
    for id in "${!cases[@]}"; do
        requests+=("$(call $((id + 1)) council_ask "${cases[$id]}")" "$(call $((id + 101)) council_pick_ask "${cases[$id]}")")
    done
    mcp "${requests[@]}"
    for id in "${!cases[@]}"; do
        [ -n "$(reply $((id + 1)))" ]
        assert_eq "$(reply $((id + 101)) | jq -c 'del(.id, .result.structuredContent.run, .result.structuredContent.awaited)')" "$(reply $((id + 1)) | jq -c 'del(.id)')"
    done
    assert_eq "$(result_error 101)" true
    assert_eq "$(result_seats 107 | jq -c 'del(.run)')" '{"question":"q","seats":[{"provider":"openrouter-1","model":"vendor/alpha","answer":"answer from vendor/alpha"}],"awaited":false}'
    [[ "$(result_seats 107 | jq -r '.run')" =~ ^[0-9a-f]{6}$ ]]
}

@test "extension: a key quoted in a seat's error never leaves the server through council_pick_ask" {
    install_fake_curl leak
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick_ask '{"question":"q","providers":["openrouter"]}')"
    [[ "$(result_seats 1 | jq -r '.seats[0].error')" == *'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$output" != *"$SENTINEL_KEY"* ]]
    [[ "$stderr" != *"$SENTINEL_KEY"* ]]
}

@test "extension: a cancelled council_pick_ask stops its run and is never answered" {
    stubborn_seat 97.37
    DRIVE_HOLD_MS=4000 DRIVE_WATCH='sleep 97.37' drive "$STUBBORN_STARTED" "cancel 1" "$INIT" \
        "$(call 1 council_pick_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 1)" ''
    assert_eq "$(reply 99)" '{"jsonrpc":"2.0","id":99,"result":{}}'
    assert_eq "$(cat "$DRIVE_SEEN")" gone
    run ! pgrep -f 'sleep 97.37'
}

# ============================================================================
# council_result: the picker's answers handed to the model
# ============================================================================

@test "extension: a cancelled council_pick_ask that then fails to end its picker is still never answered, and the failure is logged" {
    # A picker open for another ten minutes, and a codex seat that removes it
    # once running, so the cancelled ask finds no picker to write its outcome in.
    local pick
    pick="${STATE_DIR}/picks/$(printf '%015d' $((($(date +%s) + 600) * 1000)))-3f9a2c"
    mkdir -p "$pick"
    : > "${pick}/open"
    stubborn_seat 97.39
    printf '#!/bin/bash\ntrap "" TERM\nrm -rf "%s"\n: > "%s"\nexec sleep 97.39\n' "$pick" "$STUBBORN_STARTED" > "${BATS_TEST_TMPDIR}/stubborn/codex"
    DRIVE_HOLD_MS=4000 DRIVE_WATCH='sleep 97.39' drive "$STUBBORN_STARTED" "cancel 1" "$INIT" \
        "$(call 1 council_pick_ask '{"question":"q","providers":["codex"],"run":"3f9a2c"}')"
    local logged="$stderr"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 1)" ''
    assert_eq "$(reply 99)" '{"jsonrpc":"2.0","id":99,"result":{}}'
    run grep -cF 'council extension: council_pick_ask failed in a call that is never answered: Error: ENOENT' <<< "$logged"
    assert_eq "$output" 1
    run ! pgrep -f 'sleep 97.39'
}

@test "extension: council_result gives a picker run's answers by its id, as council_ask's own text" {
    install_fake_curl answer
    export COUNCIL_FAKE_BEHAVIOR=valid OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":["vendor/alpha"]}'
    local args='{"question":"Which queue?","providers":["openrouter-1","codex"]}'
    mcp "$INIT" "$(call 1 council_pick_ask "$args")" "$(call 2 council_result '{"run":"{{1.result.structuredContent.run}}"}')" \
        "$(call 3 council_ask "$args")"
    [[ "$(reply 1 | jq -r '.result.structuredContent.run')" =~ ^[0-9a-f]{6}$ ]]
    assert_eq "$(result_error 2)" false
    assert_eq "$(reply 2 | jq -c '.result | keys')" '["content","isError"]'
    [[ "$(result_text 2)" == *"## ● Codex - default"*"FAKE-CODEX-RESPONSE: deterministic answer"*"## ● Openrouter-1 - vendor/alpha"*"answer from vendor/alpha"* ]]
    assert_eq "$(result_text 2)" "$(result_text 3)"
    assert_eq "$(result_text 2 | tail -n 1)" 'answer from vendor/alpha'
}

@test "extension: council_result with no run gives the latest; an unknown run, or none yet, is a sentence saying to ask again" {
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_result)" "$(call 2 council_pick_ask '{"question":"first question","providers":["openrouter"]}')" \
        "$(call 3 council_pick_ask '{"question":"second question","providers":["openrouter"]}')" "$(call 4 council_result)" \
        "$(call 5 council_result '{"run":"{{2.result.structuredContent.run}}"}')" "$(call 6 council_result '{"run":"000000"}')" \
        "$(call 7 council_result '{"run":"run 1"}')"
    local kept='The extension keeps the last 5 picker runs in which a seat answered. Ask the council the question again.'
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" "No council run from the picker is held. ${kept}"
    [[ "$(result_text 3)" == *"asked: second question"* ]]
    assert_eq "$(result_error 4)" false
    assert_eq "$(result_text 4)" "$(result_text 3)"
    [[ "$(result_text 2)" == *"asked: first question"* ]]
    assert_eq "$(result_text 5)" "$(result_text 2)"
    assert_eq "$(result_error 6)" true
    assert_eq "$(result_text 6)" "Council run \"000000\" is not held. ${kept}"
    assert_eq "$(result_text 7)" "Council run \"run 1\" is not held. ${kept}"
}

@test "extension: council_result keeps the latest 5 picker runs, forgetting the oldest" {
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    local requests=("$INIT") id args
    for id in 1 2 3 4 5 6; do
        args="{\"question\":\"question ${id}\",\"providers\":[\"openrouter\"]}"
        requests+=("$(call "$id" council_pick_ask "$args")")
    done
    mcp "${requests[@]}" "$(call 11 council_result '{"run":"{{1.result.structuredContent.run}}"}')" \
        "$(call 12 council_result '{"run":"{{2.result.structuredContent.run}}"}')" "$(call 16 council_result '{"run":"{{6.result.structuredContent.run}}"}')"
    assert_eq "$(result_error 11)" true
    [[ "$(result_text 11)" == "Council run \"$(reply 1 | jq -r '.result.structuredContent.run')\" is not held."* ]]
    assert_eq "$(result_error 12)" false
    [[ "$(result_text 12)" == *"asked: question 2"* ]]
    assert_eq "$(result_text 12)" "$(result_text 2)"
    [[ "$(result_text 16)" == *"asked: question 6"* ]]
    assert_eq "$(result_text 16)" "$(result_text 6)"
}

@test "extension: a picker run where no seat answered, or one refused, gets no id and leaves the latest run as it was" {
    install_fake_curl leak
    export COUNCIL_FAKE_BEHAVIOR=valid OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick_ask '{"question":"q","providers":["codex"]}')" \
        "$(call 2 council_pick_ask '{"question":"q","providers":["openrouter"]}')" "$(call 3 council_pick_ask '{"question":""}')" \
        "$(call 4 council_result)"
    assert_eq "$(result_error 2)" false
    assert_eq "$(reply 2 | jq -c '.result.structuredContent | {run, answered: [.seats[] | has("answer")]}')" '{"run":null,"answered":[false]}'
    assert_eq "$(result_error 3)" true
    assert_eq "$(result_text 4)" "$(result_text 1)"
}

@test "extension: a key quoted in a held run's seat error never leaves the server through council_result" {
    install_fake_curl leak
    export COUNCIL_FAKE_BEHAVIOR=valid OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick_ask '{"question":"q","providers":["codex","openrouter"]}')" "$(call 2 council_result)"
    assert_eq "$(result_error 2)" false
    [[ "$(result_text 2)" == *'FAKE-CODEX-RESPONSE: deterministic answer'*'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$output" != *"$SENTINEL_KEY"* ]]
    [[ "$stderr" != *"$SENTINEL_KEY"* ]]
    [ -d "${STATE_DIR}/held" ]
    run ! grep -rqF "$SENTINEL_KEY" "${STATE_DIR}/held"
}

# Claude Desktop starts the extension twice, one copy for the panels' calls and
# one for the model's, so the copy that ran the question is not the one asked
# for its answers.
@test "extension: council_result gives a run that another copy of the server made, by id and as the latest" {
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick_ask '{"question":"asked in the panel","providers":["openrouter"]}')"
    local id text
    id="$(reply 1 | jq -r '.result.structuredContent.run')"
    text="$(result_text 1)"
    [[ "$text" == *"asked: asked in the panel"* ]]
    mcp "$INIT" "$(call 1 council_result "$(jq -cn --arg run "$id" '{run: $run}')")" "$(call 2 council_result)"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" "$text"
    assert_eq "$(result_text 2)" "$text"
    assert_eq "$(find "${STATE_DIR}/held" -type f -perm 600 | wc -l | tr -d ' ')" 1
    assert_eq "$(find "${STATE_DIR}/held" -type f | wc -l | tr -d ' ')" 1
}

@test "extension: council_result refuses an argument it does not take, and a run that is not a string" {
    mcp "$INIT" "$(call 1 council_result '{"question":"q"}')" "$(call 2 council_result '{"run":7}')"
    assert_eq "$(result_error 1)" true
    assert_eq "$(result_text 1)" 'council_result has no argument "question"; it takes run'
    assert_eq "$(result_error 2)" true
    assert_eq "$(result_text 2)" 'run must be a run id such as 3f9a2c, not 7'
}

@test "extension: council_pick and council_result tell the model to fetch a picker run's answers when the user asks for its synthesis" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    local sentence='When the user then asks for the synthesis of a council run, as in "Synthesise the council'"'"'s answers (run 3f9a2c)", call council_result with that run id: it gives you the answers the panel shows. Never say you cannot see them.'
    [[ "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_pick") | .description')" == *"$sentence"* ]]
    assert_eq "$(reply 1 | jq -r '.result.tools[] | select(.name == "council_result") | .description')" \
        'Get the answers of a council run made in the council picker panel. Right after council_pick, call it with the run council_pick named, in the same turn and before you write anything: it waits until the user presses Ask and the council answers. Also call it when the user asks for the synthesis of a council run, as in "Synthesise the council'"'"'s answers (run 3f9a2c)", passing that run id, or with no run for the latest run held, which it gives at once without waiting. The picker shows the answers to the user; this tool gives them to you, so never say you cannot see them. The user has already read each seat'"'"'s answer in the picker, so do not repeat them: write only your own synthesis, saying where the seats agree, where they differ, and what you recommend. The run holds only the seats the user chose in the picker, so the other seats of the council are not missing answers.'
}

# ============================================================================
# The synthesis in the turn that opened the picker
# ============================================================================

# A council_pick_ask request for the run council_pick gave in request 1.
ask_picked() {
    call "$1" council_pick_ask "{\"question\":\"q\",\"providers\":[\"openrouter\"],\"run\":\"{{1.result.structuredContent.run}}\"}"
}

@test "extension: a picked run asked with nobody waiting is held under its id and says it was not awaited; asked again it gets a fresh id" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick '{"question":"q"}')" "$(ask_picked 2)" "$(ask_picked 3)" \
        "$(call 4 council_pick_ask '{"question":"q","providers":["openrouter"],"run":"000000"}')"
    local picked
    picked=$(result_seats 1 | jq -r '.run')
    [[ "$picked" =~ ^[0-9a-f]{6}$ ]]
    assert_eq "$(result_seats 2 | jq -c '{run, awaited}')" "{\"run\":\"${picked}\",\"awaited\":false}"
    assert_eq "$(result_seats 3 | jq -r '.awaited')" false
    [[ "$(result_seats 3 | jq -r '.run')" =~ ^[0-9a-f]{6}$ ]]
    [ "$(result_seats 3 | jq -r '.run')" != "$picked" ]
    [[ "$(result_seats 4 | jq -r '.run')" =~ ^[0-9a-f]{6}$ ]]
    [ "$(result_seats 4 | jq -r '.run')" != 000000 ]
    assert_eq "$(result_text 2)" "$(result_text 3)"
}

# A council_pick_ask request for the run with the given id. The arguments go
# through a variable: bash 3.2 brace-expands a double-quoted JSON literal that
# sits inside a quoted command substitution.
ask_run() {
    local args="{\"question\":\"q\",\"providers\":[\"openrouter\"],\"run\":\"$2\"}"
    call "$1" council_pick_ask "$args"
}

# Starts, in the background, a server session that opens the picker and then
# waits in council_result for its run, as Claude does in the turn that opened
# it. Returns once the waiter's marker is in the state directory, with the run
# id in $PICKED_RUN; finish_waiter collects the session.
start_waiter() {
    local requests="${BATS_TEST_TMPDIR}/waiter.jsonl" tick
    printf '%s\n' "$INIT" "$(call 1 council_pick '{"question":"q"}')" \
        "$(call 2 council_result '{"run":"{{1.result.structuredContent.run}}"}')" > "$requests"
    WAITER_OUT="${BATS_TEST_TMPDIR}/waiter.out"
    "$NODE" "$CLIENT" "$SERVER" "$requests" > "$WAITER_OUT" 2> "${BATS_TEST_TMPDIR}/waiter.err" 3>&- &
    WAITER_PID=$!
    for tick in $(seq 1 300); do
        compgen -G "${STATE_DIR}/picks/*/waiting-*" > /dev/null && break
        sleep 0.1
    done
    compgen -G "${STATE_DIR}/picks/*/waiting-*" > /dev/null
    PICKED_RUN=$(jq -r 'select(.id == 1) | .result.structuredContent.run' "$WAITER_OUT")
}

finish_waiter() {
    local code=0
    wait "$WAITER_PID" || code=$?
    WAITER_PID=''
    assert_eq "$code" 0
    output=$(cat "$WAITER_OUT")
}

@test "extension: council_result waiting in one copy of the server gets the run another copy's picker ask made, and that ask says it was awaited" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    start_waiter
    mcp "$INIT" "$(ask_run 1 "$PICKED_RUN")"
    assert_eq "$(result_seats 1 | jq -c '{run, awaited}')" "{\"run\":\"${PICKED_RUN}\",\"awaited\":true}"
    local asked
    asked=$(result_text 1)
    finish_waiter
    assert_eq "$(result_error 2)" false
    assert_eq "$(result_text 2)" "${asked}

---
The user pressed Ask in the council picker, which asked openrouter, and has read every answer above in the panel. Do not repeat or summarise them seat by seat. Write your synthesis: where the seats agree, where they differ, and what you recommend."
    run ! compgen -G "${STATE_DIR}/picks/*/waiting-*"
}

@test "extension: a picker run in which every seat failed ends the waiting council_result with what failed, no key in it" {
    install_fake_curl leak
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    start_waiter
    mcp "$INIT" "$(ask_run 1 "$PICKED_RUN")"
    assert_eq "$(result_seats 1 | jq -c '{run, awaited}')" '{"run":null,"awaited":true}'
    local asked
    asked=$(result_text 1)
    finish_waiter
    assert_eq "$(result_text 2)" "Council run ${PICKED_RUN} from the picker ended with no answer. Tell the user what failed.

${asked}"
    [[ "$asked" == *'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$output" != *"$SENTINEL_KEY"* ]]
    run ! grep -rqF "$SENTINEL_KEY" "$STATE_DIR"
}

@test "extension: council_result's wait for a picker run runs out with a sentence saying Ask was not pressed, leaving no marker" {
    # The picker's wait, and so this one, is the run's limit plus the
    # formatting's plus the relay allowance: 7 seconds here.
    run --separate-stderr "$NODE" -e '
        const council = require(process.argv[1])
        const theCouncil = council.openCouncil({ root: process.argv[2], keys: new Map(), tooShort: [], redact: text => text,
          timeoutsMs: { ask: 1000, status: 1000, script: 5000, relay: 1000 } })
        const signal = new AbortController().signal
        theCouncil.pick({ question: "q" }, true, signal)
          .then(picked => theCouncil.result({ run: picked.structured.run }, signal).then(waited => ({ run: picked.structured.run, waited })))
          .then(outcome => process.stdout.write(JSON.stringify(outcome)))
    ' "${PROJECT_ROOT}/extension/server/council.js" "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    local picked
    picked=$(jq -r '.run' <<< "$output")
    [[ "$picked" =~ ^[0-9a-f]{6}$ ]]
    assert_eq "$(jq -c '.waited' <<< "$output")" "$(jq -cn --arg run "$picked" '{text: "The user has not pressed Ask in the council picker within 7 seconds of it opening. When they do, the picker drafts a message asking for the synthesis of run \($run); call council_result with that run then."}')"
    [ -d "${STATE_DIR}/picks" ]
    run ! compgen -G "${STATE_DIR}/picks/*/waiting-*"
}

@test "extension: council_result for a picker run still going past the picker's deadline says to call again, never to ask again, and then gives its answers" {
    install_fake_curl echo
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    # The picker's deadline is 10 seconds after it opens. Ask is pressed 8.5
    # seconds in and its seat takes 2 seconds, so the run ends after the deadline.
    run --separate-stderr "$NODE" -e '
        const council = require(process.argv[1])
        const { keys, tooShort } = council.readKeys(process.env)
        const theCouncil = council.openCouncil({ root: process.argv[2], keys, tooShort, redact: text => text,
          timeoutsMs: { ask: 6000, status: 1000, script: 3000, relay: 1000 } })
        const signal = new AbortController().signal
        const sleep = ms => new Promise(done => setTimeout(done, ms))
        const main = async () => {
          const run = (await theCouncil.pick({ question: "q" }, true, signal)).structured.run
          await sleep(8500)
          const asking = theCouncil.pickAsk({ question: "q", providers: ["openrouter"], run }, signal)
          await sleep(1800)
          const during = await theCouncil.result({ run }, signal)
          const asked = await asking
          const after = await theCouncil.result({ run }, signal)
          process.stdout.write(JSON.stringify({ run, during, asked: asked.text, after }))
        }
        main()
    ' "${PROJECT_ROOT}/extension/server/council.js" "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    local picked
    picked=$(jq -r '.run' <<< "$output")
    [[ "$picked" =~ ^[0-9a-f]{6}$ ]] || false
    assert_eq "$(jq -c '.during' <<< "$output")" "$(jq -cn --arg run "$picked" '{text: "The user pressed Ask in the council picker, and run \($run) has no outcome yet. Its answers may be seconds away: call council_result with run \($run) again shortly, and do not ask the council the question again."}')"
    assert_eq "$(jq -r '.after.text' <<< "$output")" "$(jq -r '.asked' <<< "$output")"
    [[ "$(jq -r '.asked' <<< "$output")" == *'asked: q'* ]]
}

@test "extension: a picker ask whose run id is not six hex digits is refused before anything is run or written" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    local runs=('"../held/x"' '"ABCDEF"' '"3f9a2"' '"3f9a2c0"' '7' '""')
    local requests=("$INIT") at args
    for at in "${!runs[@]}"; do
        args="{\"question\":\"q\",\"providers\":[\"openrouter\"],\"run\":${runs[$at]}}"
        requests+=("$(call $((at + 1)) council_pick_ask "$args")")
    done
    mcp "${requests[@]}"
    for at in "${!runs[@]}"; do
        assert_eq "$(result_error $((at + 1)))" true
        assert_eq "$(result_text $((at + 1)))" "run must be a run id of six hex digits, such as 3f9a2c, not ${runs[$at]}"
    done
    [ ! -e "$STATE_DIR" ]
    [ ! -e "$COUNCIL_FAKE_SENT_MODELS" ]
}

@test "extension: a waiter's marker untouched for just over 2 seconds is a dead waiter's, and a picker ask then says nobody was waiting" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_pick '{"question":"q"}')"
    local picked
    picked=$(result_seats 1 | jq -r '.run')
    local marker ready="${BATS_TEST_TMPDIR}/aged" tick
    marker="$(compgen -G "${STATE_DIR}/picks/*-${picked}")/waiting-1-abcdef"
    : > "$marker"
    # Keeps the marker 2.3 seconds old for as long as the ask runs, just past
    # the 2 seconds after which a waiter counts as gone. Its life is bounded,
    # should the test fail before it is stopped.
    "$NODE" -e '
        const fs = require("node:fs")
        const [marker, ready] = process.argv.slice(1)
        const age = () => { const at = (Date.now() - 2300) / 1000; fs.utimesSync(marker, at, at) }
        age()
        fs.writeFileSync(ready, "")
        setInterval(age, 50)
        setTimeout(() => process.exit(0), 60000)
    ' "$marker" "$ready" 3>&- &
    AGER_PID=$!
    for tick in $(seq 1 100); do
        [ -e "$ready" ] && break
        sleep 0.1
    done
    [ -e "$ready" ]
    mcp "$INIT" "$(ask_run 1 "$picked")"
    kill "$AGER_PID"
    wait "$AGER_PID" || true
    AGER_PID=''
    assert_eq "$(result_seats 1 | jq -c '{run, awaited}')" "{\"run\":\"${picked}\",\"awaited\":false}"
}

@test "extension: council_result with no run gives the latest held run at once, while a picker is open" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    CLIENT_REPLY_WAIT_MS=30000 mcp "$INIT" "$(call 1 council_pick_ask '{"question":"q","providers":["openrouter"]}')" \
        "$(call 2 council_pick '{"question":"q"}')" "$(call 3 council_result)"
    [ "$status" -eq 0 ]
    assert_eq "$(result_error 3)" false
    assert_eq "$(result_text 3)" "$(result_text 1)"
}

@test "extension: a cancelled council_result waiting for a picker run removes its marker at once and is never answered" {
    mcp "$INIT" "$(call 1 council_pick '{"question":"q"}')"
    local picked
    picked=$(result_seats 1 | jq -r '.run')
    DRIVE_HOLD_MS=1000 DRIVE_FILES="${STATE_DIR}/picks/*/waiting-*" drive "${STATE_DIR}/picks/*-${picked}/waiting-*" "cancel 2" "$INIT" \
        "$(call 2 council_result "{\"run\":\"${picked}\"}")"
    [ "$status" -eq 0 ]
    assert_eq "$(reply 2)" ''
    assert_eq "$(reply 99)" '{"jsonrpc":"2.0","id":99,"result":{}}'
    # Seen while the server was still serving, so the cancel removed it, not
    # the server's exit.
    assert_eq "$(cat "$DRIVE_SEEN")" gone
}
