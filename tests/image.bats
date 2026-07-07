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
