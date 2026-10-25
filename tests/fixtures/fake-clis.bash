# ABOUTME: Installs fake codex/agy/grok/kimi/cursor-agent/claude/copilot/opencode/ollama CLI executables onto PATH for hermetic tests
# ABOUTME: Behavior switches via COUNCIL_FAKE_BEHAVIOR; calls recorded as JSONL in COUNCIL_FAKE_STATE_DIR

# Behaviors (COUNCIL_FAKE_BEHAVIOR):
#   valid          - deterministic success response (default)
#   empty          - exit 0 with no output
#   error-result   - claude only: a JSON result event with is_error true, exit 0
#   malformed-json - syntactically broken JSON on stdout
#   block-verdict  - stop-gate reviewer reply whose first line is BLOCK:
#   long-block-verdict - the same verdict followed by 200 KB of review, several
#                    times what a pipe holds
#   rate-limit     - 429 message on stderr, exit 1
#   auth-failure   - login-required message on stderr, exit 1; claude answers
#                    `auth status` with loggedIn:false and exit 1, unless an
#                    ANTHROPIC_API_KEY is set, which the real CLI counts as
#                    logged in; copilot prints the real CLI's logged-out text;
#                    opencode answers `auth list` with its no-logins line, exit 0
#   slow           - sleep COUNCIL_FAKE_SLEEP (default 5s) then respond
#   hang           - exec sleep COUNCIL_FAKE_SLEEP (default 300s); replaces the
#                    process so the deadline watchdog's SIGTERM kills it cleanly
#   hang-handled   - sleep COUNCIL_FAKE_SLEEP but exit 0, silently, on SIGTERM:
#                    the codex wrapper's response to the deadline
#   error          - generic failure on stderr, exit 1
#   sandbox-failure - grok only: the two lines grok 1.0.46 prints when it cannot
#                    apply a --sandbox profile, exit 1; other fakes answer
#   noisy-error    - 70 KB of stderr ahead of the cause on its last line, exit 1:
#                    a CLI that echoes its banner and the whole prompt first,
#                    clears its progress line and hides the cursor, and
#                    colours the cause the way codex and agy do
#   binary-error   - a cause holding a byte that is not valid UTF-8, exit 1
#   sandbox-warning - grok only: the sandbox warning alone, then an unrelated
#                    failure, exit 1; other fakes answer
#   stdin-echo     - answers with whatever arrived on stdin, so a test can see
#                    whether the caller's stdin reached the CLI
#   dirty-stream   - kimi only: an unstructured notice line ahead of the JSONL,
#                    which a real CLI is free to print (upgrade notices etc.)
#   array-content  - kimi only: content as a [{type,text}] array rather than a
#                    string, the other shape the message format allows
#   tool-narration - kimi only: an assistant message carrying tool_calls, whose
#                    content narrates the call rather than answering
#   heads-up-note  - a heads-up side-check finding: codex under --output-schema
#                    writes it to the -o file and emits turn.completed; the
#                    others print the NOTE:/TAG:/TOPIC:/TITLE:/POINT: lines
#   heads-up-slow-note - codex only: the note after sleeping COUNCIL_FAKE_SLEEP
#                    (default 5s)
#   heads-up-none  - nothing to raise: codex writes {"none": true, ...}, the
#                    others print "NONE."
#   heads-up-blank - codex only: none false with an empty topic and headline,
#                    an answer that fits the schema and says nothing
#   heads-up-no-turn - codex only: writes a note, exits 0, but its events hold
#                    no turn.completed, as codex looks after a SIGTERM
#   heads-up-quota - codex only: the workspace is out of credits; its events
#                    end in error and turn.failed naming that, stderr holds
#                    unrelated MCP noise, exit 1
#   heads-up-turn-failed - codex only: turn.failed with a message that is not
#                    about credits, a line that is not JSON ahead of it, the
#                    same stderr noise, exit 1
#   off-contract   - a reply that neither starts NONE nor NOTE:, though it
#                    carries a NOTE: further along
#
# Every invocation appends {bin, args} to $COUNCIL_FAKE_STATE_DIR/calls.jsonl
# so tests can assert exactly what the plugin sent to the CLI.

install_fake_clis() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    COUNCIL_FAKE_STATE_DIR="${BATS_TEST_TMPDIR}/fake-state"
    mkdir -p "$FAKE_BIN_DIR" "$COUNCIL_FAKE_STATE_DIR"
    export FAKE_BIN_DIR COUNCIL_FAKE_STATE_DIR

    local bin
    for bin in codex agy grok kimi cursor-agent claude copilot opencode ollama; do
        write_fake_cli "$bin"
    done
    PATH="$FAKE_BIN_DIR:$PATH"
    export PATH
}

write_fake_cli() {
    local bin="$1"
    local marker
    marker="FAKE-$(echo "$bin" | tr '[:lower:]' '[:upper:]')-RESPONSE"
    cat > "$FAKE_BIN_DIR/$bin" <<EOF
#!/bin/bash
# Fake $bin CLI: records its invocation, then acts per COUNCIL_FAKE_BEHAVIOR
set -euo pipefail
jq -cn --arg bin "$bin" '{bin: \$bin, args: \$ARGS.positional}' --args -- "\$@" \\
    >> "\${COUNCIL_FAKE_STATE_DIR:?}/calls.jsonl"
# The value after the last <flag> in the arguments, empty when absent.
flag_value() {
    local flag="\$1" value="" prev="" a
    shift
    for a in "\$@"; do [[ "\$prev" == "\$flag" ]] && value="\$a"; prev="\$a"; done
    printf '%s' "\$value"
}
# Appends the environment variables named <prefix>* to <file> as one JSON line,
# merged over an optional JSON object of extra fields.
record_env() {
    jq -cn --arg p "\$1" --argjson extra "\${3:-null}" \\
        '(\$extra // {}) + (env | with_entries(select(.key | startswith(\$p))))' >> "\$2"
}
# Version probes succeed regardless of behavior, mirroring real CLIs where
# --version works even when logged out
if [[ "\${1:-}" == "--version" ]]; then
    echo "fake-$bin 0.0.1"
    exit 0
fi
EOF
    if [[ "$bin" == "agy" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# Only agy spills. A prompt past COUNCIL_ARGV_LIMIT is named inside the prompt
# prose rather than passed as its own argument, so recover it by shape and copy
# it out: the provider's trap deletes the original on exit, and tests need to
# see what crossed into the file versus what stayed on argv.
SPILLED=\$(printf '%s\\n' "\$@" | grep -o '[^[:space:]]*council-agy-prompt[^[:space:]]*' | head -1 || true)
if [[ -n "\${SPILLED:-}" && -f "\$SPILLED" ]]; then
    cp "\$SPILLED" "\${COUNCIL_FAKE_STATE_DIR:?}/spill.txt"
fi
EOF
    fi
    if [[ "$bin" == "codex" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<'EOF'
# The heads-up runner's structured call: codex exec --json ... --output-schema
# SCHEMA -o FILE -. The prompt arrives on stdin (kept for inspection), the
# answer goes to the -o file and the JSONL events to stdout. The real CLI exits
# 0 on SIGTERM, so only a turn.completed event says the turn finished.
if [[ " $* " == *" --output-schema "* ]]; then
    OUT=$(flag_value -o "$@")
    cat > "${COUNCIL_FAKE_STATE_DIR:?}/codex-stdin.txt"
    note='{"none":false,"tag":"Heads up","topic":"backfill never ran","headline":"The migration test used an empty fixture, so the backfill path never ran.","title":"The backfill path never ran","points":["The fixture had no rows, so the loop had nothing to do.","Seed one row in C:\\fixtures\\empty.db and rerun the migration test."]}'
    case "${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        heads-up-note|heads-up-slow-note)
            [[ "$COUNCIL_FAKE_BEHAVIOR" == heads-up-slow-note ]] && sleep "${COUNCIL_FAKE_SLEEP:-5}"
            echo '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000000"}'
            printf '%s\n' "$note" > "$OUT"
            echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            exit 0 ;;
        heads-up-none)
            echo '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000000"}'
            echo '{"none":true,"tag":"","topic":"","headline":"","title":"","points":[]}' > "$OUT"
            echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            exit 0 ;;
        heads-up-blank)
            echo '{"none":false,"tag":"Heads up","topic":"","headline":"","title":"","points":[]}' > "$OUT"
            echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            exit 0 ;;
        heads-up-no-turn)
            echo '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000000"}'
            printf '%s\n' "$note" > "$OUT"
            echo "codex: interrupted" >&2
            exit 0 ;;
        heads-up-quota)
            echo 'ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when AuthRequired(AuthRequiredError { www_authenticate_header: "Bearer" })' >&2
            echo '{"type":"turn.started"}'
            echo '{"type":"error","message":"Your workspace is out of credits. Add credits to continue."}'
            echo '{"type":"turn.failed","error":{"message":"Your workspace is out of credits. Add credits to continue."}}'
            exit 1 ;;
        heads-up-turn-failed)
            echo 'ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when AuthRequired(AuthRequiredError { www_authenticate_header: "Bearer" })' >&2
            echo '{"type":"turn.started"}'
            echo 'not json: a stray line the CLI printed'
            echo '{"type":"error","message":"stream disconnected before completion"}'
            echo '{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}'
            exit 1 ;;
    esac
fi
EOF
    fi
    if [[ "$bin" == "kimi" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real Kimi Code CLI answers --output-format stream-json with JSONL, one
# object per event: role "assistant" carries the answer (a long one arrives in
# several chunks that must be concatenated in order), role "meta" carries the
# resume hint. A fake that emits plain text here would only ever exercise
# kimi-cli.sh's error path, never its parser.
if [[ " \$* " == *" --output-format stream-json "* ]]; then
    case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        valid)
            echo '{"role":"assistant","content":"$marker: "}'
            echo '{"role":"assistant","content":"deterministic answer"}'
            echo '{"role":"meta","content":"To resume this session: kimi -r fake123"}'
            exit 0 ;;
        dirty-stream)
            echo "Update available: kimi 2.0 -> 2.1"
            echo '{"role":"assistant","content":"$marker: deterministic answer"}'
            exit 0 ;;
        array-content)
            echo '{"role":"assistant","content":[{"type":"text","text":"$marker: deterministic answer"}]}'
            exit 0 ;;
        tool-narration)
            echo '{"role":"assistant","content":"Let me check the directory.","tool_calls":[{"type":"function","id":"tc_1","function":{"name":"Shell","arguments":"{}"}}]}'
            echo '{"role":"tool","tool_call_id":"tc_1","content":"file1.py"}'
            echo '{"role":"assistant","content":"$marker: deterministic answer"}'
            exit 0 ;;
        empty)
            exit 0 ;;
    esac
fi
EOF
    fi
    if [[ "$bin" == "cursor-agent" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real Cursor CLI answers --output-format json with one object whose
# .result carries the whole answer and .usage the tokens, its input count
# leaving out the cached ones. A failure emits no JSON at all: the message
# goes to stderr and the exit is non-zero.
if [[ " \$* " == *" --output-format json "* ]]; then
    # A bare -p reads the prompt from stdin; keep a copy so a test can assert
    # what reached the CLI and that it never rode argv.
    if [[ " \$* " == *" -p --"* ]]; then
        cat > "\${COUNCIL_FAKE_STATE_DIR:?}/stdin.txt"
    fi
    case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        valid)
            echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"result":"$marker: deterministic answer","session_id":"fake","usage":{"inputTokens":20,"outputTokens":65,"cacheReadTokens":3000,"cacheWriteTokens":400}}'
            exit 0 ;;
        empty)
            echo '{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"fake"}'
            exit 0 ;;
        bad-model)
            # Names the model it was actually handed, so a provider that drops
            # --model on the floor cannot pass this case.
            MODEL=\$(flag_value --model "\$@")
            echo "Cannot use this model: \${MODEL:-none}. Available models: auto" >&2
            exit 1 ;;
    esac
fi
# The real Cursor CLI answers a logged-out "cursor-agent status" with
# "Not logged in" on stdout and exit 0, never a non-zero exit
if [[ "\${1:-}" == "status" && "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "auth-failure" ]]; then
    echo "Not logged in"
    exit 0
fi
EOF
    fi
    if [[ "$bin" == "claude" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# -p with no prompt argument reads the prompt from stdin; keep a copy so a
# test can assert what reached the CLI and that it never rode argv.
if [[ " \$* " == *" -p "* ]]; then
    cat > "\${COUNCIL_FAKE_STATE_DIR:?}/stdin.txt"
fi
# The real CLI answers -p --output-format json with a JSON array of events;
# the last, type "result", carries the answer, is_error, subtype and usage,
# whose input_tokens leave out the cache reads and writes. An API error or a
# reached usage limit still exits 0, with is_error true.
if [[ " \$* " == *" --output-format json "* ]]; then
    case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        valid)
            echo '[{"type":"system","subtype":"init"},{"type":"assistant"},{"type":"result","subtype":"success","is_error":false,"result":"$marker: deterministic answer","usage":{"input_tokens":30,"cache_creation_input_tokens":500,"cache_read_input_tokens":4000,"output_tokens":75}}]'
            exit 0 ;;
        empty)
            echo '[{"type":"system","subtype":"init"},{"type":"result","subtype":"success","is_error":false,"result":""}]'
            exit 0 ;;
        error-result)
            echo '[{"type":"system","subtype":"init"},{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded","usage":{"input_tokens":31,"cache_creation_input_tokens":0,"cache_read_input_tokens":4100,"output_tokens":0}}]'
            exit 0 ;;
        heads-up-none)
            echo '[{"type":"system","subtype":"init"},{"type":"result","subtype":"success","is_error":false,"result":"NONE.","usage":{"input_tokens":12,"cache_creation_input_tokens":800,"cache_read_input_tokens":5200,"output_tokens":3}}]'
            exit 0 ;;
    esac
fi
# The real CLI answers "claude auth status" with JSON on stdout: logged out
# is "loggedIn": false and exit 1, logged in is exit 0. An ANTHROPIC_API_KEY
# in the environment counts as logged in, whatever the claude.ai login says.
if [[ "\${1:-} \${2:-}" == "auth status" ]]; then
    if [[ "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "auth-failure" && -z "\${ANTHROPIC_API_KEY:-}" ]]; then
        echo '{"loggedIn": false, "authMethod": "none"}'
        exit 1
    fi
    echo '{"loggedIn": true, "authMethod": "claude.ai"}'
    exit 0
fi
EOF
    fi
    if [[ "$bin" == "copilot" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real CLI answers --output-format json with JSONL, one event per line,
# the answer in an assistant.message event's .data.content. These are the
# events copilot 1.0.98 printed for a one-word prompt with every tool off,
# its session.info notice included; deltas are left out. The two
# assistant.usage events, one per model request, follow the shape the CLI's
# event schema declares, input counting the cache reads and writes.
# With no -p it reads the prompt from stdin; keep a copy so a test can assert
# what reached the CLI and that it never rode argv.
if [[ " \$* " == *" --output-format json "* ]]; then
    cat > "\${COUNCIL_FAKE_STATE_DIR:?}/stdin.txt"
    case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        valid|empty)
            ANSWER="$marker: deterministic answer"
            [[ "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "empty" ]] && ANSWER=""
            echo '{"type":"session.info","data":{"infoType":"configuration","message":"Unknown tool name in the tool allowlist: \"none\""}}'
            echo '{"type":"session.mcp_servers_loaded","data":{"servers":[{"name":"github-mcp-server","status":"disabled","source":"builtin"}]}}'
            echo '{"type":"session.auto_mode_resolved","data":{"chosenModel":"example-model","availableModels":["example-model"]}}'
            echo '{"type":"session.tools_updated","data":{"model":"example-model"}}'
            echo '{"type":"user.message","data":{"content":"prompt"}}'
            jq -cn --arg a "\$ANSWER" '{type: "assistant.message", data: {model: "example-model", content: \$a, toolRequests: [], phase: "final_answer"}}'
            echo '{"type":"assistant.usage","ephemeral":true,"data":{"model":"example-model","inputTokens":1000,"outputTokens":50,"cacheReadTokens":600,"cacheWriteTokens":300,"reasoningTokens":20}}'
            echo '{"type":"assistant.usage","ephemeral":true,"data":{"model":"example-model","inputTokens":1500,"outputTokens":70,"cacheReadTokens":900,"cacheWriteTokens":0,"reasoningTokens":10}}'
            echo '{"type":"assistant.turn_end","data":{"turnId":"0"}}'
            echo '{"type":"result","sessionId":"fake","exitCode":0}'
            exit 0 ;;
        auth-failure)
            # The real CLI's logged-out stderr, word for word, exit 1.
            printf '%s\n' "Error: No authentication information found." "" \\
                "Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token." "" \\
                "To authenticate, you can use any of the following methods:" \\
                "  • Start 'copilot' and run the '/login' command" \\
                "  • Set the COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN environment variable" \\
                "  • Run 'gh auth login' to authenticate with the GitHub CLI" >&2
            exit 1 ;;
    esac
fi
EOF
    fi
    if [[ "$bin" == "opencode" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real CLI answers run --format json with one event per line, the answer
# in a "text" event's .part.text. These are the events opencode 2.1.3 printed
# for a one-word answer, ids shortened. With no message argument it reads the
# prompt from stdin; keep a copy so a test can assert what reached the CLI and
# that it never rode argv. Keep the OPENCODE_ variables too, and whether the
# config dir it was handed was an empty directory, so a test can assert what
# isolation the seat was given. Each run gets its own session id, kept in
# opencode-session.txt, so a test can assert the seat deleted that session.
# Each model request ends in a step_finish event carrying its tokens: input
# without the cache, output without the reasoning. The fake answers in two
# requests, so a seat that kept one step's tokens would show it.
if [[ "\${1:-}" == "run" && " \$* " == *" --format json "* ]]; then
    cat > "\${COUNCIL_FAKE_STATE_DIR:?}/stdin.txt"
    SID="ses_fake\${RANDOM}\${RANDOM}"
    echo "\$SID" > "\${COUNCIL_FAKE_STATE_DIR:?}/opencode-session.txt"
    CONFIG_EMPTY=false
    [[ -d "\${OPENCODE_CONFIG_DIR:-}" && -z "\$(ls -A "\$OPENCODE_CONFIG_DIR")" ]] && CONFIG_EMPTY=true
    record_env OPENCODE_ "\${COUNCIL_FAKE_STATE_DIR:?}/opencode-env.jsonl" "{\"config_dir_empty\":\$CONFIG_EMPTY}"
    case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
        valid|empty)
            ANSWER="$marker: deterministic answer"
            [[ "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "empty" ]] && ANSWER=""
            jq -cn --arg s "\$SID" '{type: "step_start", timestamp: 1, sessionID: \$s, part: {id: "prt_1", sessionID: \$s, messageID: "msg_1", type: "step-start", snapshot: "fake"}}'
            jq -cn --arg s "\$SID" '{type: "step_finish", timestamp: 2, sessionID: \$s, part: {id: "prt_2", sessionID: \$s, messageID: "msg_1", type: "step-finish", reason: "stop", cost: 0, tokens: {input: 200, output: 40, reasoning: 15, cache: {read: 3000, write: 100}}}}'
            jq -cn --arg s "\$SID" --arg a "\$ANSWER" '{type: "text", timestamp: 3, sessionID: \$s, part: {id: "prt_3", sessionID: \$s, messageID: "msg_2", type: "text", text: \$a, time: {start: 2, end: 3}}}'
            jq -cn --arg s "\$SID" '{type: "step_finish", timestamp: 4, sessionID: \$s, part: {id: "prt_4", sessionID: \$s, messageID: "msg_2", type: "step-finish", reason: "stop", cost: 0, tokens: {input: 50, output: 10, reasoning: 5, cache: {read: 3300, write: 0}}}}'
            exit 0 ;;
        bad-model)
            # The real CLI's unknown-model event on stdout, stderr empty, exit 1.
            # Names the model it was actually handed, so a provider that drops
            # -m on the floor cannot pass this case.
            MODEL=\$(flag_value -m "\$@")
            jq -cn --arg s "\$SID" --arg m "Model unavailable: \${MODEL:-none}" '{type: "error", timestamp: 1, sessionID: \$s, error: {type: "provider.no-route", message: \$m}}'
            exit 1 ;;
    esac
fi
# The real CLI answers "opencode session delete <id>" with this line, exit 0.
if [[ "\${1:-} \${2:-}" == "session delete" ]]; then
    echo "Session \${*: -1} deleted"
    exit 0
fi
# The real CLI answers "opencode auth list" with one row per stored login or
# vendor key, exit 0; with none it prints "No authenticated integrations",
# still exit 0. Keep the OPENCODE_ variables it saw, so a test can assert what
# the status probe hands it.
if [[ "\${1:-} \${2:-}" == "auth list" ]]; then
    record_env OPENCODE_ "\${COUNCIL_FAKE_STATE_DIR:?}/opencode-auth-env.jsonl"
    if [[ "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "auth-failure" ]]; then
        echo "No authenticated integrations"
        exit 0
    fi
    echo "Example    OAuth    stored"
    exit 0
fi
EOF
    fi
    if [[ "$bin" == "grok" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real grok CLI loads another vendor's hooks, rules, skills, agents, MCP
# servers and sessions unless GROK_<VENDOR>_<SURFACE>_ENABLED turns one off;
# keep each call's switches so a test can assert what the seat was given.
jq -cnS 'env | with_entries(select(.key | test("^GROK_[A-Z]+_[A-Z]+_ENABLED\$")))' \\
    >> "\${COUNCIL_FAKE_STATE_DIR:?}/grok-imports.jsonl"
# The real grok CLI answers a logged-out "grok models" with "You are not
# authenticated." on stdout and exit 0, never a non-zero exit
if [[ "\${1:-}" == "models" && "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "auth-failure" ]]; then
    echo "You are not authenticated."
    exit 0
fi
if [[ "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "sandbox-warning" ]]; then
    echo "warning: sandbox could not be applied: partial protection only" >&2
    echo "Error: 429 Too Many Requests" >&2
    exit 1
fi
if [[ " \$* " == *" --sandbox "* && "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "sandbox-failure" ]]; then
    echo "warning: sandbox could not be applied: socket deny resolution failed: could not resolve runtime-socket deny path /var/run/docker.sock: endpoint is a symlink" >&2
    echo "error: could not apply the 'read-only' sandbox profile; see the warning above for the cause. Refusing to start with its protections missing." >&2
    exit 1
fi
EOF
    fi
    cat >> "$FAKE_BIN_DIR/$bin" <<EOF
case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
    valid)          echo "$marker: deterministic answer" ;;
    empty)          ;;
    malformed-json) echo '{"unterminated": ' ;;
    block-verdict)  echo "BLOCK: tests are failing in the changed module" ;;
    long-block-verdict) echo "BLOCK: tests are failing in the changed module"; printf '%0200000d\\n' 0 ;;
    rate-limit)     echo "Error: 429 Too Many Requests" >&2; exit 1 ;;
    auth-failure)   echo "Error: not logged in" >&2; exit 1 ;;
    slow)           sleep "\${COUNCIL_FAKE_SLEEP:-5}"; echo "$marker: slow answer" ;;
    hang)           exec sleep "\${COUNCIL_FAKE_SLEEP:-300}" ;;
    hang-handled)   trap 'exit 0' TERM; sleep "\${COUNCIL_FAKE_SLEEP:-300}" & wait ;;
    hang-orphan)    trap 'exit 0' TERM; ( trap '' TERM; exec sleep "\${COUNCIL_FAKE_SLEEP:-300}" ) & wait ;;
    error)          echo "Error: fake provider failure" >&2; exit 1 ;;
    sandbox-failure) echo "$marker: deterministic answer" ;;
    noisy-error)    printf '%070000d\\n' 0 >&2
                    printf '\\033[2K\\033[?25l\\033[1m\\033[31mError:\\033[0m cause after the noise\\n' >&2; exit 1 ;;
    binary-error)   printf 'Error: caf\\351 broke\\n' >&2; exit 1 ;;
    sandbox-warning) echo "$marker: deterministic answer" ;;
    stdin-echo)     echo "$marker: stdin=[\$(cat)]" ;;
    heads-up-note)  printf '%s\\n' "NOTE: The retry loop never backs off, so a 429 storm hammers the API." \\
                        "TAG: You should know" "TOPIC: retry without backoff" "TITLE: Retries without backoff" \\
                        "POINT: Each retry fires at once." "POINT: Add a growing delay." ;;
    heads-up-none)  echo "NONE." ;;
    off-contract)   printf '%s\\n' "Here is a thought worth raising." "NOTE: the retries look off" "TOPIC: retries" ;;
    *)              echo "Unknown COUNCIL_FAKE_BEHAVIOR: \${COUNCIL_FAKE_BEHAVIOR}" >&2; exit 64 ;;
esac
EOF
    chmod +x "$FAKE_BIN_DIR/$bin"
}
