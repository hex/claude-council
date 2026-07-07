# ABOUTME: Installs fake codex/agy CLI executables onto PATH for hermetic tests
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
#
# Every invocation appends {bin, args} to $COUNCIL_FAKE_STATE_DIR/calls.jsonl
# so tests can assert exactly what the plugin sent to the CLI.

install_fake_clis() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    COUNCIL_FAKE_STATE_DIR="${BATS_TEST_TMPDIR}/fake-state"
    mkdir -p "$FAKE_BIN_DIR" "$COUNCIL_FAKE_STATE_DIR"
    export FAKE_BIN_DIR COUNCIL_FAKE_STATE_DIR

    local bin
    for bin in codex agy; do
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
# Version probes succeed regardless of behavior, mirroring real CLIs where
# --version works even when logged out
if [[ "\${1:-}" == "--version" ]]; then
    echo "fake-$bin 0.0.1"
    exit 0
fi
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
