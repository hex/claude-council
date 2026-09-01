# ABOUTME: Shared curl fakes for the check-status suites - a shadowing curl that
# ABOUTME: answers a canned code, and a recording curl that captures argv

# The stub exits non-zero on a failed transfer (code 000) because that is what
# the real binary does: curl writes 000 through -w and also exits non-zero (7 on
# a refused connection, 28 on a timeout), and the stub picks one such code. A
# stub that always exits 0 would let the script's transfer-failure branch pass
# without ever running under a non-zero curl.
shadow_curl() {
    local dir="${BATS_TEST_TMPDIR}/fakecurl"
    mkdir -p "$dir"
    cat > "$dir/curl" <<'EOF'
#!/bin/bash
code="${COUNCIL_FAKE_HTTP_CODE:-200}"
# Mirror curl's -o: the body lands in the named file, never on stdout, so a
# probe that inspects the body reads it exactly as it would from the real thing.
out=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then out="$arg"; fi
    prev="$arg"
done
if [[ -n "$out" ]]; then printf '%s' "${COUNCIL_FAKE_HTTP_BODY:-}" > "$out"; fi
printf '%s' "$code"
if [[ "$code" == "000" ]]; then exit 7; fi
exit 0
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
    export GEMINI_API_KEY=k OPENAI_API_KEY=k XAI_API_KEY=k PERPLEXITY_API_KEY=k KIMI_API_KEY=k
    export OPENROUTER_API_KEY=k
    export COUNCIL_FAKE_BEHAVIOR=valid
}

# the third is a 400 that no vendor marks as a credentials problem. The two
# vendor tests each assert that exactly one provider is flagged, so neither
# vendor's body shape can satisfy the other's rule.

# Count the providers reported as an auth failure (one row per provider).
auth_failures() {
    printf '%s\n' "$1" | grep -c 'Auth failed' || true
}


# ---- secret hygiene: /status probes must keep keys off the process argv ----

# Recording curl: appends its argv (one arg per line) to CS_ARGV_FILE, copies any
# --config file's contents to CS_CONFIG_FILE, then prints the scripted HTTP code.
record_curl() {
    local dir="${BATS_TEST_TMPDIR}/reccurl"
    mkdir -p "$dir"
    export CS_ARGV_FILE="${BATS_TEST_TMPDIR}/argv"
    export CS_CONFIG_FILE="${BATS_TEST_TMPDIR}/cfg"
    : > "$CS_ARGV_FILE"; : > "$CS_CONFIG_FILE"
    cat > "$dir/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CS_ARGV_FILE"
prev=""
for a in "$@"; do
    [[ "$prev" == "--config" && -f "$a" ]] && cat "$a" >> "$CS_CONFIG_FILE"
    prev="$a"
done
printf '%s' "${COUNCIL_FAKE_HTTP_CODE:-200}"
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
    export GEMINI_API_KEY=SEKRET_GEM OPENAI_API_KEY=SEKRET_OAI \
           XAI_API_KEY=SEKRET_GROK PERPLEXITY_API_KEY=SEKRET_PPX \
           OPENROUTER_API_KEY=SEKRET_ORT
    export COUNCIL_FAKE_BEHAVIOR=valid
}
