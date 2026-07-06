#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/display.sh
# ABOUTME: Covers detection helpers, iTerm2 wrappers, and manifest file writes

load test_helper
bats_require_minimum_version 1.5.0

LIB="${LIB_DIR}/display.sh"

# Probe for a Rich-capable python ONCE per file: the real probe costs
# 150-600ms and its result is invariant for the run. Empty → rich-gated
# tests skip.
setup_file() {
    source "$LIB"
    export COUNCIL_TEST_RICH_CMD="$(council_rich_python 2>/dev/null || true)"
}

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
    # Regression guard for the spinner waterfall. draw_loading only runs on a
    # live pane tty, so this asserts the no-wrap guard is present in source:
    # the waiting line must bracket its output with DECAWM-off
    # (\033[?7l) and DECAWM-on (\033[?7h). Without it, a list wider than the pane
    # wraps, and \r\033[K (which reclaims only the current row) leaves one stale
    # spinner line per frame. Verified behaviorally via tmux capture-pane.
    # Match the actual printf sequence, not the explanatory comment: the line
    # clears with \033[K then disables wrap, and re-enables right after the list.
    run grep -F '\033[K\033[?7l' "${LIB_DIR}/pane-watcher.sh"
    [ "$status" -eq 0 ]
    run grep -F '%s\033[?7h' "${LIB_DIR}/pane-watcher.sh"
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

@test "display: a removed pane dir does not abort the caller under set -e" {
    source "$LIB"
    # A provider runs its manifest writes inside a `set -e` subshell. If the user
    # closes the streaming pane mid-run, the pane dir vanishes; a writer that
    # returned 1 would abort the subshell here and the provider's answer + cache
    # write would never happen. The writers must no-op successfully instead, so
    # the work after them still runs. SENTINEL_REACHED is the "answer got saved".
    local gone="$PANE_DIR/removed"
    run bash -c '
        set -e
        source "$1"
        pane_status_event "$2" gemini complete 120
        pane_response_write "$2" gemini "answer"
        pane_error_write "$2" gemini "err"
        echo SENTINEL_REACHED
    ' _ "$LIB" "$gone"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SENTINEL_REACHED"* ]]
}

@test "display: pane_response_write is atomic — no temp file, complete content" {
    source "$LIB"
    mkdir -p "$PANE_DIR/responses"
    pane_response_write "$PANE_DIR" gemini "$(printf 'a\nb\nc')"
    [ -f "$PANE_DIR/responses/gemini.md" ]
    # The dot-temp used for the atomic rename must not survive, and — critically —
    # the watcher's responses/*.md glob must never match a half-written file.
    run find "$PANE_DIR/responses" -name '.*.tmp'
    [ -z "$output" ]
    run cat "$PANE_DIR/responses/gemini.md"
    [[ "$output" == *"a"* ]]
    [[ "$output" == *"c"* ]]
}

# ----- Markdown renderer selection -----

# Stub python3 whose probe (-c payload) and render (script arg) exits are
# controlled independently, so selection and runtime-fallback paths can be
# tested without a real Rich install. Render prints a sentinel so tests can
# assert the wrapper forwards the renderer's stdout (discarded on failure).
make_python_stub() {
    local dir="$1" probe_exit="$2" render_exit="$3"
    cat > "$dir/python3" <<STUB
#!/bin/bash
case "\$1" in
    -c) exit $probe_exit ;;
    *)  printf 'STUB_RICH_OUTPUT\n'; exit $render_exit ;;
esac
STUB
    chmod +x "$dir/python3"
}

# Stub uv: render invocations (last arg is a .py path) emit a sentinel; any
# other invocation is a probe, which sleeps $2 seconds (default 0) then
# succeeds — the delay exercises the probe timeout.
make_uv_stub() {
    local dir="$1" probe_delay="${2:-0}"
    cat > "$dir/uv" <<STUB
#!/bin/bash
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in
    *.py) printf 'STUB_UV_RICH_OUTPUT\n'; exit 0 ;;
    *)    sleep $probe_delay; exit 0 ;;
esac
STUB
    chmod +x "$dir/uv"
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
    # A zero-width tty (stty reports "0 0" when winsize was never set) must
    # fall back to 80: COLUMNS=0 makes Rich emit nothing with exit 0.
    run grep -F '^[1-9][0-9]*$' "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
}

@test "renderer: wrapper forwards the Rich renderer's stdout" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 0 0
    PATH="$PANE_DIR:/usr/bin:/bin" display_write_renderer "$PANE_DIR/render.sh"
    run --separate-stderr bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SAMPLE_MD" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"STUB_RICH_OUTPUT"* ]]
    # No perl fallback markers: the render succeeded, so its output must be
    # forwarded verbatim, not re-rendered.
    [[ "$output" != *"└─"* ]]
}

@test "renderer: selection routes through uv when python3 lacks rich" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 1 1
    make_uv_stub "$PANE_DIR"
    PATH="$PANE_DIR:/usr/bin:/bin" display_write_renderer "$PANE_DIR/render.sh"
    [ -f "$PANE_DIR/render.py" ]
    run grep -F "$PANE_DIR/uv" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    # --no-project: uv must not resolve (and sync!) whatever pyproject.toml
    # the pane's cwd happens to contain.
    run grep -F -- '--no-project' "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    # The baked multi-word uv command must survive word splitting end to end.
    run --separate-stderr bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SAMPLE_MD" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB_UV_RICH_OUTPUT"* ]]
}

@test "renderer: uv probe times out instead of hanging pane open" {
    source "$LIB"
    make_python_stub "$PANE_DIR" 1 1
    make_uv_stub "$PANE_DIR" 3
    COUNCIL_RICH_PROBE_TIMEOUT=1 PATH="$PANE_DIR:/usr/bin:/bin" run council_rich_python
    [ "$status" -ne 0 ]
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
    [ -n "$COUNCIL_TEST_RICH_CMD" ] || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    run --separate-stderr bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SAMPLE_MD" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"▸ thinking"* ]]
    [[ "$output" != *"<think>"* ]]
    [[ "$output" == *"Verdict"* ]]
    [[ "$output" == *$'\033['* ]]
    # Discriminate Rich from the silent perl fallback: perl always closes a
    # think block with "└─"; Rich output never contains it. Without this the
    # test passes even when render.py is dead and every render degrades.
    [[ "$output" != *"└─"* ]]
}

@test "renderer: Rich render honors COUNCIL_THEME_RESOLVED for code highlighting" {
    source "$LIB"
    [ -n "$COUNCIL_TEST_RICH_CMD" ] || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    local code=$'```bash\nif true; then printf "%s" "$HOME"; fi\n```'
    local dark light
    dark=$(printf '%s' "$code" | COUNCIL_THEME_RESOLVED=dark "$PANE_DIR/render.sh")
    light=$(printf '%s' "$code" | COUNCIL_THEME_RESOLVED=light "$PANE_DIR/render.sh")
    [ -n "$dark" ]
    [ -n "$light" ]
    # Pin the mapping's DIRECTION, not just difference (an inverted mapping
    # also differs): ansi_dark uses bright SGRs (\033[9x), ansi_light none.
    [[ "$dark" == *$'\033[9'* ]]
    [[ "$light" != *$'\033[9'* ]]
}

@test "renderer: Rich render keeps content after an unclosed think tag" {
    source "$LIB"
    [ -n "$COUNCIL_TEST_RICH_CMD" ] || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    # A response truncated mid-reasoning must not vanish: the tail renders as
    # think content (perl parity), never silently dropped by Rich's HTML pass.
    local truncated=$'before text\n\n<think>\nreasoning tail'
    run bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$truncated" "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"before text"* ]]
    [[ "$output" == *"reasoning tail"* ]]
}

@test "renderer: Rich render survives COLUMNS=0" {
    source "$LIB"
    local py_cmd="$COUNCIL_TEST_RICH_CMD"
    [ -n "$py_cmd" ] || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    run bash -c "printf '%s' '# Title' | COLUMNS=0 $py_cmd \"\$1\"" _ "$PANE_DIR/render.py"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Title"* ]]
}

@test "renderer: Rich render styles link anchors underline-cyan, not dim" {
    source "$LIB"
    [ -n "$COUNCIL_TEST_RICH_CMD" ] || skip "no rich-capable python on this machine"
    display_write_renderer "$PANE_DIR/render.sh"
    run bash -c "printf '%s' 'see [label](https://example.com) now' | \"\$1\"" _ "$PANE_DIR/render.sh"
    [ "$status" -eq 0 ]
    # 4;36 = underline cyan, the perl renderer's anchor style. With
    # hyperlinks=True Rich styles the anchor text via markdown.link_url.
    [[ "$output" == *$'\033[4;36m'* ]]
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

# ----- tmux version gate -----
# The streaming pane uses `split-window -l '<pct>%'` (length as a percentage),
# which tmux only understands from 3.1 onward. tmux_version_supports_pane is the
# pure parser behind the "pane disabled: tmux >= 3.1" fallback notice.

@test "display: tmux_version_supports_pane accepts 3.1 and newer" {
    source "$LIB"
    run tmux_version_supports_pane "tmux 3.1"
    [ "$status" -eq 0 ]
    run tmux_version_supports_pane "tmux 3.6a"
    [ "$status" -eq 0 ]
    run tmux_version_supports_pane "tmux 4.0"
    [ "$status" -eq 0 ]
    run tmux_version_supports_pane "tmux next-3.4"
    [ "$status" -eq 0 ]
}

@test "display: tmux_version_supports_pane rejects versions older than 3.1" {
    source "$LIB"
    run tmux_version_supports_pane "tmux 3.0"
    [ "$status" -ne 0 ]
    run tmux_version_supports_pane "tmux 2.9"
    [ "$status" -ne 0 ]
    run tmux_version_supports_pane "tmux 1.8"
    [ "$status" -ne 0 ]
}

@test "display: tmux_version_supports_pane rejects unparseable version strings" {
    source "$LIB"
    run tmux_version_supports_pane "garbage"
    [ "$status" -ne 0 ]
    run tmux_version_supports_pane ""
    [ "$status" -ne 0 ]
}
