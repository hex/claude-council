#!/usr/bin/env bash
# ABOUTME: End-to-end run of scripts/specialist.sh against the real codex: start, round, network follow-up, merge
# ABOUTME: Costs a few cents of Codex usage, so it is run by hand and not by run_tests.sh

set -euo pipefail

SPECIALIST="$(cd "$(dirname "$0")/../.." && pwd)/scripts/specialist.sh"
MODEL="${SPECIALIST_E2E_MODEL:-gpt-6-sol}"

fail() { echo "FAIL: $*" >&2; exit 1; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specialist-e2e.XXXXXX")"
HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
REPO="${HOME_DIR}/app"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email e2e@example.com
git -C "$REPO" config user.name E2E
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '[ "$(bash answer.sh)" = "42" ] && echo "test: pass"' > "$REPO/test.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
echo "repo: $REPO (model $MODEL)"

echo "1. start"
out="$("$SPECIALIST" start "$REPO" e2e "$(date +%Y%m%d-%H%M%S)")"
WT="$(field "$out" worktree)"; BR="$(field "$out" branch)"; STATE="$(field "$out" state)"; BASE="$(field "$out" base)"
echo "   branch=$BR"

echo "2. round 1: write answer.sh"
out="$(printf '%s' "Create answer.sh that prints 42. Then run: bash test.sh" | "$SPECIALIST" codex "$WT" "$STATE" "$MODEL")"
THREAD="$(field "$out" thread)"
echo "   exit=$(field "$out" exit) thread=${THREAD:0:8}..."
[ "$(field "$out" exit)" = 0 ] || { tail -20 "${STATE}/stderr.txt" >&2; fail "round 1 exit $(field "$out" exit)"; }
[ -n "$THREAD" ] || fail "round 1 printed no thread id"

echo "3. commit round 1 (Codex may have committed its work itself; either way the branch moves)"
out="$("$SPECIALIST" commit "$WT" "specialist e2e: answer")"
commits="$(git -C "$WT" rev-list --count "${BASE}..HEAD")"
echo "   $out, branch commits since base: $commits"
[ "$commits" -gt 0 ] || fail "round 1 left no commit on the branch"
[ -f "${WT}/answer.sh" ] || fail "round 1 did not create answer.sh"

echo "4. round 2 (resume): network reachable from the sandbox"
out="$(printf '%s' "Run: curl -sS -o /dev/null -w '%{http_code}' https://example.com and reply with only the code" | "$SPECIALIST" codex "$WT" "$STATE" "$MODEL" "$THREAD")"
echo "   exit=$(field "$out" exit) same-thread=$([ "$(field "$out" thread)" = "$THREAD" ] && echo yes || echo no) reply=$(tr -d '\n' < "${STATE}/last-message.md")"
[ "$(field "$out" exit)" = 0 ] || fail "round 2 exit $(field "$out" exit)"
[ "$(field "$out" thread)" = "$THREAD" ] || fail "round 2 did not resume thread $THREAD"
grep -q 200 "${STATE}/last-message.md" || fail "network step did not return 200"

echo "5. merge"
out="$("$SPECIALIST" finish "$REPO" "$WT" "$BR" merge)"
echo "   $out"
[ "$out" = "finished=merge" ] || fail "merge: $out"
[ ! -d "$WT" ] || fail "worktree still present"
(cd "$REPO" && bash test.sh) || fail "test.sh fails in the main repo after merge"

echo "6. all steps passed"
rm -rf "$HOME_DIR"
