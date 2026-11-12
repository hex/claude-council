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
    # The shutdown test's hung seat, should the server have failed to stop it.
    pkill -f 'sleep 97.31' || true
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

# ============================================================================
# council_ask
# ============================================================================

# A curl that stands in for the provider APIs, first on PATH. "answer" replies
# to a chat request with the model it was asked for and appends that model to
# $COUNCIL_FAKE_SENT_MODELS; "leak" fails the transfer after printing its --config file,
# which holds the Authorization header, to stderr.
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
jq -cn --arg m "$model" '{choices: [{message: {content: ("answer from " + $m)}}]}' > "$out"
printf '200'
CURL
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
}

@test "extension: council_ask refuses a question that is empty or blank, running nothing" {
    mcp "$INIT" "$(call 1 council_ask '{"question":""}')" "$(call 2 council_ask '{"question":"  \n "}')" "$(call 3 council_ask '{}')"
    for id in 1 2 3; do
        assert_eq "$(result_error $id)" true
        assert_eq "$(result_text $id)" 'The question is empty. Ask a self-contained question: the council sees nothing else.'
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

@test "extension: council_ask refuses a bad verbosity and an argument it does not take" {
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","verbosity":"loud"}')" \
        "$(call 2 council_ask '{"question":"q","model":"x"}')"
    assert_eq "$(result_text 1)" 'verbosity must be brief, standard or detailed, not "loud"'
    assert_eq "$(result_text 2)" 'council_ask has no argument "model"; it takes question, providers and verbosity'
    [ ! -e "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" ]
}

@test "extension: council_ask returns the saved answer although the script prints its path relative to the run" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    mcp "$INIT" "$(call 1 council_ask '{"question":"Which queue?","providers":["codex"]}')"
    assert_eq "$(result_error 1)" false
    [[ "$(result_text 1)" == *"FAKE-CODEX-RESPONSE: deterministic answer"* ]]
    assert_eq "$(jq -r '.bin' "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl")" codex
    # Read and removed: no transcript is left behind in the run directory.
    assert_eq "$(find "${STATE_DIR}/runs" -name 'council-*.md' | wc -l | tr -d ' ')" 0
}

@test "extension: a failed council run returns the scripts' own error" {
    export COUNCIL_FAKE_BEHAVIOR=valid TMPDIR="${BATS_TEST_TMPDIR}/no-such-dir"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    assert_eq "$(result_error 1)" true
    # The third line is mktemp's own, worded differently by BSD and GNU.
    local text
    text=$(result_text 1)
    assert_eq "$(printf '%s\n' "$text" | sed -n 1,2p)" "$(printf '%s\n' 'Error: Invalid JSON input' 'Council query failed:')"
    [[ "$(printf '%s\n' "$text" | sed -n 3p)" == "mktemp: "*"${TMPDIR}/council-query."*": No such file or directory" ]]
}

@test "extension: a key quoted in a seat's error never leaves the server, nor lands in a state file" {
    install_fake_curl leak
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')" "$(call 2 council_settings)" "$(call 3 council_models_data)"
    [[ "$(result_text 1)" == *'header = "Authorization: Bearer [key removed]"'* ]]
    [[ "$output" != *"$SENTINEL_KEY"* ]]
    [[ "$stderr" != *"$SENTINEL_KEY"* ]]
    run ! grep -rqF "$SENTINEL_KEY" "$STATE_DIR"
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
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    export OPENROUTER_MODEL=inherited/model OPENROUTER_1_MODEL=inherited/seat OPENROUTER_MODELS=inherited/roster
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" "$(env -u OPENROUTER_MODEL bash -c 'source "$1"; get_model openrouter' _ "${LIB_DIR}/providers.sh")"
}

@test "extension: a malformed models file is ignored for runs" {
    install_fake_curl answer
    export OPENROUTER_API_KEY="$SENTINEL_KEY"
    save_choices '{"openrouter":"vendor/not-a-list"}'
    mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["openrouter"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(cat "$COUNCIL_FAKE_SENT_MODELS")" "$(bash -c 'source "$1"; get_model openrouter' _ "${LIB_DIR}/providers.sh")"
}

@test "extension: under Desktop's minimal PATH a CLI seat in ~/.local/bin is still found" {
    mkdir -p "${HOME}/.local/bin"
    cp "${FAKE_BIN_DIR}/codex" "${HOME}/.local/bin/codex"
    PATH=/usr/bin:/bin mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    assert_eq "$(result_error 1)" false
    [[ "$(result_text 1)" == *"FAKE-CODEX-RESPONSE: deterministic answer"* ]]
}

@test "extension: two questions asked at once each get their own answer" {
    CLIENT_CONCURRENT=1 mcp "$INIT" "$(call 1 council_ask '{"question":"first question","providers":["codex"]}')" \
        "$(call 2 council_ask '{"question":"second question","providers":["codex"]}')"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_error 2)" false
    assert_eq "$(jq -s 'length' "${COUNCIL_FAKE_STATE_DIR}/calls.jsonl")" 2
}

@test "extension: input ending during a council run stops the run with the server" {
    export COUNCIL_FAKE_BEHAVIOR=hang COUNCIL_FAKE_SLEEP=97.31
    CLIENT_CLOSE_WHEN="${COUNCIL_FAKE_STATE_DIR}/calls.jsonl" mcp "$INIT" "$(call 1 council_ask '{"question":"q","providers":["codex"]}')"
    [ "$status" -eq 0 ]
    sleep 1
    run ! pgrep -f 'sleep 97.31'
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

@test "extension: a keyed provider's list is asked of its own endpoint only, and a failure says so" {
    export GEMINI_API_KEY="$SENTINEL_KEY" OPENROUTER_API_KEY="${SENTINEL_KEY}-router"
    mcp "$INIT" "$(call 1 council_models_data)"
    assert_eq "$(jq -sc 'sort_by(.fetch)' "$COUNCIL_FENCE_LOG")" \
        '[{"fetch":"https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000","authorized":true},{"fetch":"https://openrouter.ai/api/v1/models","authorized":true}]'
    assert_eq "$(result_text 1 | jq -c '[.providers[] | select(.hasKey) | {name, listError}]')" \
        '[{"name":"gemini","listError":"Could not load the model list (network fenced off in tests)"},{"name":"openrouter","listError":"Could not load the model list (network fenced off in tests)"}]'
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

# ============================================================================
# Settings and status
# ============================================================================

@test "extension: council_settings lists each provider's model in plain text" {
    export OPENROUTER_API_KEY="$SENTINEL_KEY" OPENAI_MODEL=inherited-model
    save_choices '{"gemini":"gemini-test-1","openrouter":["vendor/alpha","vendor/beta"]}'
    mcp "$INIT" "$(call 1 council_settings)"
    assert_eq "$(result_error 1)" false
    assert_eq "$(result_text 1)" "Council models:
Gemini: gemini-test-1, no key
OpenAI: $(script_default openai) (default, no key)
Grok: $(script_default grok) (default, no key)
Perplexity: $(script_default perplexity) (default, no key)
Kimi: $(script_default kimi) (default, no key)
OpenRouter: 2 seats: vendor/alpha, vendor/beta

Change them in the panel shown with this result; a change applies to the next council question."
}

@test "extension: council_settings says a malformed models file was ignored, and where no panel is drawn" {
    save_choices '{"gemini":["not","a","string"]}'
    mcp '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"plain","version":"0"}}}' \
        "$(call 1 council_settings)"
    assert_eq "$(reply 0 | jq -r '.result.protocolVersion')" 2025-06-18
    assert_eq "$(result_text 1 | sed -n '9,$p')" "The saved choices in ${STATE_DIR}/models.json were ignored because Gemini: [\"not\",\"a\",\"string\"] is not a model id; the defaults apply.
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
