#!/usr/bin/env bash
# ABOUTME: One real heads-up check against the logged-in codex: the digest of a session you name goes to codex
# ABOUTME: Sends that session's last turns and tool results off the machine, so it is run by hand, with consent, never by run_tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SID="${1:?usage: heads-up-codex-e2e.sh <session-id> [run-dir]}"
RUN="${2:-$(mktemp -d "${TMPDIR:-/tmp}/heads-up-codex-e2e.XXXXXX")}"
mkdir -p "$RUN"
: > "$RUN/avoid.txt"

t0=$(date +%s)
bash "$ROOT/scripts/heads-up.sh" --run-dir "$RUN" --session "$SID" --seat codex --avoid-file "$RUN/avoid.txt"
tick=0
until [ -f "$RUN/.done" ]; do
    tick=$((tick + 1)); [ "$tick" -lt 200 ] || { echo "FAIL: no .done after 200 s" >&2; exit 1; }
    sleep 1
done
echo "done after $(( $(date +%s) - t0 )) s; prompt bytes $(wc -c < "$RUN/prompt.md" | tr -d ' ')"
cat "$RUN/result.json"
kind="$(jq -r .kind "$RUN/result.json")"
[ "$kind" = none ] || [ "$kind" = note ] || { echo "FAIL: kind $kind" >&2; exit 1; }
echo "PASS ($RUN)"
