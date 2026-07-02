#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/display.sh
# ABOUTME: Covers detection helpers, iTerm2 wrappers, and manifest file writes

load test_helper
bats_require_minimum_version 1.5.0

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

# ----- tty probe -----

@test "display: council_probe_tty succeeds and is silent on a writable target" {
    source "$LIB"
    run council_probe_tty /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "display: council_probe_tty fails silently when the target cannot be opened" {
    source "$LIB"
    # A path under a nonexistent directory can never be opened for writing, so
    # the probe must fail (nonzero) AND leak nothing to stderr. This guards the
    # redirection ordering: stderr has to be silenced before the write redirect,
    # or the failed open prints "No such file or directory" to the real stderr.
    run council_probe_tty "$TEST_TMP_DIR/nope/missing/tty"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "display: waiting line disables autowrap so a too-wide list clips, not wraps" {
    # Regression guard for the spinner waterfall. The watcher's draw_loading is
    # inside an un-sourceable heredoc, so this asserts the no-wrap guard is
    # present in source: the waiting line must bracket its output with DECAWM-off
    # (\033[?7l) and DECAWM-on (\033[?7h). Without it, a list wider than the pane
    # wraps, and \r\033[K (which reclaims only the current row) leaves one stale
    # spinner line per frame. Verified behaviorally via tmux capture-pane.
    # Match the actual printf sequence, not the explanatory comment: the line
    # clears with \033[K then disables wrap, and re-enables right after the list.
    run grep -F '\033[K\033[?7l' "$LIB"
    [ "$status" -eq 0 ]
    run grep -F '%s\033[?7h' "$LIB"
    [ "$status" -eq 0 ]
}

@test "council_waiting_list: includes every provider when the budget is ample" {
    source "$LIB"
    local out; council_waiting_list out 100 codex antigravity grok
    [[ "$out" == *codex* ]]
    [[ "$out" == *antigravity* ]]
    [[ "$out" == *grok* ]]
    [[ "$out" != *"…"* ]]
}

@test "council_waiting_list: truncates with an ellipsis when the budget is tight" {
    source "$LIB"
    local out; council_waiting_list out 12 codex antigravity grok perplexity
    [[ "$out" == *"…"* ]]
    [[ "$out" == *codex* ]]
    [[ "$out" != *perplexity* ]]
}

@test "council_waiting_list: empty when there are no providers" {
    source "$LIB"
    local out="sentinel"; council_waiting_list out 50
    [ -z "$out" ]
}

@test "council_waiting_list: visible width stays within budget" {
    source "$LIB"
    local out; council_waiting_list out 40 codex grok
    # Strip ANSI; the remainder is the ASCII visible text, which must fit.
    local clean; clean=$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')
    [ "$clean" = "codex, grok" ]
    [ "${#clean}" -le 40 ]
}

# ----- pane env forwarding -----

@test "display: council_pane_env_args always forwards COUNCIL_AUTO_CLOSE" {
    source "$LIB"
    run council_pane_env_args
    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNCIL_AUTO_CLOSE="* ]]
}

@test "display: council_pane_env_args forwards COUNCIL_THEME only when set" {
    source "$LIB"
    # Unset: must NOT emit COUNCIL_THEME at all. An empty `-e COUNCIL_THEME=`
    # would overwrite a theme the pane could otherwise inherit or auto-detect.
    unset COUNCIL_THEME
    run council_pane_env_args
    [[ "$output" != *"COUNCIL_THEME"* ]]
    # Set: forwarded with its value.
    export COUNCIL_THEME=light
    run council_pane_env_args
    [[ "$output" == *"COUNCIL_THEME=light"* ]]
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

# ----- Markdown renderer selection -----

# Stub python3 whose probe (-c 'import rich') and render (script arg) exits
# are controlled independently, so selection and runtime-fallback paths can
# be tested without a real Rich install.
make_python_stub() {
    local dir="$1" probe_exit="$2" render_exit="$3"
    cat > "$dir/python3" <<STUB
#!/bin/bash
case "\$1" in
    -c) exit $probe_exit ;;
    *)  exit $render_exit ;;
esac
STUB
    chmod +x "$dir/python3"
}

SAMPLE_MD=$'<think>\nweighing the options here\n</think>\n\n# Verdict\n\nUse **stdin**, not argv.'

@test "renderer: council_rich_python echoes a python when one can import rich" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 0 0
    PATH="$PANE_DIR:/usr/bin:/bin" run council_rich_python
    [ "$status" -eq 0 ]
    [ "$output" = "$PANE_DIR/python3" ]
}

@test "renderer: council_rich_python fails when no python can import rich" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 1 1
    PATH="$PANE_DIR:/usr/bin:/bin" run council_rich_python
    [ "$status" -ne 0 ]
}

@test "renderer: COUNCIL_RENDERER=perl forces the perl renderer" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 0 0
    COUNCIL_RENDERER=perl PATH="$PANE_DIR:/usr/bin:/bin" \
        display_write_renderer "$PANE_DIR/render.sh"
    run head -1 "$PANE_DIR/render.sh"
    [[ "$output" == *perl* ]]
    [ ! -f "$PANE_DIR/render.py" ]
}

@test "renderer: falls back to perl when rich is unavailable" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 1 1
    PATH="$PANE_DIR:/usr/bin:/bin" display_write_renderer "$PANE_DIR/render.sh"
    run head -1 "$PANE_DIR/render.sh"
    [[ "$output" == *perl* ]]
    [ ! -f "$PANE_DIR/render.py" ]
}

@test "renderer: writes the Rich wrapper and render.py when rich is available" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 0 0
    PATH="$PANE_DIR:/usr/bin:/bin" display_write_renderer "$PANE_DIR/render.sh"
    [ -f "$PANE_DIR/render.py" ]
    [ -x "$PANE_DIR/render_fallback.sh" ]
    # The wrapper bakes the absolute python path: the pane's PATH is the tmux
    # server's, not the shell's that ran the probe.
    run grep -F "$PANE_DIR/python3" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
}

@test "renderer: wrapper falls back to perl when the Rich render fails at runtime" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 0 1
    PATH="$PANE_DIR:/usr/bin:/bin" display_write_renderer "$PANE_DIR/render.sh"
    run --separate-stderr bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SAMPLE_MD" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    # Stderr must be pristine — a headless run (no controlling tty) must not
    # leak the wrapper's width-probe failure.
    [ -z "$stderr" ]
    # Perl fallback output: styled think block, no raw tags, ANSI present.
    [[ "$output" == *"▸ thinking"* ]]
    [[ "$output" != *"<think>"* ]]
    [[ "$output" == *$'\033['* ]]
}

@test "renderer: Rich render styles think blocks and strips raw tags" {
    source "$LIB"
    council_rich_python >/dev/null 2>&1 || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    run --separate-stderr bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SAMPLE_MD" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"▸ thinking"* ]]
    [[ "$output" != *"<think>"* ]]
    [[ "$output" == *"Verdict"* ]]
    [[ "$output" == *$'\033['* ]]
}

@test "renderer: Rich render honors COUNCIL_THEME_RESOLVED for code highlighting" {
    source "$LIB"
    council_rich_python >/dev/null 2>&1 || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    local code=$'```bash\nif true; then printf "%s" "$HOME"; fi\n```'
    local dark light
    dark=$(printf '%s' "$code" | COUNCIL_THEME_RESOLVED=dark "$PANE_DIR/render.sh")
    light=$(printf '%s' "$code" | COUNCIL_THEME_RESOLVED=light "$PANE_DIR/render.sh")
    [ -n "$dark" ]
    [ -n "$light" ]
    [ "$dark" != "$light" ]
}

# ----- Capability gating for pane open -----

@test "display: should_open_pane is false outside tmux" {
    source "$LIB"
    run should_open_pane
    [ "$status" -eq 1 ]
}

@test "display: should_open_pane is true inside tmux by default" {
    source "$LIB"
    # test_helper.bash exports COUNCIL_NO_PANE=1 globally as an orphan-pane
    # guard; unset it here so we genuinely exercise the default code path.
    unset COUNCIL_NO_PANE
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
