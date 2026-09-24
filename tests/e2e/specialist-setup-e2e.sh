#!/usr/bin/env bash
# ABOUTME: End-to-end run of the /specialists screen in a real interactive Claude Code, driven through tmux
# ABOUTME: Writes ~/.claude/settings.json and restores it on every exit; quit other Claude sessions first

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/specialist-setup-e2e.XXXXXX")"
SESSION=specialist-setup-e2e
LOG="$OUT/debug.log"
SETTINGS="$HOME/.claude/settings.json"
cp "$SETTINGS" "$OUT/settings.before"

restore() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    cp "$OUT/settings.before" "$SETTINGS"
}
trap restore EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# The engine drops keys sent faster than it draws; one second apiece is enough.
key() { tmux send-keys -t "$SESSION" "$@"; sleep 1; }
screen() { tmux capture-pane -p -t "$SESSION"; }
row() { jq -r --arg s "$1" '.pluginConfigs["claude-council@inline"].options[$s] // ""' "$SETTINGS"; }

wait_for() {
    local tick=0
    until screen | grep -qF -- "$1"; do
        tick=$((tick + 1)); [ "$tick" -lt 20 ] || fail "never saw '$1'"; sleep 1
    done
}

# The focus ring is not visible in a plain capture; the debug log names each move.
focused() { grep "ui.focus Pane specialist-setup" "$LOG" | tail -1 | sed -n "s/.*onto claude-council's \(.*\): moved.*/\1/p"; }
focus_on() {
    local tries=0
    until [ "$(focused)" = "$1" ]; do
        tries=$((tries + 1)); [ "$tries" -le 20 ] || fail "focus never reached '$1' (at '$(focused)')"
        key Tab
    done
}

# An open Select draws its highlighted option in reverse video (SGR 7): read it
# from the escape codes and move until it is the one wanted.
highlighted() {
    tmux capture-pane -e -p -t "$SESSION" | LC_ALL=C sed 's/\x1b\[7m/<R>/g; s/\x1b\[[0-9;]*m/<E>/g' \
        | LC_ALL=C grep -o '<R>  [a-z0-9.-][a-z0-9.-]*' | head -1 | sed 's/^<R>  //'
}
pick() {
    local moves=0
    key Down
    until [ "$(highlighted)" = "$1" ]; do
        moves=$((moves + 1)); [ "$moves" -le 15 ] || fail "option '$1' never highlighted (at '$(highlighted)')"
        key Down
    done
    key Enter
}

SLOT="$(jq -r '(.pluginConfigs["claude-council@inline"].options // {}) as $o
    | ["specialist_1","specialist_2","specialist_3","specialist_4"]
    | map(select(($o[.] // "") | test("^\\s*$"))) | first // ""' "$OUT/settings.before")"
[ -n "$SLOT" ] || fail "all four specialist slots are in use; free one first"
WANT="e2e = gpt-6-luna as security, effort: max, when: e2e check"

tmux new-session -d -s "$SESSION" -x 160 -y 45 -c "$ROOT" \
    "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 $HOME/.local/bin/claude --plugin-dir $ROOT --debug-file $LOG"
wait_for '❯'
sleep 3
echo "1. open /specialists"
tmux send-keys -t "$SESSION" -l '/specialists'; key Enter
wait_for '+ Add'
screen > "$OUT/1-open.txt"

echo "2. add a draft in ${SLOT}"
focus_on add; key Enter
wait_for "NEW specialist"

echo "3. fill the form"
focus_on name; tmux send-keys -t "$SESSION" -l e2e; sleep 1
focus_on model; pick gpt-6-luna
focus_on effort; pick max
focus_on when; tmux send-keys -t "$SESSION" -l 'e2e check'; sleep 1
screen > "$OUT/3-filled.txt"

echo "4. save"
focus_on save; key Enter
wait_for "Saved e2e."
screen > "$OUT/4-saved.txt"
[ "$(row "$SLOT")" = "$WANT" ] || fail "${SLOT} is '$(row "$SLOT")', expected '$WANT'"

echo "5. remove"
focus_on "row:${SLOT}"; key Enter
focus_on remove; key Enter
wait_for "Remove e2e?"
focus_on confirm-yes; key Enter
wait_for "Removed e2e."
[ "$(row "$SLOT")" = "" ] || fail "${SLOT} is '$(row "$SLOT")' after remove"

echo "PASS ($OUT)"
