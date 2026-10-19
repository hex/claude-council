#!/usr/bin/env bash
# ABOUTME: End-to-end run of the heads-up side-check in a real interactive Claude Code, driven through tmux
# ABOUTME: The codex seat is the test suite's fake, so the band, its presses and the prompt-box draft are checked without a model

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/heads-up-e2e.XXXXXX")"
OUT="$(cd "$OUT" && pwd -P)"
SESSION=heads-up-e2e
LOG="$OUT/debug.log"
CLAUDE_JSON="$HOME/.claude.json"
PROJECT="$OUT/app"

# The fake codex writes the suite's fixed note through the schema; the runner
# finds it on PATH like the real one, and the mod's env scrub passes COUNCIL_FAKE_*.
# shellcheck source=../fixtures/fake-clis.bash
source "$ROOT/tests/fixtures/fake-clis.bash"
FAKE_BIN_DIR="$OUT/fakebin"
COUNCIL_FAKE_STATE_DIR="$OUT/fake-state"
mkdir -p "$FAKE_BIN_DIR" "$COUNCIL_FAKE_STATE_DIR" "$PROJECT/.claude"
export FAKE_BIN_DIR COUNCIL_FAKE_STATE_DIR
write_fake_cli codex

# The heads-up memory (seen and known topics, backoff), the usage counts and
# the intro flag are shared by every session in the plugin store; this run
# must leave all three as it found them. The intro flag is dropped for the run
# so the once-per-install line shows.
KEYS='["heads-up", "heads-up-counts", "heads-up-intro-shown"]'
for store in "$HOME"/.claude/plugins/store/claude-council_inline-*.json; do
    [ -f "$store" ] || continue
    jq --argjson keys "$KEYS" 'with_entries(select(.key as $k | $keys | index($k)))' "$store" > "$OUT/before.$(basename "$store")"
    jq 'del(.["heads-up-intro-shown"], .["heads-up-counts"])' "$store" > "$OUT/cleared.json"
    cat "$OUT/cleared.json" > "$store"
done
# The workspace trust dialog is one flag per project path; it is seeded so the
# script never types through a dialog whose text may change, and removed after.
jq --arg p "$PROJECT" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' "$CLAUDE_JSON" > "$OUT/claude.json.seeded"
cat "$OUT/claude.json.seeded" > "$CLAUDE_JSON"

restore() {
    tmux send-keys -t "$SESSION" -l '/exit' 2>/dev/null && tmux send-keys -t "$SESSION" Enter 2>/dev/null && sleep 3 || true
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    local saved store
    for saved in "$OUT"/before.*; do
        [ -f "$saved" ] || continue
        store="$HOME/.claude/plugins/store/${saved##*/before.}"
        jq --slurpfile before "$saved" --argjson keys "$KEYS" \
            'with_entries(select(.key as $k | $keys | index($k) | not)) + $before[0]' \
            "$store" > "$OUT/restored.json"
        cat "$OUT/restored.json" > "$store"
    done
    jq --arg p "$PROJECT" 'del(.projects[$p])' "$CLAUDE_JSON" > "$OUT/claude.json.restored"
    cat "$OUT/claude.json.restored" > "$CLAUDE_JSON"
    # A killed tmux test can leave claude alive (its process shows as its version, not "claude").
    if pgrep -f -- "--plugin-dir $ROOT --debug-file $LOG" > /dev/null; then
        pkill -f -- "--plugin-dir $ROOT --debug-file $LOG" || true
        echo "a test Claude survived /exit and was killed" >&2
    fi
}
trap restore EXIT

fail() {
    tmux capture-pane -p -S -400 -t "$SESSION" > "$OUT/fail.txt" 2>/dev/null || true
    echo "FAIL: $* (screen: $OUT/fail.txt, log: $LOG)" >&2
    exit 1
}
key() { tmux send-keys -t "$SESSION" "$@"; sleep 1; }
# A hotkey sent in the same second the band is drawn can land in the prompt
# box instead; the stray character is cleared and the press repeated once.
press() {
    sleep 2
    key "$1"
    if screen | grep -qE "^❯ $1\$"; then
        key C-u
        key "$1"
        screen | grep -qE "^❯ $1\$" && fail "the hotkey $1 typed into the prompt box twice"
    fi
}
screen() { tmux capture-pane -p -S -400 -t "$SESSION"; }
# A check takes the fake a moment, the engine draws on its own clock, and the
# model turn before the check is a real Haiku turn: a minute covers all three.
wait_for() {
    local tick=0
    until screen | grep -qF -- "$1"; do
        tick=$((tick + 1)); [ "$tick" -lt 90 ] || fail "never saw '$1'"; sleep 1
    done
}
memory() { jq -c '.["heads-up"] // {}' "$HOME"/.claude/plugins/store/claude-council_inline-*.json | head -1; }
counts() { jq -c '.["heads-up-counts"] // {}' "$HOME"/.claude/plugins/store/claude-council_inline-*.json | head -1; }

git -C "$PROJECT" init -q -b main
printf '{"enabled": false, "seat": "codex", "every": 2}\n' > "$PROJECT/.claude/council-heads-up.json"
echo "project: $PROJECT"

tmux new-session -d -s "$SESSION" -x 160 -y 45 -c "$PROJECT" \
    "PATH=$FAKE_BIN_DIR:\$PATH COUNCIL_FAKE_STATE_DIR=$COUNCIL_FAKE_STATE_DIR COUNCIL_FAKE_BEHAVIOR=heads-up-note CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 \
     $HOME/.local/bin/claude --plugin-dir $ROOT --debug-file $LOG --model haiku --permission-mode bypassPermissions --allow-dangerously-skip-permissions"
wait_for '❯'
sleep 3
screen | grep -qF 'trust' && fail "the trust dialog showed; the seed in ~/.claude.json did not take"

echo "0. the once-per-install tail sits on the prompt hint while the check is off; /heads-up reads the state and switches the project on"
wait_for 'Tip: /heads-up on lets another model watch long turns and flag what Claude missed'
screen > "$OUT/0-intro.txt"
tmux send-keys -t "$SESSION" -l '/heads-up'; key Enter
wait_for 'Heads-up side-check: off for this project'
screen | grep -qF 'Tip: /heads-up on lets another model watch long turns and flag what Claude missed' && fail "the intro tail is still drawn after typing"
tmux send-keys -t "$SESSION" -l '/heads-up on'; key Enter
wait_for 'Heads-up side-check: on for this project'
wait_for 'every    2 requests'
[ "$(cat "$PROJECT/.claude/council-heads-up.json")" = '{"enabled": true, "seat": "codex", "every": 2}' ] || fail "the file after /heads-up on is $(cat "$PROJECT/.claude/council-heads-up.json")"
screen > "$OUT/0-switch.txt"

echo "1. a turn of three shell commands reaches the cadence (every 2) and the fake seat's note is drawn"
tmux send-keys -t "$SESSION" -l 'Run date, then ls, then pwd, as three separate shell commands, one per step. Then say ok.'; key Enter
wait_for 'Heads up · The migration test used an empty fixture, so the backfill path never ran.'
wait_for '1: Learn more'
screen | grep -qF '2: Knew this already' || fail "the band lacks 2: Knew this already"
screen | grep -qF '4: Turn off' || fail "the band lacks 4: Turn off"
screen | grep -qF '0: Dismiss' || fail "the band lacks 0: Dismiss"
# The model is read from your own codex config, not from the fake.
screen | grep -qE 'codex · [^·]+ · [0-9.]+ KB · [0-9]+ s' || fail "the band lacks the seat line"
screen > "$OUT/1-band.txt"
echo "   band drawn; seat line: $(screen | grep -oE 'codex · [^·]+ · [0-9.]+ KB · [0-9]+ s')"
grep -q 'scripts/heads-up.schema.json' "$COUNCIL_FAKE_STATE_DIR/calls.jsonl" || fail "codex was not called with the schema"

echo "2. Learn more opens the title and bullets, the action bold last"
press 1
wait_for 'The backfill path never ran'
wait_for 'Seed one row in C:\fixtures\empty.db and rerun the migration test.'
screen | grep -qF -e '- The fixture had no rows, so the loop had nothing to do.' || fail "the first bullet is missing"
screen | grep -qF -e '- Seed one row in C:\fixtures\empty.db' || fail "the action bullet is missing"
wait_for '1: Tell Claude'
screen | grep -qF '0: Close' || fail "the expanded band lacks 0: Close"
screen > "$OUT/2-expanded.txt"

echo "3. Tell Claude closes the band and puts the draft in the prompt box, unsent"
press 1
wait_for 'A side check by codex (not you) raised this: The migration test used an empty fixture'
screen | grep -qF 'Tell Claude' && fail "the band is still drawn after Tell Claude"
screen | grep -qF 'What do you make of it?' || fail "the draft is cut before its question"
screen > "$OUT/3-draft.txt"
[ "$(memory | jq -r '.seen | index("backfill never ran")')" != "null" ] || fail "the topic did not join seen: $(memory)"
echo "   memory: $(memory)"

echo "4. the person sends the draft; Claude answers a note it only learned from them"
# The draft is the person's to edit before sending: a bound keeps Haiku from
# treating the note's action as a work order. The earlier turn's done line is
# gone once the screen redraws, so the new one is told apart by its wording.
tmux send-keys -t "$SESSION" -l ' Answer in one sentence and run nothing.'; sleep 1
key Enter
tick=0
until screen | grep -qF 'run nothing.' && screen | grep -qE '✻ .* done [0-9]' && ! screen | grep -qE '^[✶✻✽✾✿❀❁] [A-Z][a-z]+…'; do
    tick=$((tick + 1)); [ "$tick" -lt 180 ] || fail "the turn never finished"; sleep 1
done
screen > "$OUT/4-answered.txt"

echo "5. /heads-up status counts the checks, the one drawn note and the two presses"
# Claude's answer to the draft may run tools and launch a check of its own,
# which finds the same topic again: a repeat, nothing drawn. Every launched
# check settles before the counts are read.
tick=0
until [ "$(counts | jq '.checks == (.none + .notes + .repeats + .failed)')" = true ]; do
    tick=$((tick + 1)); [ "$tick" -lt 90 ] || fail "a check never settled: $(counts)"; sleep 1
done
C="$(counts)"
[ "$(printf '%s' "$C" | jq '.notes == 1 and .learn == 1 and .tell == 1 and .knew == 0 and .dismiss == 0 and .typedPast == 0 and .none == 0 and .failed == 0 and .checks == 1 + .repeats')" = true ] || fail "counts are $C"
# The engine redraws the whole screen, so earlier status lines are gone from
# the capture; the new one is told apart by its counts, which the earlier two
# showed as zero.
# The engine may leave a suggested prompt in the box; clear it first.
key C-u
tmux send-keys -t "$SESSION" -l '/heads-up status'; key Enter
wait_for "checks   $(printf '%s' "$C" | jq -r '"checks \(.checks) · none \(.none) · notes \(.notes) · repeats \(.repeats) · failed \(.failed)"')"
wait_for "presses  $(printf '%s' "$C" | jq -r '"learn \(.learn) · tell \(.tell) · knew \(.knew) · dismiss \(.dismiss) · turned off \(.turnOff) · typed past \(.typedPast)"')"
echo "   counts: $(printf '%s' "$C" | jq -c 'del(.repeats, .checks)') and every check settled"

echo "6. /exit leaves no claude behind"
tmux send-keys -t "$SESSION" -l '/exit'; key Enter
tick=0
while pgrep -f -- "--plugin-dir $ROOT --debug-file $LOG" > /dev/null; do tick=$((tick + 1)); [ "$tick" -lt 15 ] || fail "claude is still running after /exit"; sleep 1; done

echo "PASS ($OUT)"
