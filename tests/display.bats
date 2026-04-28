#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/display.sh
# ABOUTME: Covers detection helpers, iTerm2 wrappers, and manifest file writes

load test_helper

LIB="${LIB_DIR}/display.sh"

setup() {
    mkdir -p "$TEST_TMP_DIR"
    unset TMUX TMUX_PANE LC_TERMINAL ITERM_SESSION_ID TERM_PROGRAM
    PANE_DIR=$(mktemp -d "${TEST_TMP_DIR}/pane.XXXXXX")
    export PANE_DIR
}

teardown() {
    rm -rf "$PANE_DIR"
}

# ----- Detection helpers -----

@test "display: is_tmux returns 0 when TMUX is set" {
    source "$LIB"
    export TMUX="/tmp/tmux-501/default,12345,0"
    run is_tmux
    [ "$status" -eq 0 ]
}

@test "display: is_tmux returns 1 when TMUX is unset" {
    source "$LIB"
    run is_tmux
    [ "$status" -eq 1 ]
}

@test "display: is_iterm2_outer returns 0 when LC_TERMINAL=iTerm2" {
    source "$LIB"
    export LC_TERMINAL="iTerm2"
    run is_iterm2_outer
    [ "$status" -eq 0 ]
}

@test "display: is_iterm2_outer returns 0 when ITERM_SESSION_ID is set" {
    source "$LIB"
    export ITERM_SESSION_ID="w0t0p0:ABC123"
    run is_iterm2_outer
    [ "$status" -eq 0 ]
}

@test "display: is_iterm2_outer returns 1 when neither is set" {
    source "$LIB"
    run is_iterm2_outer
    [ "$status" -eq 1 ]
}

# ----- iTerm2 wrappers (no-op outside iTerm2) -----

@test "display: it2_set_tab_color is silent no-op outside iTerm2" {
    source "$LIB"
    run it2_set_tab_color yellow
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "display: it2_set_tab_color emits escape when in iTerm2" {
    source "$LIB"
    export LC_TERMINAL="iTerm2"
    # Capture raw bytes (run's $output strips control chars in some bats versions)
    local out
    out=$(it2_set_tab_color yellow 2>&1 | od -c | head -2)
    [[ "$out" == *"033"* ]]
}

@test "display: it2_set_mark is silent no-op outside iTerm2" {
    source "$LIB"
    run it2_set_mark
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "display: it2_set_mark emits SetMark sequence in iTerm2" {
    source "$LIB"
    export LC_TERMINAL="iTerm2"
    local raw
    raw=$(it2_set_mark)
    [[ "$raw" == *"SetMark"* ]]
}

@test "display: it2_attention is silent no-op outside iTerm2" {
    source "$LIB"
    run it2_attention start
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ----- Manifest writes -----

@test "display: pane_status_event appends a tab-separated line" {
    source "$LIB"
    pane_status_event "$PANE_DIR" gemini complete 187
    [ -f "$PANE_DIR/status" ]
    run cat "$PANE_DIR/status"
    [[ "$output" == *"gemini"* ]]
    [[ "$output" == *"complete"* ]]
    [[ "$output" == *"187"* ]]
}

@test "display: pane_status_event accepts events without timing" {
    source "$LIB"
    pane_status_event "$PANE_DIR" openai querying
    run cat "$PANE_DIR/status"
    [[ "$output" == *"openai"* ]]
    [[ "$output" == *"querying"* ]]
}

@test "display: pane_response_write creates per-provider markdown file" {
    source "$LIB"
    mkdir -p "$PANE_DIR/responses"
    pane_response_write "$PANE_DIR" gemini "## Hello from Gemini"
    [ -f "$PANE_DIR/responses/gemini.md" ]
    run cat "$PANE_DIR/responses/gemini.md"
    [[ "$output" == *"Hello from Gemini"* ]]
}

@test "display: pane_response_write preserves multiline content" {
    source "$LIB"
    mkdir -p "$PANE_DIR/responses"
    pane_response_write "$PANE_DIR" openai "$(printf 'line1\nline2\nline3')"
    run cat "$PANE_DIR/responses/openai.md"
    [[ "$output" == *"line1"* ]]
    [[ "$output" == *"line2"* ]]
    [[ "$output" == *"line3"* ]]
}

# ----- Markdown renderer detection -----


# ----- Capability gating for pane open -----

@test "display: should_open_pane is false outside tmux" {
    source "$LIB"
    run should_open_pane
    [ "$status" -eq 1 ]
}

@test "display: should_open_pane is true inside tmux by default" {
    source "$LIB"
    export TMUX="/tmp/tmux-501/default,12345,0"
    run should_open_pane
    [ "$status" -eq 0 ]
}

@test "display: should_open_pane respects COUNCIL_NO_PANE=1" {
    source "$LIB"
    export TMUX="/tmp/tmux-501/default,12345,0"
    export COUNCIL_NO_PANE=1
    run should_open_pane
    [ "$status" -eq 1 ]
}
