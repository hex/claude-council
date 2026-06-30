#!/usr/bin/env bats
# ABOUTME: Guards that query-council.sh marshals large prompts/responses to jq
# ABOUTME: via stdin (not argv), so the MSYS ARG_MAX overflow can't drop output

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${SCRIPTS_DIR}/query-council.sh"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset_provider_keys
}

teardown() {
    rm -rf "$TEST_CACHE_DIR"
}

# A payload comfortably past MSYS's ~32KB ARG_MAX. The original bug (jq
# "Argument list too long" on Windows, silently dropping every response) can't
# be reproduced where ARG_MAX is ~2MB, so these tests assert the durable
# invariant instead: a large payload round-trips through the final JSON intact,
# whatever transport jq is fed. The markers catch truncation at either edge; a
# length floor catches a dropped or empty body.
BIG_BYTES=60000
MARK_START="BIGSTART_8f2a"
MARK_END="BIGEND_3c7b"

# Writes a fake provider that emits FAKE_START, FAKE_BYTES of body, then
# FAKE_END. The script is static (quoted heredoc) — values arrive via the
# environment so there is no shell-escaping hazard in the generated file.
write_big_provider() {
    cat > "$1" <<'PROVIDER'
#!/bin/bash
printf '%s\n' "$FAKE_START"
head -c "$FAKE_BYTES" /dev/zero | tr '\0' 'x'
printf '%s\n' "$FAKE_END"
PROVIDER
    chmod +x "$1"
}

@test "query-council: a large round-1 response round-trips intact (ARG_MAX)" {
    local fakedir="${BATS_TEST_TMPDIR}/argmax-r1"
    mkdir -p "$fakedir"
    write_big_provider "$fakedir/antigravity.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" \
        FAKE_START="$MARK_START" FAKE_END="$MARK_END" FAKE_BYTES="$BIG_BYTES" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity "ping"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e . >/dev/null   # whole output is valid JSON
    local resp
    resp=$(echo "$output" | jq -r '.round1.antigravity.response')
    [[ "$resp" == "$MARK_START"* ]]       # front not truncated
    [[ "$resp" == *"$MARK_END" ]]        # back not truncated
    [ "${#resp}" -ge "$BIG_BYTES" ]      # full body survived
}

@test "query-council: a large prompt round-trips intact into metadata (ARG_MAX)" {
    local fakedir="${BATS_TEST_TMPDIR}/argmax-prompt"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'PROVIDER'
#!/bin/bash
echo "ok"
PROVIDER
    chmod +x "$fakedir/antigravity.sh"

    local body
    body=$(head -c "$BIG_BYTES" /dev/zero | tr '\0' 'P')
    local big_prompt="PROMPTSTART ${body} PROMPTEND"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" \
        bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --providers=antigravity "$big_prompt"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e . >/dev/null
    local mprompt
    mprompt=$(echo "$output" | jq -r '.metadata.prompt')
    [[ "$mprompt" == "PROMPTSTART "* ]]
    [[ "$mprompt" == *" PROMPTEND" ]]
    [ "${#mprompt}" -ge "$BIG_BYTES" ]
}

@test "query-council: a large response round-trips intact in debate round 2 (ARG_MAX)" {
    local fakedir="${BATS_TEST_TMPDIR}/argmax-debate"
    mkdir -p "$fakedir"
    write_big_provider "$fakedir/antigravity.sh"

    run --separate-stderr env PROVIDERS_DIR="$fakedir" \
        FAKE_START="$MARK_START" FAKE_END="$MARK_END" FAKE_BYTES="$BIG_BYTES" \
        bash "$SCRIPT" --no-cache --no-pane --debate --providers=antigravity "ping"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e . >/dev/null
    local r1 r2
    r1=$(echo "$output" | jq -r '.round1.antigravity.response')
    r2=$(echo "$output" | jq -r '.round2.antigravity.response')
    [ "${#r1}" -ge "$BIG_BYTES" ]
    [[ "$r2" == "$MARK_START"* ]]
    [[ "$r2" == *"$MARK_END" ]]
    [ "${#r2}" -ge "$BIG_BYTES" ]
}
