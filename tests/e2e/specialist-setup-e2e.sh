#!/usr/bin/env bash
# ABOUTME: End-to-end run of the /specialists screen in a real interactive Claude Code, driven through tmux
# ABOUTME: Writes the specialists field of ~/.claude/settings.json and puts it back on every exit

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/specialist-setup-e2e.XXXXXX")"
SESSION=specialist-setup-e2e
LOG="$OUT/debug.log"
SETTINGS="$HOME/.claude/settings.json"
# The plugin store is shared with every live session of the plugin; a draft
# there is someone's unsaved work, and this run would type into it.
for store in "$HOME"/.claude/plugins/store/claude-council_inline-*.json; do
    [ -f "$store" ] || continue
    if jq -e '.["specialist-setup"].draft != null' "$store" >/dev/null; then
        echo "FAIL: a /specialists draft is open in $store; save or discard it first" >&2
        exit 1
    fi
done
cp "$SETTINGS" "$OUT/settings.before"

# Puts back only the specialists field, so a live session's other settings
# written meanwhile survive.
restore() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    local before
    before="$(jq '.pluginConfigs["claude-council@inline"].options.specialists' "$OUT/settings.before")"
    jq --argjson v "$before" 'if $v == null then del(.pluginConfigs["claude-council@inline"].options.specialists) else .pluginConfigs["claude-council@inline"].options.specialists = $v end' "$SETTINGS" > "$OUT/settings.restored"
    cat "$OUT/settings.restored" > "$SETTINGS"
}
trap restore EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# The engine drops keys sent faster than it draws; one second apiece is enough.
key() { tmux send-keys -t "$SESSION" "$@"; sleep 1; }
screen() { tmux capture-pane -p -t "$SESSION"; }
# The specialists live in one hidden settings field, a JSON list of objects.
entries() { jq -r '.pluginConfigs["claude-council@inline"].options.specialists // "[]"' "$SETTINGS"; }

wait_for() {
    local tick=0
    until screen | grep -qF -- "$1"; do
        tick=$((tick + 1)); [ "$tick" -lt 20 ] || fail "never saw '$1'"; sleep 1
    done
}

# The focus ring is not visible in a plain capture; the debug log names each move.
# Text fields carry an epoch suffix (name.3) that changes after each Enter.
focused() { grep "ui.focus Pane specialist-setup" "$LOG" | tail -1 | sed -n "s/.*onto claude-council's \(.*\): moved.*/\1/p" | sed 's/\.[0-9]*$//'; }
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

BEFORE="$(jq -r '.pluginConfigs["claude-council@inline"].options.specialists // "[]"' "$OUT/settings.before")"
INDEX="$(printf '%s' "$BEFORE" | jq 'length')"
# How /config names the hidden row in a typed /config key=value.
CONFIG_KEY="${SPECIALIST_CONFIG_KEY:-specialists}"
WANT='{"effort":"max","instructions":"say e2e first","model":"gpt-6-luna","name":"e2e","when":"e2e check"}'

tmux new-session -d -s "$SESSION" -x 160 -y 45 -c "$ROOT" \
    "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 $HOME/.local/bin/claude --plugin-dir $ROOT --debug-file $LOG"
wait_for '❯'
sleep 3
echo "1. open /specialists"
tmux send-keys -t "$SESSION" -l '/specialists'; key Enter
wait_for '+ Add'
screen > "$OUT/1-open.txt"

echo "2. add a new specialist"
focus_on add; key Enter
wait_for "NEW specialist"

echo "3. fill the form; Enter in a text field keeps its text and moves on"
focus_on name; tmux send-keys -t "$SESSION" -l e2e; sleep 1
key Enter
[ "$(focused)" = model ] || fail "Enter in name moved focus to '$(focused)', expected model"
pick gpt-6-luna
focus_on effort; pick max
focus_on when; tmux send-keys -t "$SESSION" -l 'e2e check'; sleep 1
key Enter
[ "$(focused)" = instructions ] || fail "Enter in use-when moved focus to '$(focused)', expected instructions"
tmux send-keys -t "$SESSION" -l 'say e2e first'; sleep 1
key Enter
[ "$(focused)" = save ] || fail "Enter in instructions moved focus to '$(focused)', expected save"
screen > "$OUT/3-filled.txt"
screen | grep -qF 'e2e check' || fail "the use-when text was lost after Enter"

echo "4. save"
key Enter
wait_for "Saved e2e."
screen > "$OUT/4-saved.txt"
GOT="$(entries | jq -cS --argjson i "$INDEX" '.[$i]')"
[ "$GOT" = "$WANT" ] || fail "specialist $((INDEX + 1)) is '$GOT', expected '$WANT'"

echo "5. remove"
focus_on "row:${INDEX}"; key Enter
focus_on remove; key Enter
wait_for "Remove e2e?"
focus_on confirm-yes; key Enter
wait_for "Removed e2e."
[ "$(entries | jq -c .)" = "$(printf '%s' "$BEFORE" | jq -c .)" ] || fail "the list is $(entries) after remove, expected $BEFORE"

echo "6. a list set by hand is checked like a Save"
key Escape
wait_for '❯'
tmux send-keys -t "$SESSION" -l "/config $CONFIG_KEY=nope"; key Enter
wait_for "the specialists setting is not JSON: nope"
screen > "$OUT/6-hand-edit.txt"
[ "$(entries | jq -c .)" = "$(printf '%s' "$BEFORE" | jq -c .)" ] || fail "the refused hand edit changed the list to $(entries)"

echo "PASS ($OUT)"
