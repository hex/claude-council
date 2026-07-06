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

# ----- OSC 11 reply parsing (pure, no tty) -----
# council_detect_theme's live query was dead on bash 3.2 (fractional read -t and
# an ST-only delimiter). The parse/luminance logic now lives in a pure function
# so every branch is testable without a terminal.

@test "theme: osc reply — black background maps to dark" {
    run council_theme_from_osc_reply 'rgb:0000/0000/0000'
    [ "$output" = "dark" ]
}

@test "theme: osc reply — white background maps to light" {
    run council_theme_from_osc_reply 'rgb:ffff/ffff/ffff'
    [ "$output" = "light" ]
}

@test "theme: osc reply — luminance threshold sits at 127" {
    # 0x80 = 128 on every channel -> lum 128 (> 127) -> light
    run council_theme_from_osc_reply 'rgb:8080/8080/8080'
    [ "$output" = "light" ]
    # 0x7f = 127 -> lum 127 (not > 127) -> dark
    run council_theme_from_osc_reply 'rgb:7f7f/7f7f/7f7f'
    [ "$output" = "dark" ]
}

@test "theme: osc reply — handles 8-bit channels and a full OSC frame" {
    run council_theme_from_osc_reply 'rgb:ff/ff/ff'
    [ "$output" = "light" ]
    # The tty returns the triplet wrapped in the OSC frame; parsing must find it.
    run council_theme_from_osc_reply $'\033]11;rgb:1c1c/1c1c/1c1c\033\\'
    [ "$output" = "dark" ]
}

@test "theme: osc reply — unparseable input yields empty (no assertion)" {
    run council_theme_from_osc_reply 'garbage'
    [ -z "$output" ]
    run council_theme_from_osc_reply ''
    [ -z "$output" ]
}

# ============================================================================
# Theme-aware renderer
# ============================================================================

render_with_theme() {
    local theme="$1" markdown="$2"
    local renderer="${BATS_TEST_TMPDIR}/render.sh"
    # These tests pin the perl renderer's theme-adaptive SGR codes; the Rich
    # renderer handles theme via pygments code themes and is tested in
    # display.bats.
    COUNCIL_RENDERER=perl display_write_renderer "$renderer"
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

@test "renderer: scrubs raw control/escape bytes from untrusted model output" {
    # A model answer could smuggle an OSC title-set (ESC ]0;...BEL) or a CSI
    # clear (ESC [2J) into its text. The renderer must strip the raw control
    # bytes before styling so they can't drive the terminal; the leftover
    # printable characters are harmless.
    local payload=$'before\033]0;pwned\a mid \033[2J after'
    run render_with_theme dark "$payload"
    [ "$status" -eq 0 ]
    # Visible words survive the scrub.
    [[ "$output" == *before* ]]
    [[ "$output" == *after* ]]
    # None of the injected raw sequences survive.
    [[ "$output" != *$'\033]0;'* ]]   # OSC title-set intro gone
    [[ "$output" != *$'\033[2J'* ]]   # CSI clear-screen gone
    [[ "$output" != *$'\a'* ]]        # BEL gone
}

# ----- Block-construct rendering (perl renderer, dark theme markers) -----
# These pin the perl renderer's structural output: head=96, gray=90, strong=1;97
# on dark. They complement the emphasis/muted tests above by covering tables,
# code fences, headings, lists, and blockquotes.

@test "renderer: table renders gray inner separators and a styled header row" {
    run render_with_theme dark $'| Name | Role |\n| --- | --- |\n| gem | judge |'
    [ "$status" -eq 0 ]
    # Borderless table: gray │ separators between columns.
    [[ "$output" == *$'\033[90m│\033[0m'* ]]
    # Header cells: bold + head color (96 on dark). The --- separator row that
    # marked them as a header is consumed, never printed.
    [[ "$output" == *$'\033[1;96mName\033[0m'* ]]
    [[ "$output" == *$'\033[1;96mRole\033[0m'* ]]
    [[ "$output" == *"─┼─"* ]]        # header underline crossbars
    # Data row present and NOT header-styled.
    [[ "$output" == *"gem"* ]]
    [[ "$output" == *"judge"* ]]
}

@test "renderer: fenced code block uses ┌/└ markers and copies content verbatim" {
    run render_with_theme dark $'```bash\n# cfg line\n**not bold**\n```'
    [ "$status" -eq 0 ]
    [[ "$output" == *"┌─────"* ]]     # open marker
    [[ "$output" == *"└─────"* ]]     # close marker
    [[ "$output" == *"bash"* ]]       # language label
    # Content inside a fence is never markdown-processed.
    [[ "$output" == *'# cfg line'* ]]
    [[ "$output" == *'**not bold**'* ]]
    [[ "$output" != *$'\033[1;7;96m'* ]]  # '# cfg line' is not turned into an H1
    [[ "$output" != *$'\033[1;97m'* ]]    # '**not bold**' is not turned into bold
}

@test "renderer: H1–H3 get distinct heading styles" {
    run render_with_theme dark $'# Title One\n## Title Two\n### Title Three'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Title One"* ]]
    [[ "$output" == *$'\033[1;7;96m'* ]]                   # H1: bold + inverse + head
    [[ "$output" == *$'\033[1;96mTitle Two\033[0m'* ]]     # H2: bold + head
    [[ "$output" == *$'\033[1;36mTitle Three\033[0m'* ]]   # H3: bold + fixed cyan
}

@test "renderer: bullet and numbered lists get cyan markers" {
    run render_with_theme dark $'- first\n- second\n\n1. one\n2. two'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[36m•\033[0m first'* ]]   # unordered → cyan bullet
    [[ "$output" == *$'\033[36m1.\033[0m one'* ]]    # ordered → cyan number
}

@test "renderer: blockquote gets a magenta bar and italic body" {
    run render_with_theme dark $'> quoted words'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[35m▌\033[0m'* ]]           # magenta bar
    [[ "$output" == *$'\033[3mquoted words\033[0m'* ]] # italic body
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
