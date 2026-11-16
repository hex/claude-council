#!/usr/bin/env bash
# ABOUTME: End-to-end check that provider keys and the OpenRouter roster stored in the plugin's config reach a Bash-tool command in a real claude -p session
# ABOUTME: Placeholders come in through --settings, so nothing is written to Claude Code's secure storage or settings.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/stored-keys-e2e.XXXXXX")"
OUT="$(cd "$OUT" && pwd -P)"
SETTINGS="$OUT/settings.json"
SEEN="$OUT/seen.txt"
LOG="$OUT/debug.log"
USER_SETTINGS="$HOME/.claude/settings.json"
LIMIT_SECONDS=180
mkdir -p "$OUT/cwd"

placeholder() { printf 'e2e-%s' "$(openssl rand -hex 16)"; }
digest() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
# Account, service and modification date of every Claude Code credentials item, never the secret.
keychain_state() {
    security dump-keychain 2>/dev/null | awk '
        /^keychain:/ { if (svce ~ /Claude Code-credentials/) print acct, svce, mdat; acct = svce = mdat = "" }
        /"acct"<blob>=/ { acct = $0 }
        /"svce"<blob>=/ { svce = $0 }
        /"mdat"<timedate>=/ { mdat = $0 }
        END { if (svce ~ /Claude Code-credentials/) print acct, svce, mdat }' | sort
}

STORED_OPENAI="$(placeholder)"
STORED_GEMINI="$(placeholder)"
STORED_PERPLEXITY="$(placeholder)"
STORED_OPENROUTER="$(placeholder)"
STORED_ROSTER="$(placeholder)"
SHELL_GEMINI="$(placeholder)"
SHELL_PERPLEXITY="$(placeholder)"
SHELL_XAI="$(placeholder)"
SHELL_ROSTER="$(placeholder)"

settings_before="$(shasum -a 256 "$USER_SETTINGS" | cut -d' ' -f1)"
keychain_before="$(keychain_state)"

claude_pid=""
cleanup() {
    if [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null; then
        kill "$claude_pid" 2>/dev/null || true
        echo "the test Claude was still running and was killed" >&2
    fi
    rm -f "$SETTINGS"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $* (log: $LOG)" >&2
    exit 1
}

# The other options are pinned off so the run starts no heads-up check and offers no council tool.
( umask 077; jq -n --arg openai "$STORED_OPENAI" --arg gemini "$STORED_GEMINI" --arg perplexity "$STORED_PERPLEXITY" \
    --arg openrouter "$STORED_OPENROUTER" --arg roster "  $STORED_ROSTER " '{pluginConfigs: {"claude-council@inline": {options: {
    openai_api_key: $openai, gemini_api_key: $gemini, perplexity_api_key: $perplexity, openrouter_api_key: $openrouter,
    openrouter_models: $roster,
    heads_up: false, council_tool: false, wake_on_async_done: false}}}}' > "$SETTINGS" )

cat > "$OUT/probe.sh" <<'PROBE'
for name in OPENAI_API_KEY GEMINI_API_KEY PERPLEXITY_API_KEY OPENROUTER_API_KEY XAI_API_KEY OPENROUTER_MODELS; do
    value="${!name-}"
    printf '%s %s %s\n' "$name" "${#value}" "$(printf '%s' "$value" | shasum -a 256 | cut -d' ' -f1)"
done > "$1"
PROBE

(
    cd "$OUT/cwd"
    exec env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u XAI_API_KEY -u GROK_API_KEY \
        -u PERPLEXITY_API_KEY -u KIMI_API_KEY -u MOONSHOT_API_KEY -u OPENROUTER_API_KEY \
        GEMINI_API_KEY="$SHELL_GEMINI" PERPLEXITY_API_KEY="$SHELL_PERPLEXITY" XAI_API_KEY="$SHELL_XAI" \
        OPENROUTER_MODELS="$SHELL_ROSTER" \
        claude -p "Run this exact Bash command once, then reply with only the word done: bash $OUT/probe.sh $SEEN" \
        --plugin-dir "$ROOT" --settings "$SETTINGS" --debug-file "$LOG" \
        --model haiku --allowedTools Bash --no-session-persistence --max-turns 4 \
        < /dev/null > "$OUT/reply.txt" 2>&1
) &
claude_pid=$!
tick=0
while kill -0 "$claude_pid" 2>/dev/null; do
    tick=$((tick + 1))
    [ "$tick" -le "$LIMIT_SECONDS" ] || fail "claude -p still running after $LIMIT_SECONDS s"
    sleep 1
done
wait "$claude_pid" || fail "claude -p exited $? (reply: $OUT/reply.txt)"
claude_pid=""
[ -s "$SEEN" ] || fail "the Bash command never ran (reply: $OUT/reply.txt)"

mismatches=0
check() {
    local name="$1" case="$2" which="$3" want="$4" line
    line="$(grep "^$name " "$SEEN")" || fail "$name missing from $SEEN"
    if [ "$line" = "$name ${#want} $(digest "$want")" ]; then
        echo "$name $case: the $which value (length ${#want})"
    else
        echo "MISMATCH $name $case: want the $which value (length ${#want}), got length $(echo "$line" | cut -d' ' -f2)" >&2
        mismatches=$((mismatches + 1))
    fi
}
check OPENAI_API_KEY "stored, not exported" stored "$STORED_OPENAI"
check GEMINI_API_KEY "stored, the shell exports another" stored "$STORED_GEMINI"
check PERPLEXITY_API_KEY "stored, the shell exports another" stored "$STORED_PERPLEXITY"
check OPENROUTER_API_KEY "stored, not exported" stored "$STORED_OPENROUTER"
check XAI_API_KEY "not stored, the shell exports one" shell "$SHELL_XAI"
check OPENROUTER_MODELS "stored with surrounding spaces, the shell exports another" "stored, trimmed," "$STORED_ROSTER"
# A value already in Claude Code's secure storage for claude-council@inline wins over --settings.
[ "$mismatches" -eq 0 ] || fail "$mismatches of 6 variables did not hold the expected value"

[ "$(shasum -a 256 "$USER_SETTINGS" | cut -d' ' -f1)" = "$settings_before" ] || fail "$USER_SETTINGS changed during the run"
for value in "$STORED_OPENAI" "$STORED_GEMINI" "$STORED_PERPLEXITY" "$STORED_OPENROUTER" "$STORED_ROSTER"; do
    if grep -qF "$value" "$USER_SETTINGS"; then fail "a placeholder reached $USER_SETTINGS"; fi
done
[ "$(keychain_state)" = "$keychain_before" ] || fail "a Claude Code credentials keychain item changed or appeared during the run"
echo "settings.json and the credentials keychain items unchanged"
echo "PASS"
