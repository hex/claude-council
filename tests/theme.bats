#!/usr/bin/env bats
# ABOUTME: Tests for terminal theme detection and theme-aware markdown rendering
# ABOUTME: Emphasis colors must adapt: bright on dark, dark on light, attribute-only when unknown

load test_helper

setup() {
    mkdir -p "$TEST_TMP_DIR"
    # Never query a real tty from tests
    export COUNCIL_NO_TTY_QUERY=1
    unset COUNCIL_THEME COLORFGBG
    source "${LIB_DIR}/display.sh"
}

# ============================================================================
# council_detect_theme
# ============================================================================

@test "theme: COUNCIL_THEME override wins" {
    export COUNCIL_THEME=light
    run council_detect_theme
    [ "$output" == "light" ]
    export COUNCIL_THEME=dark
    run council_detect_theme
    [ "$output" == "dark" ]
}

@test "theme: COLORFGBG light background detected" {
    export COLORFGBG="0;15"
    run council_detect_theme
    [ "$output" == "light" ]
}

@test "theme: COLORFGBG dark background detected" {
    export COLORFGBG="15;0"
    run council_detect_theme
    [ "$output" == "dark" ]
}

@test "theme: COLORFGBG three-field form uses last field" {
    export COLORFGBG="0;default;15"
    run council_detect_theme
    [ "$output" == "light" ]
}

@test "theme: no signals yields unknown" {
    run council_detect_theme
    [ "$output" == "unknown" ]
}

# ============================================================================
# Theme-aware renderer
# ============================================================================

render_with_theme() {
    local theme="$1" markdown="$2"
    local renderer="${BATS_TEST_TMPDIR}/render.sh"
    display_write_renderer "$renderer"
    printf '%s\n' "$markdown" | COUNCIL_THEME_RESOLVED="$theme" "$renderer"
}

@test "renderer: dark theme keeps bright-white emphasis" {
    run render_with_theme dark "this is **important** text"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[1;97m'important* ]]
}

@test "renderer: light theme uses dark emphasis, never bright white" {
    run render_with_theme light "this is **important** and *subtle* text"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[1;30m'important* ]]
    [[ "$output" == *$'\033[3;30m'subtle* ]]
    [[ "$output" != *"97m"* ]]
}

@test "renderer: unknown theme uses attribute-only emphasis" {
    run render_with_theme unknown "this is **important** and *subtle* text"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[1m'important* ]]
    [[ "$output" == *$'\033[3m'subtle* ]]
    [[ "$output" != *"97m"* ]]
    [[ "$output" != *"30m"* ]]
}
