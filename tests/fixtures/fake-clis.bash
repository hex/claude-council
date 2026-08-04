# ABOUTME: Installs fake codex/agy/grok/kimi/ollama CLI executables onto PATH for hermetic tests
# ABOUTME: Behavior switches via COUNCIL_FAKE_BEHAVIOR; calls recorded as JSONL in COUNCIL_FAKE_STATE_DIR

# Behaviors (COUNCIL_FAKE_BEHAVIOR):
#   valid          - deterministic success response (default)
#   empty          - exit 0 with no output
#   malformed-json - syntactically broken JSON on stdout
#   block-verdict  - stop-gate reviewer reply whose first line is BLOCK:
#   rate-limit     - 429 message on stderr, exit 1
#   auth-failure   - login-required message on stderr, exit 1
#   slow           - sleep COUNCIL_FAKE_SLEEP (default 5s) then respond
#   hang           - exec sleep COUNCIL_FAKE_SLEEP (default 300s); replaces the
#                    process so an inherited SIGALRM (timeout) kills it cleanly
#   error          - generic failure on stderr, exit 1
#   dirty-stream   - kimi only: an unstructured notice line ahead of the JSONL,
#                    which a real CLI is free to print (upgrade notices etc.)
#   array-content  - kimi only: content as a [{type,text}] array rather than a
#                    string, the other shape the message format allows
#   tool-narration - kimi only: an assistant message carrying tool_calls, whose
#                    content narrates the call rather than answering
#
# Every invocation appends {bin, args} to $COUNCIL_FAKE_STATE_DIR/calls.jsonl
# so tests can assert exactly what the plugin sent to the CLI.

install_fake_clis() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    COUNCIL_FAKE_STATE_DIR="${BATS_TEST_TMPDIR}/fake-state"
    mkdir -p "$FAKE_BIN_DIR" "$COUNCIL_FAKE_STATE_DIR"
    export FAKE_BIN_DIR COUNCIL_FAKE_STATE_DIR

    local bin
    for bin in codex agy grok kimi ollama; do
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
# A spilled prompt is named inside the prompt prose rather than passed as its
# own argument, so recover it by shape and copy it out. The provider's trap
# deletes the original on exit, and tests need to see what crossed into the
# file versus what stayed on argv.
SPILLED=\$(printf '%s\\n' "\$@" | grep -o '[^[:space:]]*council-agy-prompt[^[:space:]]*' | head -1 || true)
if [[ -n "\${SPILLED:-}" && -f "\$SPILLED" ]]; then
    cp "\$SPILLED" "\${COUNCIL_FAKE_STATE_DIR}/spill.txt"
fi
# Version probes succeed regardless of behavior, mirroring real CLIs where
# --version works even when logged out
if [[ "\${1:-}" == "--version" ]]; then
    echo "fake-$bin 0.0.1"
    exit 0
fi
EOF
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
    if [[ "$bin" == "grok" ]]; then
        cat >> "$FAKE_BIN_DIR/$bin" <<EOF
# The real grok CLI answers a logged-out "grok models" with "You are not
# authenticated." on stdout and exit 0, never a non-zero exit
if [[ "\${1:-}" == "models" && "\${COUNCIL_FAKE_BEHAVIOR:-valid}" == "auth-failure" ]]; then
    echo "You are not authenticated."
    exit 0
fi
EOF
    fi
    cat >> "$FAKE_BIN_DIR/$bin" <<EOF
case "\${COUNCIL_FAKE_BEHAVIOR:-valid}" in
    valid)          echo "$marker: deterministic answer" ;;
    empty)          ;;
    malformed-json) echo '{"unterminated": ' ;;
    block-verdict)  echo "BLOCK: tests are failing in the changed module" ;;
    rate-limit)     echo "Error: 429 Too Many Requests" >&2; exit 1 ;;
    auth-failure)   echo "Error: not logged in" >&2; exit 1 ;;
    slow)           sleep "\${COUNCIL_FAKE_SLEEP:-5}"; echo "$marker: slow answer" ;;
    hang)           exec sleep "\${COUNCIL_FAKE_SLEEP:-300}" ;;
    error)          echo "Error: fake provider failure" >&2; exit 1 ;;
    *)              echo "Unknown COUNCIL_FAKE_BEHAVIOR: \${COUNCIL_FAKE_BEHAVIOR}" >&2; exit 64 ;;
esac
EOF
    chmod +x "$FAKE_BIN_DIR/$bin"
}
