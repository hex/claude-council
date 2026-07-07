#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/pane-watcher.sh
# ABOUTME: Drives the standalone pane watcher against a prebuilt watch dir

load test_helper
bats_require_minimum_version 1.5.0

LIB="${LIB_DIR}/display.sh"
WATCHER="${LIB_DIR}/pane-watcher.sh"

# Build a watch dir the watcher consumes in one pass: a perl render.sh plus
# .done pre-created, so the poll loop breaks after its first iteration.
setup() {
    mkdir -p "$TEST_TMP_DIR"
    W=$(mktemp -d "${TEST_TMP_DIR}/watch.XXXXXX")
    mkdir -p "$W/responses"
    (source "$LIB" && COUNCIL_RENDERER=perl display_write_renderer "$W/render.sh")
    touch "$W/.done"
    export W
}

# No teardown for $W: the watcher's EXIT trap removes the watch dir itself.

# The perl alarm turns a regression in the .done exit path into a SIGALRM
# failure (status 142) instead of a hung bats run.
run_watcher() {
    run --separate-stderr env COUNCIL_AUTO_CLOSE=1 COUNCIL_NO_TTY_QUERY=1 \
        perl -e 'alarm shift; exec @ARGV' 10 bash "$WATCHER" "$W" "$LIB"
}

@test "watcher: renders a response under its provider banner and exits on .done" {
    printf '## Hello\n' > "$W/responses/gemini.md"
    printf 'gemini\tcomplete\t1234\tgemini-2.5-pro\n' >> "$W/status"
    run_watcher
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    # Banner: uppercased provider title, model name, and timing in seconds.
    [[ "$output" == *"GEMINI"* ]]
    [[ "$output" == *"gemini-2.5-pro"* ]]
    [[ "$output" == *"1.2s"* ]]
    # Response body rendered through render.sh.
    [[ "$output" == *"Hello"* ]]
    # An iTerm2 mark (SetMark) is dropped above each response.
    [[ "$output" == *"SetMark"* ]]
}

@test "watcher: prints an inline notice for a provider that errored without a response" {
    mkdir -p "$W/errors"
    printf 'API key missing\n' > "$W/errors/grok.txt"
    printf 'grok\terror\t\t\n' >> "$W/status"
    run_watcher
    [ "$status" -eq 0 ]
    [[ "$output" == *"grok error"* ]]
    [[ "$output" == *"API key missing"* ]]
}

@test "watcher: removes the watch dir on exit" {
    printf '## Bye\n' > "$W/responses/openai.md"
    run_watcher
    [ "$status" -eq 0 ]
    [ ! -d "$W" ]
}
