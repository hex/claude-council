#!/usr/bin/env bash
# ABOUTME: End-to-end run of the Claude Desktop extension's server against the real provider APIs
# ABOUTME: Keys come from the environment, as Desktop passes them; costs a few tokens per keyed provider

# Usage: GEMINI_API_KEY=... OPENROUTER_API_KEY=... tests/e2e/extension-e2e.sh [unpacked-package-dir]
# Runs the server from this checkout, or from an unpacked .mcpb when a directory
# is given, with a state directory of its own so the user's saved choices are
# untouched. Checks, for every provider with a key: its live model list loads,
# a saved model choice reaches a real council run and the answers panel's
# seats, and no key appears in any reply or in any file the run leaves. Every
# reply is kept under the printed directory for review.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="${1:-$ROOT/extension}/server/index.js"
CLIENT="$ROOT/tests/fixtures/mcp-client.js"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/extension-e2e.XXXXXX")"
export XDG_CONFIG_HOME="$OUT/config"
export CLIENT_REPLY_WAIT_MS=600000

KEY_VARIABLES=(GEMINI_API_KEY OPENAI_API_KEY XAI_API_KEY PERPLEXITY_API_KEY KIMI_API_KEY OPENROUTER_API_KEY)
declare -a keyed=()
for variable in "${KEY_VARIABLES[@]}"; do
    [[ -n "${!variable:-}" ]] && keyed+=("$variable")
done
if [[ ${#keyed[@]} -eq 0 ]]; then
    echo "No provider key in the environment; export at least one of: ${KEY_VARIABLES[*]}" >&2
    exit 2
fi

INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}},"clientInfo":{"name":"extension-e2e","version":"0"}}}'

# Runs one server session; the replies land in $OUT/<name>.jsonl.
session() {
    local name="$1"
    shift
    printf '%s\n' "$INIT" "$@" > "$OUT/$name.requests.jsonl"
    node "$CLIENT" "$SERVER" "$OUT/$name.requests.jsonl" > "$OUT/$name.jsonl" 2> "$OUT/$name.stderr"
}

tool() {
    jq -cn --argjson id "$1" --arg name "$2" --argjson args "${3:-{\}}" \
        '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $name, arguments: $args}}'
}

text_of() {
    jq -r --argjson id "$2" 'select(.id == $id) | .result.content[0].text' "$OUT/$1.jsonl"
}

failures=0
fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

session lists "$(tool 1 council_models_data)"
providers=$(text_of lists 1)
echo "$providers" | jq -r '.providers[] | select(.hasKey) | "\(.name): \(.models | length) models\(if .listError != "" then ", " + .listError else "" end)"'
while IFS= read -r name; do
    fail "$name's model list did not load"
done < <(echo "$providers" | jq -r '.providers[] | select(.hasKey and (.listError != "" or (.models | length) == 0)) | .name')

# One saved choice per keyed provider, other than its default so the run proves
# the choice reached it: the first of these chat models the live list offers,
# else the default itself. EXTENSION_E2E_SELECTIONS (a JSON object in the
# council_models_save shape) replaces the pick. The live lists also hold
# models no council seat can use (speech, image, embedding), so never a blind pick.
CANDIDATES='{"gemini":["gemini-flash-lite-latest","gemini-2.5-flash"],"openai":["gpt-4.1-mini","gpt-4o-mini"],
    "grok":["grok-4.7-fast"],"perplexity":["fast"],"kimi":["moonshot-v1-8k"],
    "openrouter":["openai/gpt-5-mini","google/gemini-2.5-flash","deepseek/deepseek-v4.1-flash"]}'
selections=${EXTENSION_E2E_SELECTIONS:-$(echo "$providers" | jq -c --argjson c "$CANDIDATES" '[.providers[] | select(.hasKey)
    | . as $p | [$c[$p.name][] | select(. as $id | $p.models | index($id))] as $offered
    | {key: .name, value: (if .roster then ($offered[0:2] | if length == 2 then . else [$p.defaultModel] end)
        else ($offered[0] // .defaultModel) end)}] | from_entries')}
asked=$(echo "$providers" | jq -c --argjson s "$selections" '[.providers[] | select(.hasKey) | .name
    | if . == "openrouter" then ("openrouter-" + ($s.openrouter | keys[] | . + 1 | tostring)) else . end]')
echo "saving: $selections"
echo "asking: $asked"
session ask \
    "$(tool 1 council_models_save "$(jq -cn --argjson s "$selections" '{selections: $s}')")" \
    "$(tool 2 council_settings)" \
    "$(tool 3 council_ask "$(jq -cn --argjson p "$asked" '{question: "In one sentence: what is a mutex?", providers: $p, verbosity: "brief"}')")" \
    "$(tool 4 council_status)"
[[ "$(text_of ask 1)" == '{"saved":true}' ]] || fail "the save was refused: $(text_of ask 1)"
text_of ask 2
answer=$(text_of ask 3)
[[ "$(jq -r 'select(.id == 3) | .result.isError' "$OUT/ask.jsonl")" == false ]] || fail "the council run failed: $answer"
while IFS= read -r model; do
    [[ "$answer" == *"$model"* ]] || fail "the answer does not name the saved model $model"
done < <(echo "$selections" | jq -r '.[] | if type == "array" then .[] else . end')
if grep -i '^error' <<< "$answer"; then fail "a seat answered with an error"; fi
seats=$(jq -c 'select(.id == 3) | .result.structuredContent.seats' "$OUT/ask.jsonl")
[[ "$(jq -c '[.[].provider]' <<< "$seats")" == "$asked" ]] || fail "the panel's seats $(jq -c '[.[].provider]' <<< "$seats") are not the seats asked, $asked"
while IFS= read -r failed; do
    fail "the panel shows an error for $failed"
done < <(jq -r '.[] | select(has("error")) | "\(.provider): \(.error)"' <<< "$seats")
text_of ask 4 | tail -4

for variable in "${keyed[@]}"; do
    if grep -rqFf <(printf '%s\n' "${!variable}") "$OUT"; then fail "the $variable value appears under $OUT"; fi
done

echo
echo "replies and the council answer: $OUT"
if [[ $failures -gt 0 ]]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
