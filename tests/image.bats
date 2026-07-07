#!/usr/bin/env bats
# ABOUTME: Council image/vision support — flag validation, routing, privacy
# ABOUTME: Hermetic: fake provider scripts echo received args; no real network

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${SCRIPTS_DIR}/query-council.sh"

setup() {
    mkdir -p "$TEST_CACHE_DIR"
    unset_provider_keys
    IMG="${BATS_TEST_TMPDIR}/shot.png"
    printf 'PNGDATA' > "$IMG"
}
teardown() { rm -rf "$TEST_CACHE_DIR"/*; }

@test "image: missing file is rejected before any provider runs" {
    run --separate-stderr bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="${BATS_TEST_TMPDIR}/nope.png" --providers=gemini "hi"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"not found"* || "$stderr" == *"No such"* ]]
}

@test "image: unsupported extension is rejected" {
    local bad="${BATS_TEST_TMPDIR}/notes.txt"; printf 'x' > "$bad"
    run --separate-stderr bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="$bad" --providers=gemini "hi"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"unsupported image type"* ]]
}

@test "image: a file over the size cap is rejected" {
    local big="${BATS_TEST_TMPDIR}/big.png"
    head -c 10485761 /dev/zero > "$big"
    run --separate-stderr bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="$big" --providers=gemini "hi"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"too large"* ]]
}

# A fake provider that proves whether it received an image and echoes the prompt.
write_echo_provider() {
    cat > "$1" <<'PROV'
#!/bin/bash
p="${1:-}"; img=""; mime=""
[[ "$p" == "--prompt-file" ]] && { p=$(cat "$2"); shift 2; } || shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-file) img=$(cat "$2"); shift 2 ;;
        --image-mime) mime="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'PROMPT=%s|IMG=%s|MIME=%s\n' "$p" "$img" "$mime"
PROV
    chmod +x "$1"
}

@test "image: a vision provider receives the base64 and mime" {
    local fd="${BATS_TEST_TMPDIR}/fp"; mkdir -p "$fd"
    write_echo_provider "$fd/gemini.sh"
    run --separate-stderr env PROVIDERS_DIR="$fd" \
        bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="$IMG" --providers=gemini "look"
    [ "$status" -eq 0 ]
    local resp; resp=$(echo "$output" | jq -r '.round1.gemini.response')
    [[ "$resp" == *"IMG=$(base64 < "$IMG" | tr -d '\n')"* ]]
    [[ "$resp" == *"MIME=image/png"* ]]
}

@test "image: a non-vision provider runs text-only and is tagged" {
    local fd="${BATS_TEST_TMPDIR}/fp"; mkdir -p "$fd"
    write_echo_provider "$fd/perplexity.sh"
    run --separate-stderr env PROVIDERS_DIR="$fd" PERPLEXITY_API_KEY=k \
        bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="$IMG" --providers=perplexity "look"
    [ "$status" -eq 0 ]
    local resp; resp=$(echo "$output" | jq -r '.round1.perplexity.response')
    [[ "$resp" == *"(answered without the image)"* ]]
    [[ "$resp" == *"IMG=|"* ]]   # empty image field: it never got the base64
}

@test "image: codex routes to openai (sibling) with the image" {
    local fd="${BATS_TEST_TMPDIR}/fp"; mkdir -p "$fd"
    write_echo_provider "$fd/codex.sh"     # must NOT be the one that answers
    write_echo_provider "$fd/openai.sh"    # sibling that should get the image
    run --separate-stderr env PROVIDERS_DIR="$fd" OPENAI_API_KEY=k \
        bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --image="$IMG" --providers=codex "look"
    [ "$status" -eq 0 ]
    # The slot is filled by the sibling and carries the image.
    local fb; fb=$(echo "$output" | jq -r '.round1.codex.fallback // empty')
    [ "$fb" = "openai" ]
    local resp; resp=$(echo "$output" | jq -r '.round1.codex.response')
    [[ "$resp" == *"MIME=image/png"* ]]
}

# A fixed-text provider for privacy assertions: it accepts the prompt and image
# args but never repeats the bytes, so any base64 found in the cache can only
# have come from the pipeline itself, not the provider's response.
write_fixed_provider() {
    cat > "$1" <<'PROV'
#!/bin/bash
printf 'critique text\n'
PROV
    chmod +x "$1"
}

@test "image: the base64 never appears in a cache entry" {
    local fd="${BATS_TEST_TMPDIR}/fp"; mkdir -p "$fd"
    write_fixed_provider "$fd/gemini.sh"
    local b64; b64=$(base64 < "$IMG" | tr -d '\n')
    run --separate-stderr env PROVIDERS_DIR="$fd" COUNCIL_CACHE_DIR="$TEST_CACHE_DIR" \
        bash "$SCRIPT" --no-pane --no-auto-context \
        --image="$IMG" --providers=gemini "look"
    [ "$status" -eq 0 ]
    # No cache file contains the base64 blob.
    ! grep -rqF "$b64" "$TEST_CACHE_DIR"
}

@test "image: a no-image query is unaffected (regression)" {
    local fd="${BATS_TEST_TMPDIR}/fp"; mkdir -p "$fd"
    write_echo_provider "$fd/gemini.sh"
    run --separate-stderr env PROVIDERS_DIR="$fd" \
        bash "$SCRIPT" --no-cache --no-pane --no-auto-context \
        --providers=gemini "look"
    [ "$status" -eq 0 ]
    local resp; resp=$(echo "$output" | jq -r '.round1.gemini.response')
    [[ "$resp" == *"IMG=|"* ]]                       # no image sent
    [[ "$resp" != *"(answered without the image)"* ]]  # no spurious tag
}
