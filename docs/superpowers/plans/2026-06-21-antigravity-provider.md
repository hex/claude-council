# Antigravity Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `gemini-cli` council provider with an `antigravity` provider driving the `agy` CLI, and add a runtime fallback so a failing CLI provider retries through its API sibling.

**Architecture:** Each provider is a `scripts/providers/<name>.sh` returning text on stdout (non-zero exit = failure). `lib/providers.sh` owns discovery and the CLI↔API pairing (`shadow_origin`). The new `antigravity` provider mirrors `codex.sh` (agentic CLI, gated on its binary). The fallback lives inside `query_provider()` in `query-council.sh`, keyed off a new reverse-of-`shadow_origin` lookup — so it covers both query rounds without touching discovery policy.

**Tech Stack:** Bash (3.2-compatible), `jq`, `bats` (with `tests/fixtures/fake-clis.bash` fake-binary harness), `agy` CLI v1.0.10.

## Global Constraints

- Bash must stay **3.2-compatible** (no associative arrays; existing code uses space-padded set strings and `printf -v`).
- Every shell file starts with two `# ABOUTME:` comment lines.
- No emojis in code/output except the existing vendor emoji set (🟦🔳🟥🟩⬛).
- TDD: failing test first, minimal code, green, commit. Commit after each task.
- Match surrounding code style; names describe purpose, not history (no "new"/"legacy").
- `agy` invocation contract (empirically verified): flags **before** the prompt — `agy --sandbox --model "<model>" -p "<prompt>"`. The prompt must carry a tool-suppression guard or `agy` writes an artifact file instead of answering inline.
- Default antigravity model: `Gemini 3.5 Flash (High)` (overridable via `ANTIGRAVITY_MODEL`).
- `shadow_origin(gemini)` becomes `antigravity`; `gemini-cli` is removed entirely (no compat alias).

---

### Task 1: Reverse-lookup helpers in `lib/providers.sh`

Foundation for the fallback: given a failed CLI provider, which API provider does it fall back to, and is that sibling's key present?

**Files:**
- Modify: `scripts/lib/providers.sh` (add two functions next to `shadow_origin`)
- Test: `tests/cli-providers.bats`

**Interfaces:**
- Produces:
  - `api_sibling <cli_provider>` → echoes the API provider a CLI falls back to (`codex`→`openai`, `antigravity`→`gemini`), empty otherwise. Inverse of `shadow_origin`.
  - `api_key_present <api_provider>` → exit 0 if that provider's API key env var is set, else exit 1.

- [ ] **Step 1: Write the failing tests**

Add to `tests/cli-providers.bats` after the `prefer_cli_over_api` block:

```bash
# ============================================================================
# api_sibling — reverse of shadow_origin (CLI → API fallback target)
# ============================================================================

@test "api_sibling: codex falls back to openai" {
    run source_lib_and_call 'api_sibling codex'
    [ "$status" -eq 0 ]
    [[ "$output" == "openai" ]]
}

@test "api_sibling: antigravity falls back to gemini" {
    run source_lib_and_call 'api_sibling antigravity'
    [ "$status" -eq 0 ]
    [[ "$output" == "gemini" ]]
}

@test "api_sibling: provider with no sibling yields empty" {
    run source_lib_and_call 'api_sibling grok'
    [ "$status" -eq 0 ]
    assert_blank "$output"
}

@test "api_key_present: true when the env var is set" {
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        export GEMINI_API_KEY=x
        api_key_present gemini && echo YES
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "YES" ]]
}

@test "api_key_present: false when the env var is unset" {
    run bash -c "
        export PROVIDERS_DIR='${PROVIDERS_DIR_REAL}'
        source '${PROVIDERS_LIB}'
        unset GEMINI_API_KEY
        api_key_present gemini || echo NO
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "NO" ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-providers.bats -f "api_sibling|api_key_present"`
Expected: FAIL — `api_sibling: command not found` / `api_key_present: command not found`.

- [ ] **Step 3: Implement the helpers**

In `scripts/lib/providers.sh`, immediately after the `shadow_origin()` function, add:

```bash
# Reverse of shadow_origin: the API provider a failed CLI provider falls back
# to (or empty if none). Kept adjacent to shadow_origin as its paired inverse —
# the two enumerate the same CLI↔API pairs and must stay in sync.
api_sibling() {
    case "$1" in
        codex)       echo "openai" ;;
        antigravity) echo "gemini" ;;
        *)           echo "" ;;
    esac
}

# True (exit 0) if the API key env var for an API provider is set. Mirrors the
# per-provider gating in discover_providers.
api_key_present() {
    case "$1" in
        gemini)     [[ -n "${GEMINI_API_KEY:-}" ]] ;;
        openai)     [[ -n "${OPENAI_API_KEY:-}" ]] ;;
        grok)       [[ -n "${GROK_API_KEY:-}" ]] ;;
        perplexity) [[ -n "${PERPLEXITY_API_KEY:-}" ]] ;;
        *)          return 1 ;;
    esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-providers.bats -f "api_sibling|api_key_present"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/providers.sh tests/cli-providers.bats
git commit -m "Add api_sibling/api_key_present reverse lookups for CLI→API fallback"
```

---

### Task 2: Replace `gemini-cli` with the `antigravity` provider

One atomic swap: create `antigravity.sh`, delete `gemini-cli.sh`, repoint every `lib/providers.sh` touchpoint, update the fake-CLI fixture, and update both bats suites.

**Files:**
- Create: `scripts/providers/antigravity.sh`
- Delete: `scripts/providers/gemini-cli.sh`
- Modify: `scripts/lib/providers.sh` (discover_providers, shadow_origin, get_model, provider_color, provider_emoji)
- Modify: `tests/fixtures/fake-clis.bash` (fake `gemini` → fake `agy`)
- Modify: `tests/cli-providers.bats`, `tests/fake-clis.bats`

**Interfaces:**
- Consumes: `get_model`, `BASE_SYSTEM_PROMPT`, `verbosity_prefix` (existing).
- Produces: `scripts/providers/antigravity.sh` accepting one prompt arg; `antigravity` recognized by `discover_providers`/`get_model`/`shadow_origin`/`provider_color`/`provider_emoji`.

- [ ] **Step 1: Write the failing provider-registration tests**

In `tests/cli-providers.bats`, replace the test `discover_providers: includes gemini-cli when gemini binary is on PATH` with:

```bash
@test "discover_providers: includes antigravity when agy binary is on PATH" {
    if ! command_exists agy; then skip "agy CLI not installed"; fi
    run source_lib_and_call 'discover_providers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"antigravity"* ]]
}
```

In the same file, replace the `prefer_cli_over_api: drops gemini when gemini-cli is present` and `drops both API siblings` tests' `gemini-cli` tokens with `antigravity`, e.g.:

```bash
@test "prefer_cli_over_api: drops gemini when antigravity is present" {
    run source_lib_and_call 'prefer_cli_over_api antigravity gemini perplexity'
    [ "$status" -eq 0 ]
    [[ "$output" == *"antigravity"* ]]
    [[ "$output" == *"perplexity"* ]]
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}

@test "prefer_cli_over_api: drops both API siblings when both CLIs present" {
    run source_lib_and_call 'prefer_cli_over_api codex antigravity openai gemini grok'
    [ "$status" -eq 0 ]
    [[ "$output" == *"codex"* ]]
    [[ "$output" == *"antigravity"* ]]
    [[ "$output" == *"grok"* ]]
    [[ "$output" != *"openai"* ]]
    [[ ! "$output" =~ (^|[[:space:]])gemini([[:space:]]|$) ]]
}
```

Add a new test for `shadow_origin` and `get_model`:

```bash
@test "shadow_origin: gemini is shadowed by antigravity" {
    run source_lib_and_call 'shadow_origin gemini'
    [ "$status" -eq 0 ]
    [[ "$output" == "antigravity" ]]
}

@test "get_model: antigravity default is a Gemini Flash model" {
    run source_lib_and_call 'get_model antigravity'
    [ "$status" -eq 0 ]
    [[ "$output" == "Gemini 3.5 Flash (High)" ]]
}
```

Replace the `--providers gemini-cli flag is accepted` test:

```bash
@test "query-council: --providers antigravity flag is accepted" {
    run bash "$SCRIPT" --providers=antigravity "test prompt" 2>&1
    [[ "$output" != *"Unknown flag"* ]]
}
```

Delete the test `gemini-cli.sh: real gemini accepts the args we send (skip-trust guard)` and replace it with a real-`agy` presence-gated guard test:

```bash
# ============================================================================
# Real-CLI guard — runs whenever the real agy is present (not COUNCIL_E2E).
# Verifies the flag ordering + tool-suppression guard against the actual CLI:
# agy must answer inline (no artifact pointer) and accept our flags.
# ============================================================================

@test "antigravity.sh: real agy answers inline for a trivial prompt" {
    if ! command_exists agy; then skip "agy CLI not installed"; fi
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "Reply with exactly the word: OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    # Inline answer, not an artifact pointer
    [[ "$output" != *"file:///"* ]]
}
```

Also update the file's top ABOUTME line and the `--list-available` test's `gemini` mention:
- ABOUTME line 2: `codex/gemini-cli provider integration` → `codex/antigravity provider integration`.
- In `query-council: --list-available shows CLI providers when binaries present`, change the `command_exists gemini` / `gemini-cli` branch to `command_exists agy` / `antigravity`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-providers.bats`
Expected: FAIL — `shadow_origin gemini` returns `gemini-cli`; `get_model antigravity` returns `unknown`; antigravity discovery/guard fail (no `antigravity.sh`).

- [ ] **Step 3: Create `scripts/providers/antigravity.sh`**

```bash
#!/bin/bash
# ABOUTME: Queries Google's Antigravity CLI (agy) in print mode using subscription auth
# ABOUTME: Availability is gated on the agy binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
    echo "Error: agy CLI not found on PATH" >&2
    exit 1
fi

# agy is an agentic coding assistant, not a chat CLI: left unconstrained it
# answers by writing a report artifact to disk and returning a pointer to it.
# This guard makes it answer inline as plain text with no tool use — the only
# effective control, since agy exposes no flag to disable tools or set output.
GUARD="IMPORTANT: Respond with your complete answer as plain text directly in this conversation. Do NOT use any tools. Do NOT write, create, or edit any files. Do NOT create artifacts, reports, or documents. Do NOT reference external files. Provide your entire response inline as text."

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${GUARD}

${SYSTEM}

${PROMPT}"

MODEL=$(get_model antigravity)
# Flags must precede the prompt: agy uses Go's flag package, which stops
# parsing at the first positional argument, so flags after the prompt get
# folded into the prompt text. --sandbox restricts terminal access as
# defense-in-depth alongside the guard.
ARGS=(--sandbox --model "$MODEL" -p "$FULL_PROMPT")

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(agy "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
    echo "Error from antigravity CLI: ${ERR_MSG:-non-zero exit}" >&2
    exit 1
fi
```

Then make it executable:

```bash
chmod +x scripts/providers/antigravity.sh
```

- [ ] **Step 4: Repoint `lib/providers.sh` registration**

In `scripts/lib/providers.sh`:

In `discover_providers`, replace the `gemini-cli` case:
```bash
            antigravity)
                command -v agy >/dev/null 2>&1 && is_available=true
                ;;
```
(also update the function's header comment `codex, gemini-cli` → `codex, antigravity`).

In `shadow_origin`, change the gemini line:
```bash
        gemini) echo "antigravity" ;;
```

In `get_model`, replace the `gemini-cli` line:
```bash
        antigravity) echo "${ANTIGRAVITY_MODEL:-Gemini 3.5 Flash (High)}" ;;
```

In `provider_color`, change the gemini group:
```bash
        gemini|antigravity) echo -e "${BLUE}" ;;
```

In `provider_emoji`, change the gemini group:
```bash
        gemini|antigravity) echo "🟦" ;;
```

- [ ] **Step 5: Delete the old provider**

```bash
git rm scripts/providers/gemini-cli.sh
```

- [ ] **Step 6: Update the fake-CLI fixture**

In `tests/fixtures/fake-clis.bash`:
- ABOUTME line 1: `fake codex/gemini CLI executables` → `fake codex/agy CLI executables`.
- In `install_fake_clis`, change the loop: `for bin in codex gemini; do` → `for bin in codex agy; do`.

(The generic fake handles `agy` unchanged: it records args, answers the `valid` marker `FAKE-AGY-RESPONSE`, and errors on `error`/`auth-failure`. agy is never invoked with `--version` by the provider, so that branch is simply unused.)

- [ ] **Step 7: Update `tests/fake-clis.bats`**

- ABOUTME line 1: `fake codex/gemini binaries` → `fake codex/agy binaries`.
- Replace `fixture: fake gemini shadows any real gemini on PATH` with:
```bash
@test "fixture: fake agy shadows any real agy on PATH" {
    run command -v agy
    [ "$status" -eq 0 ]
    [[ "$output" == "$FAKE_BIN_DIR/agy" ]]
}
```
- Replace the three `gemini-cli.sh` tests with `antigravity.sh` equivalents:
```bash
# ============================================================================
# antigravity.sh against the fake binary
# ============================================================================

@test "antigravity.sh: returns fake response on valid behavior" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAKE-AGY-RESPONSE"* ]]
}

@test "antigravity.sh: sends --sandbox, model flag, and -p prompt with guard, flags before prompt" {
    export COUNCIL_FAKE_BEHAVIOR=valid
    export ANTIGRAVITY_MODEL="test-model-z"
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "another question"
    [ "$status" -eq 0 ]
    local call
    call=$(tail -1 "$COUNCIL_FAKE_STATE_DIR/calls.jsonl")
    assert_json_eq "$call" '.bin' "agy"
    [[ "$(echo "$call" | jq -r '.args[0]')" == "--sandbox" ]]
    [[ "$(echo "$call" | jq -r '.args | index("--model") as $i | .[$i+1]')" == "test-model-z" ]]
    # -p is the last flag; the prompt is the final positional arg and carries the guard
    [[ "$(echo "$call" | jq -r '.args[-2]')" == "-p" ]]
    [[ "$(echo "$call" | jq -r '.args[-1]')" == *"another question"* ]]
    [[ "$(echo "$call" | jq -r '.args[-1]')" == *"Do NOT use any tools"* ]]
}

@test "antigravity.sh: surfaces stderr and exits 1 on auth-failure behavior" {
    export COUNCIL_FAKE_BEHAVIOR=auth-failure
    run "${PROVIDERS_DIR_REAL}/antigravity.sh" "test prompt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not logged in"* ]]
}
```
- In `discover_providers: includes both CLI providers with fakes on PATH`, change `gemini-cli` → `antigravity`.

- [ ] **Step 8: Run both suites to verify they pass**

Run: `bats tests/cli-providers.bats tests/fake-clis.bats`
Expected: PASS (antigravity discovery, shadow_origin, get_model, fake-binary behavior, flag ordering + guard all green; the real-`agy` guard test runs if `agy` is installed, else skips).

- [ ] **Step 9: Commit**

```bash
git add scripts/providers/antigravity.sh scripts/lib/providers.sh \
    tests/fixtures/fake-clis.bash tests/cli-providers.bats tests/fake-clis.bats
git commit -m "Replace gemini-cli provider with antigravity (agy)"
```

---

### Task 3: CLI→API fallback in `query_provider()`

When a CLI provider's script errors, retry through its API sibling (if the key is set) and write the API answer into the same slot, tagged with the API model and a `fallback` note.

**Files:**
- Modify: `scripts/query-council.sh:8` (PROVIDERS_DIR seam), `query_provider()` error branch (~331-338)
- Modify: `scripts/lib/providers.sh` (`coerce_result_json`: input-provided model wins)
- Test: `tests/cli-providers.bats`

**Interfaces:**
- Consumes: `api_sibling`, `api_key_present`, `get_model` (Task 1 + existing).
- Produces: a fallback result `{status:"success", response, model:<api-model>, fallback:<api-provider>, …}` written into the CLI provider's slot.

- [ ] **Step 1: Write the failing coerce test (preserve provider-supplied model)**

Add to `tests/cli-providers.bats` in the `coerce_result_json` block:

```bash
@test "coerce_result_json: a model already in the result is preserved, not overwritten" {
    run source_lib_and_call $'coerce_result_json \'{"status":"success","response":"hi","model":"gemini-3.1-pro-preview"}\' some-default-model'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.model')" == "gemini-3.1-pro-preview" ]]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/cli-providers.bats -f "preserved"`
Expected: FAIL — model is `some-default-model` (current `coerce` overwrites).

- [ ] **Step 3: Make input-provided model win in `coerce_result_json`**

In `scripts/lib/providers.sh`, change the final line of `coerce_result_json` from:
```bash
    jq --arg m "$model" '. + {model: $m}' <<<"$raw"
```
to:
```bash
    # {model:$m} + . lets a model already present in the result win; the
    # default applies only when the provider didn't set one (fallback results
    # carry the API sibling's model and must not be relabeled here).
    jq --arg m "$model" '{model: $m} + .' <<<"$raw"
```

- [ ] **Step 4: Run the coerce tests to verify all pass**

Run: `bats tests/cli-providers.bats -f "coerce_result_json"`
Expected: PASS (4 tests — the 3 existing + the new one).

- [ ] **Step 5: Write the failing fallback integration test**

Add a new block to `tests/cli-providers.bats`:

```bash
# ============================================================================
# CLI→API fallback — a failing CLI provider retries through its API sibling.
# Hermetic: a temp PROVIDERS_DIR with a failing antigravity.sh and a stub
# gemini.sh, driven through the real query-council.sh orchestration.
# ============================================================================

@test "query-council: antigravity failure falls back to the gemini API sibling" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-providers"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    cat > "$fakedir/gemini.sh" <<'EOF'
#!/bin/bash
echo "FALLBACK-GEMINI-ANSWER"
EOF
    chmod +x "$fakedir/antigravity.sh" "$fakedir/gemini.sh"

    run env PROVIDERS_DIR="$fakedir" GEMINI_API_KEY="test-key" \
        bash "$SCRIPT" --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    local slot
    slot=$(echo "$output" | jq -c '.round1.antigravity')
    [[ "$(echo "$slot" | jq -r '.status')" == "success" ]]
    [[ "$(echo "$slot" | jq -r '.response')" == *"FALLBACK-GEMINI-ANSWER"* ]]
    [[ "$(echo "$slot" | jq -r '.fallback')" == "gemini" ]]
    [[ "$(echo "$slot" | jq -r '.model')" == "gemini-3.1-pro-preview" ]]
}

@test "query-council: antigravity failure with no gemini key stays an error" {
    local fakedir="${BATS_TEST_TMPDIR}/fallback-nokey"
    mkdir -p "$fakedir"
    cat > "$fakedir/antigravity.sh" <<'EOF'
#!/bin/bash
echo "Error from antigravity CLI: boom" >&2
exit 1
EOF
    chmod +x "$fakedir/antigravity.sh"

    run env PROVIDERS_DIR="$fakedir" bash "$SCRIPT" \
        --no-cache --no-pane --providers=antigravity "ping"
    [ "$status" -eq 0 ]
    local slot
    slot=$(echo "$output" | jq -c '.round1.antigravity')
    [[ "$(echo "$slot" | jq -r '.status')" == "error" ]]
    [[ "$(echo "$slot" | jq -r '.error')" == *"boom"* ]]
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `bats tests/cli-providers.bats -f "falls back|stays an error"`
Expected: FAIL — the first test's `antigravity` slot is `status:error` (no fallback yet); `GEMINI_API_KEY` is unset by `PROVIDERS_DIR` not being honored (line 8 hardcodes the dir).

- [ ] **Step 7: Add the PROVIDERS_DIR seam**

In `scripts/query-council.sh` line 8, change:
```bash
PROVIDERS_DIR="${SCRIPT_DIR}/providers"
```
to:
```bash
PROVIDERS_DIR="${PROVIDERS_DIR:-${SCRIPT_DIR}/providers}"
```

- [ ] **Step 8: Add the fallback to `query_provider()`**

In `scripts/query-council.sh`, replace the error branch (the `else` block at ~331-338, currently writing the error result) with:

```bash
    else
        # CLI provider failed — fall back to its API sibling when one exists and
        # its key is set. The slot keeps the CLI provider's identity but carries
        # the API answer, the API model, and a `fallback` note.
        local sibling sibling_script sibling_model fb_response
        sibling=$(api_sibling "$provider")
        if [[ -n "$sibling" ]] && api_key_present "$sibling"; then
            sibling_script="${PROVIDERS_DIR}/${sibling}.sh"
            sibling_model=$(get_model "$sibling")
            if [[ -x "$sibling_script" ]] && fb_response=$("$sibling_script" "$final_prompt" 2>&1); then
                local elapsed=$(( $(now_ms) - start_ms ))
                jq -n --arg r "$fb_response" --arg role "$role" \
                    --arg fb "$sibling" --arg m "$sibling_model" \
                    '{status: "success", response: $r, cached: false, model: $m, fallback: $fb, role: (if $role == "" then null else $role end)}' > "$output_file"
                if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
                    pane_status_event "$COUNCIL_PANE_DIR" "$provider" complete "$elapsed" "$sibling_model"
                    pane_response_write "$COUNCIL_PANE_DIR" "$provider" "$fb_response"
                fi
                if [[ "$USE_CACHE" == true ]]; then
                    local key
                    key=$(cache_key "$sibling" "$sibling_model" "$final_prompt")
                    cache_set "$key" "$sibling" "$sibling_model" "$final_prompt" "$fb_response"
                fi
                return
            fi
        fi
        # No fallback available, or it failed too: preserve the CLI error.
        jq -n --arg e "$response" --arg role "$role" \
            '{status: "error", error: $e, cached: false, role: (if $role == "" then null else $role end)}' > "$output_file"
        if [[ -n "${COUNCIL_PANE_DIR:-}" ]]; then
            pane_error_write "$COUNCIL_PANE_DIR" "$provider" "$response"
            pane_status_event "$COUNCIL_PANE_DIR" "$provider" error "" "$model"
        fi
    fi
```

- [ ] **Step 9: Run the fallback + full suite to verify green**

Run: `bats tests/cli-providers.bats`
Expected: PASS (both fallback tests + everything else). The `model` in the fallback slot survives the collection loop because Task 3 Step 3 made the result's own model win in `coerce_result_json`.

- [ ] **Step 10: Commit**

```bash
git add scripts/query-council.sh scripts/lib/providers.sh tests/cli-providers.bats
git commit -m "Fall back to API sibling when a CLI provider fails"
```

---

### Task 4: Documentation and ancillary scripts

Bring `check-status.sh`, `display.sh`, and the docs in line with the new provider.

**Files:**
- Modify: `scripts/check-status.sh`, `scripts/lib/display.sh`
- Modify: `README.md`, `TESTING.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update `scripts/check-status.sh`**

- `remediation_for`: replace `gemini-cli:no_binary) echo "npm install -g @google/gemini-cli" ;;` with:
  ```bash
        antigravity:no_binary) echo "install the Antigravity CLI (agy)" ;;
  ```
- Replace the status probe line:
  ```bash
  gemini_cli_status=$(check_cli_provider "gemini-cli" "gemini")
  ```
  with:
  ```bash
  antigravity_status=$(check_cli_provider "antigravity" "agy")
  ```
  and update the preceding comment `gemini has no equivalent offline auth probe` → `agy has no equivalent offline auth probe`.
- Replace the format line:
  ```bash
  format_status "Gemini CLI" "gemini-cli" "$gemini_cli_status"
  ```
  with:
  ```bash
  format_status "Antigravity" "antigravity" "$antigravity_status"
  ```

- [ ] **Step 2: Update `scripts/lib/display.sh`**

In both color tables, change the `gemini|gemini-cli)` group to `gemini|antigravity)`:
- Line ~311: `gemini|antigravity) printf -v "$__out" '59;130;246'   ;;  # blue-500`
- Line ~450: `gemini|antigravity) bg='30;64;175';   fg='255;255;255'; accent='147;197;253' ;;  # blue-700/300`

- [ ] **Step 3: Verify status + display still run**

Run: `bash scripts/check-status.sh` (expect an "Antigravity" row, no `gemini-cli`).
Run: `bats tests/display.bats` (expect green — no behavioral change, just renamed cases).
Expected: clean output; suite passes.

- [ ] **Step 4: Update `README.md`**

- Line ~16 comment: `install the codex / gemini CLIs` → `install the codex / antigravity (agy) CLIs`.
- Line ~409: `--providers=gemini,gemini-cli` → `--providers=gemini,antigravity`.
- Line ~415 env example: replace
  ```bash
  export GEMINI_CLI_MODEL="gemini-3-pro"          # default: gemini-3-flash-preview
  ```
  with:
  ```bash
  export ANTIGRAVITY_MODEL="Gemini 3.1 Pro (High)"  # default: Gemini 3.5 Flash (High)
  ```

- [ ] **Step 5: Update `docs/ARCHITECTURE.md`**

- Line ~34 diagram: `| gemini-cli|` → `|antigravity|`.
- Lines ~131-134: `**CLI providers** (`codex`, `gemini-cli`)` → ``codex`, `antigravity``; `gemini-cli+gemini` → `antigravity+gemini`.
- Line ~140: `CODEX_MODEL` / `GEMINI_CLI_MODEL` → `CODEX_MODEL` / `ANTIGRAVITY_MODEL`.
- Line ~371: `│   │   └── gemini-cli.sh        # CLI (subscription auth, shadows gemini)` → `│   │   └── antigravity.sh       # CLI (subscription auth, shadows gemini)`.
- Line ~404: `cli-providers.bats       # CLI providers (codex, gemini-cli)` → `(codex, antigravity)`.
- Line ~433 env table: `| `GEMINI_CLI_MODEL` | gemini-3-flash-preview | Model passed to `gemini -m` |` → `| `ANTIGRAVITY_MODEL` | Gemini 3.5 Flash (High) | Model passed to `agy --model` |`.
- If the architecture text describes the CLI-prefers-API policy, add one sentence: "If a CLI provider fails at query time, the council retries through its API sibling (when that key is set) and marks the slot as a fallback."

- [ ] **Step 6: Update `TESTING.md`**

- Line ~44: `codex/gemini-cli discovery` → `codex/antigravity discovery`; bump the cli-providers.bats test count to the new total.
- Line ~51: `codex.sh/gemini-cli.sh against fake binaries` → `codex.sh/antigravity.sh against fake binaries`; update its count if changed.
- Line ~199 heading `2b. CLI Providers (codex / gemini-cli)` → `(codex / antigravity)`.
- Line ~203 sample command `--providers=codex,gemini-cli` → `--providers=codex,antigravity`.
- Line ~218 checklist: `codex, gemini-cli, grok, perplexity` → `codex, antigravity, grok, perplexity`.

- [ ] **Step 7: Final full-suite gate**

Run: `bats tests/` (or the repo's standard test command).
Expected: all green. Confirm no `gemini-cli` reference remains: `rg -n 'gemini-cli|GEMINI_CLI' --glob '!docs/superpowers/**' --glob '!CHANGELOG.md' --glob '!.cs/**'` returns nothing.

- [ ] **Step 8: Commit**

```bash
git add README.md TESTING.md docs/ARCHITECTURE.md scripts/check-status.sh scripts/lib/display.sh
git commit -m "Docs + status/display: gemini-cli → antigravity"
```

---

## Self-Review

**Spec coverage:**
- Component 1 (antigravity.sh) → Task 2 Steps 3-4. ✓ (guard, flag order, --sandbox, default model)
- Component 2 (remove gemini-cli, register antigravity) → Task 2 (providers.sh, fixture, both bats). ✓
- Component 3 (fallback in query_provider, all pairs, same-slot+model+note) → Task 3. ✓ (`api_sibling` covers codex→openai too; `coerce` model-preserve; integration tests)
- Testing section → covered across Tasks 1-3; real-`agy` presence-gated guard in Task 2. ✓
- Docs/ancillary (README, TESTING, ARCHITECTURE, check-status, display) → Task 4. ✓
- Out-of-scope items (no compat alias, no new flags beyond ANTIGRAVITY_MODEL, discovery policy untouched) → respected. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type/name consistency:** `api_sibling`, `api_key_present`, `coerce_result_json`, `get_model antigravity` → `"Gemini 3.5 Flash (High)"`, `fallback` field, `ANTIGRAVITY_MODEL`, marker `FAKE-AGY-RESPONSE` used consistently across tasks. ✓

**Note for the implementer:** codex→openai fallback is now active (Task 3) even though no codex-specific test drives it — it shares the exact code path the antigravity tests exercise, via `api_sibling`. If you want belt-and-suspenders, add a codex variant of the fallback integration test using a fake `codex.sh` + `openai.sh` and `OPENAI_API_KEY`; it is not required for coverage.
