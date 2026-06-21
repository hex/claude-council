# Design: Replace `gemini-cli` with `antigravity`, add CLI→API fallback

Date: 2026-06-21
Status: Awaiting review

## Goal

Three coupled changes to the council's provider system:

1. **Remove the `gemini-cli` provider entirely.** It is superseded by a new
   provider for Google's Antigravity CLI, which fills the same role
   (Gemini models via a subscription/OAuth CLI, no per-call API cost).
2. **Add an `antigravity` provider** that drives the `agy` binary in print mode.
3. **Add a runtime CLI→API fallback.** When a CLI provider's invocation fails,
   the council retries the query through that CLI's API sibling (if its key is
   set) so the slot still produces an answer instead of an error.

## Background: the existing provider system

- Each provider is a script `scripts/providers/<name>.sh` that reads a prompt
  and writes a text response to stdout (non-zero exit on failure).
- `lib/providers.sh` owns discovery and policy:
  - `discover_providers()` — a provider is "available" if its API key is set
    (API providers) or its binary is on `PATH` (CLI providers: `codex`,
    `gemini-cli`).
  - `shadow_origin(api)` — single source of truth for API↔CLI pairings.
    Returns the CLI that shadows a given API provider (`openai`→`codex`,
    `gemini`→`gemini-cli`).
  - `prefer_cli_over_api(list)` — discovery-time policy: when a CLI and its API
    sibling are both available, drop the API sibling. The CLI wins by default.
  - `get_model`, `provider_color`, `provider_emoji` — switch on provider name;
    CLI variants share their vendor's color/emoji (`gemini`+`gemini-cli` → 🟦).
- `query-council.sh` orchestrates: `query_provider()` runs one provider's
  script into a temp file as a status-tagged JSON result; round 1 runs the
  selected set in parallel, round 2 runs an optional follow-up. Both rounds
  call `query_provider()`.

Key distinction this design rests on:

- The current CLI-prefers-API policy is **discovery-time** — it decides which
  providers run *before* any of them run.
- The new fallback is **runtime** — it reacts to a CLI provider *failing during
  execution*. It therefore cannot live in `prefer_cli_over_api`; it hooks into
  `query_provider()`.

## The `agy` CLI (empirically verified, v1.0.10)

`agy` is an **agentic coding assistant**, not a plain chat CLI. Relevant facts
established by direct testing:

- Print mode: `agy --print "<prompt>"` (`-p` / `--prompt` are aliases). It uses
  Go's `flag` package, which stops parsing at the first positional argument, so
  **all flags must precede the prompt** (`agy --sandbox --model X -p "<prompt>"`).
  Putting flags after the prompt feeds them into the prompt as text.
- Left to its own devices, print mode behaves agentically: given a question it
  **wrote a `report.md` artifact to disk and returned a stdout pointer to it**
  instead of answering inline. This makes its raw output unusable for a council.
- There is **no flag** to disable tool use or set an output format. The only
  effective control is a **prompt guard** instructing it to answer inline as
  plain text and not use tools / write files. With the guard, it returns a
  clean, complete inline markdown answer and writes no artifact.
- `--sandbox` runs with terminal restrictions (blocks `run_command`); used as
  defense-in-depth alongside the guard.
- `agy models` lists human-readable names like `Gemini 3.5 Flash (High)`,
  `Gemini 3.1 Pro (High)`, plus some Claude/GPT-OSS options. `--model` takes
  these exact strings. Default family is Gemini 3.5 Flash.
- Auth is via Google account login (OAuth), not an API key — hence gating on
  the binary, like `codex`.

## Design

### Component 1 — `scripts/providers/antigravity.sh`

Modeled on `codex.sh` (the existing agentic-CLI provider).

- Gate: error out if `agy` is not on `PATH`.
- Model: `MODEL=$(get_model antigravity)`, overridable via `ANTIGRAVITY_MODEL`,
  default `"Gemini 3.5 Flash (High)"` (mirrors the prior gemini-cli flash
  default, with high thinking effort).
- Prompt assembly, in order:
  1. **Tool-suppression guard** — a fixed instruction block: answer inline as
     plain text, do not use tools, do not write/create/edit files, do not
     create artifacts or reports, provide the entire response inline.
  2. Verbosity prefix + `BASE_SYSTEM_PROMPT` (same as other providers).
  3. The user prompt.
- Invocation: `agy --sandbox --model "$MODEL" -p "$FULL_PROMPT"`, capturing
  stderr to a temp file, mirroring `codex.sh`'s error handling (emit
  `Error from antigravity CLI: …` and exit 1 on failure).

The guard is the load-bearing element — it is what converts agy from an
artifact-emitting agent into an inline advisor. It lives in this script (not in
`BASE_SYSTEM_PROMPT`) because it is specific to agentic CLIs; the API providers
must not receive it.

### Component 2 — remove `gemini-cli`, register `antigravity`

- Delete `scripts/providers/gemini-cli.sh`.
- `lib/providers.sh`:
  - `discover_providers()`: remove the `gemini-cli` case; add
    `antigravity) command -v agy …`.
  - `shadow_origin()`: repoint `gemini` from `gemini-cli` → `antigravity`.
  - `get_model()`: remove `gemini-cli`; add `antigravity` (default
    `"Gemini 3.5 Flash (High)"`).
  - `provider_color()` / `provider_emoji()`: rename the `gemini|gemini-cli`
    group to `gemini|antigravity` (stays 🟦 blue — same vendor).
- `query-council.sh`: the "No providers configured" hint that lists
  `(codex, gemini)` becomes `(codex, agy)`.
- `scripts/check-status.sh`, `scripts/lib/display.sh`: replace `gemini-cli`
  references with `antigravity` / `agy`.
- Docs: `README.md`, `TESTING.md`, `docs/ARCHITECTURE.md` (provider list,
  diagram, env-var table: `GEMINI_CLI_MODEL` → `ANTIGRAVITY_MODEL`).

### Component 3 — runtime CLI→API fallback in `query_provider()`

- Add a reverse-of-`shadow_origin` lookup in `lib/providers.sh`, e.g.
  `api_sibling(cli)` returning `codex`→`openai`, `antigravity`→`gemini`. It is
  kept directly adjacent to `shadow_origin` and documented as its paired
  inverse so the two cannot drift (the pairing remains a single conceptual
  source of truth).
- In `query_provider()`: when the provider script exits non-zero, before
  writing the error result, check:
  1. `api_sibling(provider)` is non-empty, **and**
  2. that sibling's API key is set (e.g. `GEMINI_API_KEY` for `gemini`).
  If both hold, run the sibling's script with the same final prompt:
  - On sibling success: write a **success** result into the *same slot*
    (same provider key), carrying the sibling's response, the sibling's model
    name, and a `fallback` field naming the sibling (e.g. `"gemini"`). Pane
    events report `complete` with the sibling's model.
  - On sibling failure (or no key): write the **original CLI error** result
    (the API failure is not more informative to the user than the CLI one).
- Display: per decision, the slot keeps the CLI provider's identity/position
  (`antigravity`), but shows the API model name and a short "fell back to API"
  note sourced from the `fallback` field. `format-output.sh` / `display.sh`
  render the note.
- Because round 1 and round 2 both call `query_provider()`, fallback applies to
  both with no change to the round loops. `prefer_cli_over_api` is untouched.

## Data flow

```
query_provider("antigravity")
   └─ run antigravity.sh  ── success ─→ {status:success, response, model:"Gemini …"}
                          └─ failure ─→ api_sibling = "gemini"
                                          ├─ GEMINI_API_KEY set?
                                          │     ├─ run gemini.sh ── success ─→
                                          │     │     {status:success, response,
                                          │     │      model:"gemini-3.1-pro-preview",
                                          │     │      fallback:"gemini"}
                                          │     └─ failure ─→ original CLI error
                                          └─ no key ─→ original CLI error
```

## Error handling

- antigravity.sh: same contract as codex.sh — non-zero exit + `Error from
  antigravity CLI: <first 500 chars of stderr>` on any failure (binary missing,
  print timeout, non-zero exit).
- Fallback: never masks a successful CLI answer; only triggers on CLI failure.
  A failed fallback preserves the original CLI error so the user sees the root
  cause, not a secondary symptom.
- `coerce_result_json` continues to guard against malformed provider JSON
  downstream (unchanged).

## Testing (TDD)

Extend `tests/cli-providers.bats` (and its `fake-clis.bash` fixtures):

- `antigravity` is discovered when a fake `agy` is on `PATH`, absent otherwise.
- The provider script builds the invocation with flags before the prompt and
  includes the tool-suppression guard text.
- `gemini-cli` is fully gone: no `gemini-cli.sh`, not discovered, not in
  `shadow_origin`/`get_model`/color/emoji.
- `shadow_origin(gemini)` now returns `antigravity`.
- Fallback: with a fake `agy` that exits non-zero and a `gemini` API key set
  (stubbed `gemini.sh`), the `antigravity` slot ends up `status:success` with
  the gemini model and a `fallback` field. With no key, it stays an error
  carrying the CLI's message.
- Fallback applies symmetrically to `codex`→`openai`.

## Out of scope / YAGNI

- No backward-compatibility shim or alias for `gemini-cli` (per explicit
  decision to remove it entirely).
- No new flags or config surface beyond `ANTIGRAVITY_MODEL`.
- No change to the discovery-time `prefer_cli_over_api` policy.
- No attempt to use agy's non-Gemini models (Claude/GPT-OSS) — the provider
  speaks for the Gemini vendor and shadows the Gemini API.
