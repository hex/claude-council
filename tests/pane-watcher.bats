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
    fake_stty 80
}

# No teardown for $W: the watcher's EXIT trap removes the watch dir itself.

# Shadow stty on PATH so a test can move the pane width while the watcher runs.
# The watcher reads live width from `stty size`; under bats there is no tty, so
# the real stty always fails and the width would never change. COLS_FILE holds
# the current width — write to it to simulate a resize.
fake_stty() {
    FAKE_BIN="$W/fake-bin"
    COLS_FILE="$W/cols"
    mkdir -p "$FAKE_BIN"
    echo "$1" > "$COLS_FILE"
    cat > "$FAKE_BIN/stty" <<EOF
#!/bin/bash
[[ "\$1" == "size" ]] && { echo "24 \$(cat "$COLS_FILE")"; exit 0; }
exec /bin/stty "\$@"
EOF
    chmod +x "$FAKE_BIN/stty"
    export FAKE_BIN COLS_FILE
}

# Count every render the watcher performs. render.sh runs once per displayed
# response, so the marker lets a test sequence its writes against what is
# actually on screen instead of guessing at sleeps — the watcher's first tick
# can be a second late on a loaded machine.
count_renders() {
    : > "$W/renders"
    mv "$W/render.sh" "$W/render-body.sh"
    cat > "$W/render.sh" <<EOF
#!/bin/bash
echo rendered >> "$W/renders"
exec "$W/render-body.sh"
EOF
    chmod +x "$W/render.sh"
}

# Block until the watcher has rendered $1 responses in total. The cap is an
# `if`, not `[[ ... ]] && return 1`: bats runs tests under errexit, and that
# idiom yields status 1 on every ordinary iteration, which kills the caller.
await_renders() {
    local want="$1" waited=0
    while [[ $(wc -l < "$W/renders") -lt $want ]]; do
        sleep 0.05
        waited=$((waited + 1))
        if [[ $waited -gt 160 ]]; then
            echo "timed out waiting for $want renders" >&2
            return 1
        fi
    done
}

# The perl alarm turns a regression in the .done exit path into a SIGALRM
# failure (status 142) instead of a hung bats run.
run_watcher() {
    run --separate-stderr env COUNCIL_AUTO_CLOSE=1 COUNCIL_NO_TTY_QUERY=1 \
        PATH="$FAKE_BIN:$PATH" \
        perl -e 'alarm shift; exec @ARGV' 10 bash "$WATCHER" "$W" "$LIB"
}

# Everything the watcher printed after its last screen+scrollback clear, i.e.
# the surviving redraw.
after_last_redraw() {
    printf '%s' "$1" | perl -0777 -pe 's/.*\e\[3J//s'
}

count_matches() {
    printf '%s' "$2" | grep -o "$1" | wc -l | tr -d ' '
}

# Drop terminal escapes so blank lines can be counted. The DCS goes first: the
# SetMark passthrough wraps an OSC inside it, and it sits on the line above a
# banner, so leaving its bytes behind makes a blank line look occupied.
plain_text() {
    printf '%s' "$1" | perl -0777 -pe '
        s/\eP.*?\e\\//gs;
        s/\e\][^\a]*\a//g;
        s/\e\[[0-9;?]*[a-zA-Z]//g;
        s/\r//g;
    '
}

# Blank lines immediately above the first line containing $1.
blank_lines_before() {
    printf '%s' "$2" | awk -v m="$1" 'index($0, m) { print b + 0; exit } NF == 0 { b++; next } { b = 0 }'
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

@test "watcher: leaves two blank lines between one provider block and the next" {
    printf 'First answer\n' > "$W/responses/gemini.md"
    printf 'Second answer\n' > "$W/responses/openai.md"
    printf 'gemini\tcomplete\t1000\t\n' >> "$W/status"
    printf 'openai\tcomplete\t2000\t\n' >> "$W/status"
    run_watcher
    [ "$status" -eq 0 ]
    text=$(plain_text "$output")
    [[ "$text" == *"First answer"* ]]
    [ "$(blank_lines_before OPENAI "$text")" -eq 2 ]
}

@test "watcher: removes the watch dir on exit" {
    printf '## Bye\n' > "$W/responses/openai.md"
    run_watcher
    [ "$status" -eq 0 ]
    [ ! -d "$W" ]
}

@test "watcher: re-renders everything already shown when the pane width changes" {
    rm -f "$W/.done"
    fake_stty 40
    count_renders
    printf 'Hello from gemini\n' > "$W/responses/gemini.md"
    printf 'gemini\tcomplete\t1234\tgemini-2.5-pro\n' >> "$W/status"
    (
        await_renders 1; echo 100 > "$COLS_FILE"
        await_renders 2; touch "$W/.done"
    ) &
    run_watcher
    [ "$status" -eq 0 ]
    # Once as it landed, once replayed at the new width.
    [ "$(count_matches GEMINI "$output")" -eq 2 ]
    # Scrollback is cleared too, or the narrow copy survives in tmux history.
    [[ "$output" == *$'\033[3J'* ]]
    [[ "$(after_last_redraw "$output")" == *"Hello from gemini"* ]]
}

@test "watcher: replays responses and error notices in the order they appeared" {
    rm -f "$W/.done"
    fake_stty 40
    count_renders
    mkdir -p "$W/errors"
    printf 'First answer\n' > "$W/responses/gemini.md"
    printf 'gemini\tcomplete\t1000\t\n' >> "$W/status"
    printf 'no credentials\n' > "$W/errors/grok.txt"
    (
        # Both land after gemini is on screen, and a status line is always
        # consumed before the response glob, so the display order is fixed.
        await_renders 1
        printf 'grok\terror\t\t\n' >> "$W/status"
        printf 'Third answer\n' > "$W/responses/openai.md"
        await_renders 2; echo 100 > "$COLS_FILE"
        await_renders 4; touch "$W/.done"
    ) &
    run_watcher
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[3J'* ]]
    replay=$(after_last_redraw "$output")
    [[ "$replay" == *GEMINI*"grok error"*OPENAI* ]]
    [[ "$replay" == *"no credentials"* ]]
}

@test "watcher: still reflows while waiting at the close prompt" {
    fake_stty 40
    count_renders
    printf 'Hello from gemini\n' > "$W/responses/gemini.md"
    printf 'gemini\tcomplete\t1234\t\n' >> "$W/status"
    ( await_renders 1; echo 100 > "$COLS_FILE" ) &
    # The escape is withheld until the redraw has happened, so a blocking read
    # would sit on the old width forever. bash 3.2 rejects a fractional read
    # timeout, so the prompt polls once a second and the settle check needs two
    # of those ticks.
    run --separate-stderr env COUNCIL_AUTO_CLOSE=0 COUNCIL_NO_TTY_QUERY=1 \
        PATH="$FAKE_BIN:$PATH" \
        perl -e 'alarm shift; exec @ARGV' 12 bash "$WATCHER" "$W" "$LIB" \
        < <(await_renders 2; printf '\033')
    [ "$status" -eq 0 ]
    [ "$(count_matches GEMINI "$output")" -eq 2 ]
}

@test "watcher: closes on ctrl-d at the close prompt" {
    printf 'Hello\n' > "$W/responses/gemini.md"
    # stdin stays open well past the ctrl-d, so only reading the \004 itself
    # can end the wait.
    run --separate-stderr env COUNCIL_AUTO_CLOSE=0 COUNCIL_NO_TTY_QUERY=1 \
        PATH="$FAKE_BIN:$PATH" \
        perl -e 'alarm shift; exec @ARGV' 3 bash "$WATCHER" "$W" "$LIB" \
        < <(printf '\004'; sleep 6)
    [ "$status" -eq 0 ]
}

@test "watcher: closes when the pane's stdin is gone rather than polling forever" {
    printf 'Hello\n' > "$W/responses/gemini.md"
    run --separate-stderr env COUNCIL_AUTO_CLOSE=0 COUNCIL_NO_TTY_QUERY=1 \
        PATH="$FAKE_BIN:$PATH" \
        perl -e 'alarm shift; exec @ARGV' 8 bash "$WATCHER" "$W" "$LIB" \
        < /dev/null
    [ "$status" -eq 0 ]
}
