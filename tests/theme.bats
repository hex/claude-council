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

@test "theme: COLORFGBG dark/ambiguous background yields unknown" {
    # COLORFGBG is unreliable — it goes stale (this very session reported
    # "15;0" (dark bg) while the terminal was actually light). Forcing a
    # "dark" pick renders bright-white emphasis that is invisible on a light
    # background, so an ambiguous COLORFGBG yields "unknown" and emphasis
    # falls back to attribute-only (readable on any theme). Only an explicit
    # COUNCIL_THEME or a live OSC 11 query may assert "dark".
    export COLORFGBG="15;0"
    run council_detect_theme
    [ "$output" == "unknown" ]
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

# ============================================================================
# Theme-aware muted text (faint borders, gray URLs/rules, H6 headings)
# ANSI 2 (faint) and 90 (bright-black) wash out on a light background, so
# light remaps both to a dark-gray 256-color that holds contrast; dark and
# unknown keep the raw codes (faint/bright-black read fine on a dark theme).
# ============================================================================

@test "renderer: light theme uses dark gray for muted text, never faint or bright-black" {
    run render_with_theme light $'###### sub heading\n[label](http://x)\n\n---'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[38;5;240'* ]]   # H6 / link URL / rule recolored
    [[ "$output" != *$'\033[2;3m'* ]]       # no raw faint-italic (H6)
    [[ "$output" != *$'\033[90m'* ]]        # no raw bright-black (URL, rule)
}

@test "renderer: dark theme keeps faint and bright-black muted codes" {
    run render_with_theme dark $'###### sub heading\n\n---'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[2;3m'* ]]        # H6 faint-italic preserved
    [[ "$output" == *$'\033[90m'* ]]         # horizontal rule bright-black preserved
    [[ "$output" != *$'\033[38;5;240'* ]]
}

# ============================================================================
# council_faint_sgr + theme-aware waiting list
# ============================================================================

@test "faint sgr: light yields dark gray, dark/unknown yield faint" {
    export COUNCIL_THEME_RESOLVED=light
    run council_faint_sgr
    [ "$output" == "38;5;240" ]
    export COUNCIL_THEME_RESOLVED=dark
    run council_faint_sgr
    [ "$output" == "2" ]
    export COUNCIL_THEME_RESOLVED=unknown
    run council_faint_sgr
    [ "$output" == "2" ]
}

@test "waiting list: light theme uses dark-gray separators, not faint" {
    export COUNCIL_THEME_RESOLVED=light
    local out
    council_waiting_list out 100 gemini openai
    [[ "$out" == *$'\033[38;5;240m, \033[0m'* ]]
    [[ "$out" != *$'\033[2m'* ]]
}

@test "waiting list: dark theme keeps faint separators" {
    export COUNCIL_THEME_RESOLVED=dark
    local out
    council_waiting_list out 100 gemini openai
    [[ "$out" == *$'\033[2m, \033[0m'* ]]
}
