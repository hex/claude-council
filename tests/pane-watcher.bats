#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/pane-watcher.sh
# ABOUTME: Drives the standalone pane watcher against a prebuilt watch dir

load test_helper
bats_require_minimum_version 1.5.0

LIB="${LIB_DIR}/display.sh"
WATCHER="${LIB_DIR}/pane-watcher.sh"
DEADLINE="${LIB_DIR}/deadline.sh"

# Build a watch dir the watcher consumes in one pass: a perl render.sh plus
# .done pre-created, so the poll loop breaks after its first iteration.
setup() {
    source "$DEADLINE"
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

# Block until a file appears. Same errexit-safe `if` as await_renders, and for
# the same reason: `[[ ... ]] && return 1` yields status 1 on every ordinary
# iteration, which kills the caller under bats.
await_file() {
    local f="$1" waited=0
    while [[ ! -e "$f" ]]; do
        sleep 0.05
        waited=$((waited + 1))
        if [[ $waited -gt 200 ]]; then
            echo "timed out waiting for $f" >&2
            return 1
        fi
    done
}

# Block until a file contains a string. Same errexit-safe shape as the two above.
await_content() {
    local f="$1" want="$2" waited=0
    while ! grep -qF "$want" "$f" 2>/dev/null; do
        sleep 0.05
        waited=$((waited + 1))
        if [[ $waited -gt 200 ]]; then
            echo "timed out waiting for '$want' in $f" >&2
            return 1
        fi
    done
}

# The watcher under run_with_deadline, so a regression in the .done exit path
# fails with status 143 instead of hanging the bats run. A shell function, not
# a binary, so callers set COUNCIL_AUTO_CLOSE as a prefix assignment on `run`
# rather than through env.
bounded_watcher() {
    PATH="$FAKE_BIN:$PATH" COUNCIL_NO_TTY_QUERY=1 \
        run_with_deadline "$1" bash "$WATCHER" "$W" "$LIB"
}

run_watcher() {
    COUNCIL_AUTO_CLOSE=1 run --separate-stderr bounded_watcher 10
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

@test "watcher: shows error text written the way the producer writes it, with no trailing newline" {
    # The fixture goes through pane_error_write, not a hand-written file: the
    # producer stores a command substitution, which has no trailing newline,
    # and a reader that needs one shows nothing for every real error.
    (source "$LIB" && pane_error_write "$W" kimi-cli "Error from kimi CLI: no assistant content in response")
    printf 'kimi-cli\terror\t\t\n' >> "$W/status"
    run_watcher
    [ "$status" -eq 0 ]
    [[ "$output" == *"kimi-cli error"* ]]
    [[ "$output" == *"no assistant content in response"* ]]
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

@test "watcher: a width that keeps moving does not redraw until it settles" {
    rm -f "$W/.done"
    fake_stty 40
    count_renders
    printf 'Hello from gemini\n' > "$W/responses/gemini.md"
    printf 'gemini\tcomplete\t1234\t\n' >> "$W/status"
    (
        await_renders 1
        # A drag: a new width every tick, none of them held. tmux moves in
        # whole-cell steps, so consecutive polls can repeat a width the drag
        # is about to abandon — settling on the first repeat would redraw at
        # a width nobody chose, at ~1s and a scrollback wipe each time.
        for w in 44 44 52 52 61 61 70 70 78 78; do
            echo "$w" > "$COLS_FILE"
            sleep 0.13
        done
        echo 100 > "$COLS_FILE"
        await_renders 2
        touch "$W/.done"
    ) &
    run_watcher
    [ "$status" -eq 0 ]
    # Exactly one redraw, at the width the drag came to rest on.
    [ "$(count_matches GEMINI "$output")" -eq 2 ]
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
    COUNCIL_AUTO_CLOSE=0 run --separate-stderr bounded_watcher 12 \
        < <(await_renders 2; printf '\033')
    [ "$status" -eq 0 ]
    [ "$(count_matches GEMINI "$output")" -eq 2 ]
}

@test "watcher: closes on ctrl-d at the close prompt" {
    printf 'Hello\n' > "$W/responses/gemini.md"
    # stdin stays open well past the ctrl-d, so only reading the \004 itself
    # can end the wait.
    COUNCIL_AUTO_CLOSE=0 run --separate-stderr bounded_watcher 3 \
        < <(printf '\004'; sleep 6)
    [ "$status" -eq 0 ]
}

@test "watcher: closes when the pane's stdin is gone rather than polling forever" {
    printf 'Hello\n' > "$W/responses/gemini.md"
    COUNCIL_AUTO_CLOSE=0 run --separate-stderr bounded_watcher 8 \
        < /dev/null
    [ "$status" -eq 0 ]
}

# ----- Retry offer -----

# A producer's offer: open for $1 seconds, naming the providers after it.
write_offer() {
    local seconds="$1"; shift
    (source "$LIB" && pane_retry_offer_write "$W" "$seconds" "$@")
}

# Play the producer's side of the offer with the real helper: when the pane
# accepts, deliver the retried answer; either way, end the run.
producer_awaits_retry() {
    local seconds="$1"
    if (source "$LIB" && pane_retry_await "$W" "$seconds"); then
        printf 'kimi-cli\tquerying\t\t\n' >> "$W/status"
        printf 'Answer on retry\n' > "$W/responses/kimi-cli.md"
        printf 'kimi-cli\tcomplete\t900\t\n' >> "$W/status"
    fi
    # The watcher may already have left (esc, dead tty) and removed the dir.
    touch "$W/.done" 2>/dev/null || true
}

# Keep the watcher's stdin open exactly as long as the watcher lives (its EXIT
# trap removes the watch dir), so no feeder outlives the test.
until_watcher_exits() {
    while [[ -d "$W" ]]; do sleep 0.1; done
}

@test "watcher: offers a retry naming the failed providers, and r asks the producer for one" {
    rm -f "$W/.done"
    (source "$LIB" && pane_error_write "$W" kimi-cli "Error from kimi CLI: transient")
    printf 'kimi-cli\terror\t\t\n' >> "$W/status"
    write_offer 5 kimi-cli
    producer_awaits_retry 8 &
    COUNCIL_AUTO_CLOSE=1 run --separate-stderr bounded_watcher 12 \
        < <(sleep 1; printf 'r'; until_watcher_exits)
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"[r] retry failed (kimi-cli)"* ]]
    # The countdown shows the seconds the producer said the offer stays open.
    [[ "$output" == *"5s"* ]]
    # The prompt sits under the error and the retried answer lands after it.
    [[ "$output" == *"kimi-cli error"*"[r] retry failed"*"KIMI-CLI"*"Answer on retry"* ]]
}

@test "watcher: esc at the retry offer closes the pane" {
    rm -f "$W/.done"
    write_offer 5 kimi-cli
    COUNCIL_AUTO_CLOSE=1 run --separate-stderr bounded_watcher 8 \
        < <(sleep 1; printf '\033'; until_watcher_exits)
    # .done never arrives, so only the close can end the wait — and the watch
    # dir going away is what tells the producer to carry on without a retry.
    [ "$status" -eq 0 ]
    [[ "$output" == *"[r] retry failed (kimi-cli)"* ]]
    [ ! -d "$W" ]
}

@test "watcher: a withdrawn offer falls back to the plain close prompt" {
    rm -f "$W/.done"
    write_offer 5 kimi-cli
    # The producer's one-second deadline passes unanswered: it withdraws the
    # offer and finishes.
    producer_awaits_retry 1 &
    COUNCIL_AUTO_CLOSE=0 run --separate-stderr bounded_watcher 12 \
        < <(sleep 4; printf '\033'; until_watcher_exits)
    [ "$status" -eq 0 ]
    [[ "$output" == *"[r] retry failed (kimi-cli)"*"[esc/ctrl-d] close"* ]]
    # The close prompt must not keep advertising a retry nobody can take.
    [[ "${output##*\[esc/ctrl-d\] close}" != *"[r]"* ]]
}

@test "watcher: the retry prompt fits the pane width with autowrap off" {
    rm -f "$W/.done"
    fake_stty 40
    write_offer 5 gemini openai grok perplexity
    producer_awaits_retry 1 &
    COUNCIL_AUTO_CLOSE=1 run --separate-stderr bounded_watcher 8
    [ "$status" -eq 0 ]
    # Drawn between DECAWM off/on like the waiting line, so a prompt wider
    # than the pane clips instead of leaving a stale wrapped row every tick.
    [[ "$output" == *$'\033[?7l'*"[r] retry failed ("*$'\033[?7h'* ]]
    # The provider list is cut to the pane, not the countdown after it.
    [[ "$output" == *"…"*"close"* ]]
    [[ "$output" != *"perplexity"* ]]
}

@test "watcher: a provider that fails again on retry replays both errors, each once" {
    rm -f "$W/.done"
    fake_stty 40
    (source "$LIB" && pane_error_write "$W" kimi-cli "first failure")
    printf 'kimi-cli\terror\t\t\n' >> "$W/status"
    write_offer 5 kimi-cli
    (
        (source "$LIB" && pane_retry_await "$W" 8)
        printf 'kimi-cli\tquerying\t\t\n' >> "$W/status"
        (source "$LIB" && pane_error_write "$W" kimi-cli "second failure")
        printf 'kimi-cli\terror\t\t\n' >> "$W/status"
        # The redraw under test has to happen while the watcher is still
        # polling, and .done ends that. Waiting for the feeder to confirm the
        # width change makes that ordering explicit; previously both sides
        # timed it independently and only agreed when the machine was idle.
        await_file "$W/.redrawn"
        touch "$W/.done"
    ) &
    COUNCIL_AUTO_CLOSE=0 run --separate-stderr bounded_watcher 16 \
        < <(sleep 1; printf 'r'
            # The replay must contain both failures, so the redraw comes after
            # the second one is recorded. pane_error_write overwrites the
            # provider's error file, so its content is the signal.
            await_content "$W/errors/kimi-cli.txt" "second failure"
            echo 100 > "$COLS_FILE"
            # The redraw itself lands on the watcher's stdout, which this feeder
            # cannot observe, so this one wait stays a sleep — bounded and
            # generous rather than tuned. Everything downstream of it is now
            # ordered by the .redrawn handshake rather than by the clock.
            sleep 2
            touch "$W/.redrawn"
            printf '\033'; until_watcher_exits)
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[3J'* ]]
    replay=$(after_last_redraw "$output")
    # Shown on failure: how many redraws happened and what the last one
    # holds, so a slow runner's ordering is visible rather than inferred.
    echo "redraws: $(count_matches $'\033\[3J' "$output")"
    echo "second-failure matches in full output: $(count_matches 'second failure' "$output")"
    echo "replay (plain text):"
    plain_text "$replay"
    [ "$(count_matches 'first failure' "$replay")" -eq 1 ]
    [ "$(count_matches 'second failure' "$replay")" -eq 1 ]
    [[ "$replay" == *"first failure"*"second failure"* ]]
}
