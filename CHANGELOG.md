# Changelog

All notable changes to claude-council are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to a `YYYY.M.BUILD` versioning scheme where `BUILD` resets each month.

## 2026.7.6

### Added

- **`grok-cli` provider.** Drives xAI's Grok CLI (`grok`) in headless
  single-turn mode (`grok -p ... --output-format plain`), gated on the binary
  being on PATH rather than an API key — so a Grok CLI subscription answers the
  council with no `XAI_API_KEY` and no per-call cost, the same way `codex` and
  `antigravity` already do. It shadows the `grok` API provider (listing both,
  e.g. `--providers=grok,grok-cli`, runs them side by side), pins grok's
  built-in `read-only` sandbox as defense-in-depth, and defaults to the grok
  CLI's own default model unless `GROK_CLI_MODEL` is set. Because it is a
  CLI, an image query routes to its `grok` API sibling when a key is present,
  and answers text-only otherwise.

### Docs

- Added grok-cli to provider enumerations, the configuration reference, and
  manual test scenarios across README, ARCHITECTURE, and TESTING.

## 2026.7.5

### Added

- **Model fallback for API providers.** When a provider's default model is
  unavailable for your key or region — the API answers 403/404, or a 400
  naming the model — the council retries with a verified fallback model
  instead of failing, and reports the substitution on three surfaces: the
  rendered header (`grok-4.20-reasoning (grok-4.5 unavailable)`), a stderr
  note, and the synthesis. `grok-4.5`, for example, is not currently served in
  the EU. The verdict is cached for a day (`COUNCIL_AVAILABILITY_TTL`,
  seconds, `0` to re-check every query) so the unavailable model isn't
  retried on every call, and the council returns to the default automatically
  once it becomes available. An explicit `<PROVIDER>_MODEL` opts a provider
  out of the fallback.
- **Image input for Grok and Perplexity.** grok-4.x and Perplexity sonar
  models now receive images over their OpenAI-compatible `/chat/completions`
  endpoints, alongside the existing Gemini and OpenAI vision routing. The
  text-only path is unchanged, and Perplexity's `search_recency_filter` /
  `return_citations` are preserved on the image path.

### Fixed

- **xAI errors reported their HTTP code instead of their reason.** xAI returns
  `.error` as a bare string rather than an object. `.error.message` on a string
  raises a jq error rather than yielding null, and `//` does not catch a raise —
  so the existing check read every xAI failure as "no usable message" and
  replaced the body, printing `Error from Grok: HTTP 403` instead of *"The
  model grok-4.5 is not available in your region."*
- **Any OpenAI API error crashed the provider script instead of reporting it.**
  On the `/v1/responses` path — which the default model `gpt-5.6-sol` uses —
  the text extraction iterated `.output[]` over an error body that has no
  `.output` key. jq exits 5, and under `set -euo pipefail` the command
  substitution aborted the script before its error-handling block ever ran.
  Users saw a raw jq diagnostic and exit 5 instead of a reported error.
- **The Stop hook wedged the session when the plugin path contained a space.**
  An unquoted `${CLAUDE_PLUGIN_ROOT}` word-split (common on Windows,
  `C:\Users\First Last\...`), so bash ran the split-off prefix as a script —
  exit 127, or a syntax error and exit 2 that Claude Code reads as "block the
  stop", a loop that survived disabling the plugin. Quoting the expansion
  passes the path as a single argument. (Fixes #11.)

### Changed

- **Default models bumped to current flagships:** OpenAI `gpt-5.6-sol`,
  Grok `grok-4.5`.

## 2026.7.4

No user-facing behavior changes. This release makes the shell linter tell the
truth, then lets it block a merge.

### Fixed

- **`set -e` can see a failing command again in three places.** `local x=$(cmd)`
  discards the command's exit status, because `local` is itself a command and its
  success becomes the line's. A failing `dirname` when exporting, and a failing
  `provider_color` or `provider_emoji` when formatting the provider list, passed
  silently.

### Other

- **shellcheck reported 58 findings and was configured never to fail.**
  `continue-on-error: true` kept the run green while the check stayed red, so
  every commit on main carried a red mark, both releases included. It reports
  none now, and a finding blocks a merge.
- **Thirty-four of those came from one blind spot.** Every script reaches its
  libraries through `source "$SCRIPT_DIR/lib/x.sh"`, a path shellcheck cannot
  resolve, so it never opened the sourced files and called every shared
  definition unused. A `.shellcheckrc` resolves them at the root.
- **The lint target names every tracked script** rather than three globs, which
  had silently skipped two files and would have skipped any script in a
  directory added later.
- **shellcheck is pinned by digest**, and its download retries into a file rather
  than a pipe, since curl restarts a transfer from byte zero and cannot unwrite
  what it already emitted. A linter ships new checks in every release, so an
  unpinned one blocking a merge reddens main on a commit nobody touched.
- **`available` named three different things**: an array of discovered providers,
  a padded set string, and a provider counter. Each now names what it holds.
- **A pane-watcher script global is gone.** The banner was built into a variable
  through an out-param, then printed once and dropped. It prints directly now.

### Docs

- `TESTING.md` gains a lint section: how to run it, and when suppressing a
  finding is legitimate.
- `docs/ARCHITECTURE.md` lists `.shellcheckrc`, `.github/workflows/tests.yml`,
  and `CHANGELOG.md` in the file tree.

## 2026.7.3

Three bugs made `/status` misreport provider health, including one that told users
to revoke a working API key.

### Fixed

- **A typo'd model name no longer reads as a rejected API key.** Neither Gemini's
  `INVALID_ARGUMENT` status nor xAI's `invalid-argument` code names the key: both
  are the vendor's marker for their whole 400 class, an unusable model name
  included. A capitalised `GEMINI_MODEL` reported `Auth failed (HTTP 400)` with
  the remediation `key rejected - regenerate it`, so the user revoked a good key
  and the symptom survived. Each check now reads the field that names the key,
  Gemini's `details[].reason` and xAI's error text.
- **A rejected key is reported even when the vendor answers 400.** Gemini and xAI
  answer `400` rather than `401`, so half the providers rendered a bad key as a
  generic error carrying no remediation.
- **Perplexity is no longer reported as broken when it is fine.** The probe asked
  for `max_tokens: 1`, under that API's floor of 16, so the API answered 400 to
  our own request and every valid Perplexity key read as `Error (HTTP 400)`.
- **Connection failures no longer render as `Error (HTTP 000000)`.** curl reports
  a failed transfer as `000` and also exits non-zero; the guard that kept `set -e`
  from aborting appended a second `000`. A body that stalled after a `200` header
  produced `Error (HTTP 200000)`.
- **A missing `jq` is reported rather than silently misdiagnosed.** Every `jq`
  failure looked like "not a rejected key", so a genuinely rejected key reported
  as an ordinary 400: a wrong answer rather than a missing one.

### Security

- **The OpenAI and Perplexity probes no longer write a response body to disk.**
  Nothing reads it, and OpenAI's error body echoes a partially redacted copy of
  the key.

### Changed

- Mutation testing drove these fixes: of ten defects injected into
  `check-status.sh`, eight survived the suite. All ten now fail it. Coverage added
  for 403, for 401 and 403 reaching every provider rather than one, for curl
  writing nothing, for `-X POST` and `--max-time`, for temp-file cleanup, and a
  cost bound on the billable Perplexity probe. 354 tests to 367.
- The zombie-reaping test obtains a dead pid from a child that exits at once,
  rather than backgrounding a 30-second sleep that could outlive the test and
  hold its output stream, which intermittently failed the macOS runner.

## 2026.7.2

Screenshot/image input for the council, plus a full security & correctness audit
(67 findings) and continuous integration.

### Added

- **Screenshot / image input (`--image=path`).** Attach one image
  (png/jpg/jpeg/webp/gif, ≤10 MB) to a council query. Gemini and OpenAI analyze
  it natively; CLI providers route to their vision-capable API sibling
  (codex→openai, antigravity→gemini); Grok and Perplexity answer text-only,
  tagged `(answered without the image)`. The image bytes never touch cache
  entries or saved `council-*.md` transcripts — only a hash keys the cache.
- **Continuous integration.** GitHub Actions runs the bats suite on Ubuntu and
  macOS; releases are gated on a green suite and refuse to run with a pre-staged
  index.

### Fixed

Security and correctness hardening from a full audit (67 findings):

- **Secrets off the process argv** — API keys reach `curl` via a mode-600
  `--config` file, never the command line or a URL query string (Gemini uses the
  `x-goog-api-key` header).
- **Large prompts no longer fail** — provider prompts and payloads travel via
  files rather than argv, fixing "argument list too long" on big `--file` inputs.
- **Cache hardening** — portable SHA-256; keys that account for verbosity, token
  cap, and any attached image; a self-ignoring cache dir; safe handling of empty
  or corrupt entries.
- **No silent failures** — `curl_with_retry` always returns a structured error
  body; council failures surface, and zombie async jobs are reaped to `failed`.
- **Display & terminal** — millisecond-correct timing, revived OSC-11 theme
  detection on bash 3.2, control-byte scrubbing before render, hardened tmux pane
  manifest writes.
- **Provider robustness** — CLI providers bounded by `COUNCIL_TIMEOUT`, codex
  pinned to a read-only sandbox, a near-free Perplexity status probe.

### Docs

- Corrected documentation drift (cache-key formula, file trees, model defaults),
  documented the vision feature in the architecture and testing guides, added
  privacy/cost notes, and removed a phantom config block and an unsupported
  install command from the README.

### Changed

- Extracted the perl / Rich renderers and the pane watcher from inline heredocs
  into standalone files; untracked session state; localized git attributes.

## 2026.7.1

Rich markdown rendering in the streaming tmux pane, with the perl renderer as
the zero-install fallback.

### Added

- **Rich markdown rendering in the streaming tmux pane.** When a Rich-capable
  Python is available (`python3` with a modern `rich`, or `uv`, which fetches
  it on demand), responses render through a council-tuned
  [Rich](https://github.com/Textualize/rich) renderer: word-wrapped prose,
  tables fitted to the pane width, syntax-highlighted code and reasoning
  blocks styled with the terminal's own palette, and clickable OSC 8 links.
  Without one, the built-in perl renderer runs unchanged — the plugin stays
  zero-install. `COUNCIL_RENDERER=perl` forces the perl path.
- Selection hardening: uv runs isolated from the cwd's Python project
  (`--no-project`, `--offline` at render time), the pane-open probe is
  bounded (`COUNCIL_RICH_PROBE_TIMEOUT`, default 10s), pre-13 Rich installs
  are rejected by feature detection, and any runtime render failure falls
  back to perl so the pane never goes blank.

### Docs

- Corrected stale `codex` / `gemini` CLI references to `agy` (Antigravity)
  in README — the gemini CLI was replaced in v2026.6.7.
- Documented renderer selection, `COUNCIL_RENDERER`, and
  `COUNCIL_RICH_PROBE_TIMEOUT`; Requirements lists the optional Rich
  dependency. Test suite 256 → 270.

## 2026.6.9

Fixes a Windows/MSYS bug where large provider responses were silently dropped.

### Fixed

- **Windows/MSYS: provider responses silently dropped at `standard`/`detailed`
  verbosity.** On MSYS, `ARG_MAX` is ~32 KB, but the council built its final
  JSON by passing the combined provider responses to `jq` on the command line —
  so once they exceeded ~32 KB, `jq` aborted with "Argument list too long" and
  the script emitted nothing. All large data (responses, the metadata prompt,
  the per-round accumulators) now reaches `jq` via stdin, which isn't bounded by
  `ARG_MAX`. Linux/macOS were never affected (`ARG_MAX` ~2 MB). Thanks to
  @GmailTedam (Dr Josh Tedam) for the report and original fix (#5).

### Changed

- Consolidated the jq marshalling onto one stdin-based path — a `merge_result`
  helper for the result accumulators plus `jq -s`/`jq -Rs` for the metadata and
  final build — replacing the temp files the initial fix used (byte-identical
  output on every platform).
- Added `tests/argmax.bats` (3 tests): large round-1 response, large prompt, and
  large debate-round-2 response each round-trip through the final JSON intact.
  Suite 253 → 256.

### Docs

- Listed the new `tests/argmax.bats` coverage in `TESTING.md` and
  `docs/ARCHITECTURE.md`.

## 2026.6.8

Makes the streaming pane's muted text readable on light/cream backgrounds.

### Fixed

- **Light-background pane contrast** — the pane's *muted* text (link URLs, table
  grid lines, `---` rules, sub-headings, and the "waiting on" label) now adapts
  to the terminal theme the way bold/italic emphasis already did. On light/cream
  backgrounds these render as a readable dark gray instead of the faint
  (`2`)/bright-black (`90`) codes that washed out; dark themes are unchanged.
  Force with `COUNCIL_THEME=light`.

### Changed

- Docs (README, ARCHITECTURE, TESTING) updated to describe theme adaptation
  covering muted text, not just emphasis.
- Gated the real-`agy` CLI end-to-end test behind `COUNCIL_E2E=1` (matching the
  codex E2E) so the default suite no longer makes a live model call or depends
  on its exact wording.
- Simplified the muted-SGR construction in the waiting-list renderer
  (byte-identical output).

## 2026.6.7

Replaces the Gemini CLI provider with Google's Antigravity CLI and adds an
automatic CLI→API fallback.

### Added

- **`antigravity` provider** — drives Google's Antigravity CLI (`agy`) in print
  mode as the Gemini-vendor subscription-CLI provider, gated on the `agy` binary
  being on `PATH`. Default model `Gemini 3.5 Flash (High)` (override via
  `ANTIGRAVITY_MODEL`). A tool-suppression prompt guard keeps the agentic CLI
  answering inline as plain text instead of writing report artifacts to disk.
- **CLI→API fallback** — when a CLI provider fails at query time and its API
  sibling's key is set, the council automatically retries through that sibling
  (in both the initial and debate rounds), showing the answer in the same slot
  with the API model's name and a "fell back to … API" note. The fallback is
  skipped when the sibling is already a selected provider (so you never get the
  same vendor's answer twice), reuses a cached sibling answer instead of
  re-billing the API on a repeat, and also rescues a missing/non-executable
  provider script.

### Removed

- **`gemini-cli` provider** — removed entirely (no compatibility alias);
  `antigravity` supersedes it as the Gemini-vendor CLI.

### Changed

- `shadow_origin` and `api_sibling` now derive from a single `SHADOW_PAIRS`
  source list so the API↔CLI pairing can't drift between them; `api_key_present`
  gates generically on the `<NAME>_API_KEY` convention.
- Docs (README, ARCHITECTURE, TESTING) updated for the new provider and the
  fallback behavior.

## 2026.6.6

Streaming-pane fix: the waiting-list spinner no longer waterfalls.

### Fixed

- **The "council is waiting on …" spinner no longer prints a new line every
  frame.** Whenever the waiting line was wider than the pane it wrapped, and the
  carriage-return redraw (`\r\033[K`) could only reclaim the last physical row —
  leaving one stale row per animation frame (a waterfall). The line now disables
  autowrap (DECAWM) so it clips at the right margin instead of wrapping, and the
  provider list is truncated to fit the pane width with a `…` overflow. Live pane
  width comes from `stty size` (the pane tty's winsize); `tput cols` returns the
  static terminfo default in a non-interactive pane process, not the real width.

## 2026.6.5

Correctness fix for the local council shipped in 2026.6.4.

### Fixed

- **The local council no longer hijacks queries when real providers are
  available.** 2026.6.4 shipped council members as a standalone `council-member`
  agent type; because a registered agent is directly spawnable by the model,
  asking to "use the council" could spawn a local Claude-only council directly —
  bypassing provider detection, so real providers (Gemini/OpenAI/…) were skipped
  even when configured. The agent type is removed; the local council now runs
  **only** through its gated path — when no providers are configured, when the
  user accepts the offer, or with explicit `--local` — and a skill-level guard
  enforces this even if the skill is reached directly. Local members are now
  `general-purpose` subagents (matching `--agents` mode).

## 2026.6.4

A local Claude-only council for users without provider keys, plus collection-loop
and gemini-CLI robustness fixes.

### Added

- **Local council (`--local`).** Convene a council using Claude alone when no
  provider keys or CLIs are configured. Spawns N independent subagents — each a
  different role from `config/roles.json`, blind to the others — and synthesizes
  them. When a query finds no providers, the command now *offers* a local council
  instead of erroring. You choose how many members to convene (default 4, up to
  8); `--roles` still selects specific lenses. Output is explicitly framed as
  same-model *angles and blind-spot coverage*, not cross-vendor consensus.

### Fixed

- **One bad provider no longer crashes the whole run.** The result-collection
  loops fed raw provider output straight to `jq --argjson`; a single non-JSON
  result aborted the entire council under `set -e`. Output is now coerced into a
  structured error via `coerce_result_json`, so every other provider's result
  survives.

- **`gemini-cli` only passes `--skip-trust` when the installed CLI advertises
  it.** Newer Gemini builds dropped the flag, so headless mode aborted with
  `Unknown argument: skip-trust`. It is now probed via `--help` before use.
  (Thanks @Deal-Phoenix.)

### Changed

- **Manual-install docs corrected.** Don't clone into `~/.claude/plugins/` (the
  managed install cache, never scanned for manual plugins); `pluginDirectories`
  is not a real settings key. Documented the per-session `--plugin-dir` path and
  the two traps. Refreshed test counts and the token-table standard-model example.

## 2026.6.3

Streaming-pane robustness fixes for the tty probe and light-terminal rendering.

### Fixed

- **Streaming pane no longer leaks a `/dev/tty` error.** The tty-writability
  probe silenced stderr *after* the failing redirect, so headless runs printed
  a stray `query-council.sh: line 407: /dev/tty: Device not configured`.
  Extracted into `council_probe_tty()` with stderr silenced first.

- **Light-theme contrast.** Bold/italic were rendered invisible bright-white on
  light terminals because `COLORFGBG` goes stale (reports `15;0` "dark" on a
  light terminal). `council_detect_theme` now trusts `COLORFGBG` only to assert
  *light*; anything ambiguous falls back to attribute-only emphasis that
  inherits the real foreground — readable on any theme.

- **`COUNCIL_THEME` no longer clobbered when forwarding to the pane.**
  `display_pane_open` passed `-e COUNCIL_THEME=` unconditionally, overwriting a
  theme the pane could otherwise inherit or auto-detect with an empty value. It
  is now forwarded only when set.

### Changed

- Documentation: corrected `display.bats` (17→21) and `agent-analysis.bats`
  (9→11) test counts; tightened the `COUNCIL_THEME` description in
  `ARCHITECTURE.md`.

## 2026.6.2

Patterns adopted from an analysis of openai/codex-plugin-cc, adapted to
claude-council's bash architecture.

### Added

- **Background jobs (`--async`).** `run-council.sh --async` detaches the
  query as a tracked job (json + log per job in a workspace-hashed state dir
  under `$CLAUDE_PLUGIN_DATA`) and returns a job id immediately.
  `--result=<id>` returns the outfile path (exit 2 while in flight),
  `--jobs` lists, `--cancel=<id>` terminates the worker process tree. New
  `/claude-council:result` command fetches, lists, and cancels;
  `/claude-council:status` now lists jobs.

- **Opt-in stop-gate review hook (off by default).** A `Stop` hook asks one
  council provider to review the uncommitted diff and blocks the stop only
  on a first-line `BLOCK:` verdict. Enabled per project via
  `.claude/council-stop-gate.json`; guarded by a `stop_hook_active` check
  and a per-session block cap, and any reviewer failure allows the stop.

- **Enforced agent-mode output contract.** Deep-execution agents now return
  JSON matching `schemas/agent-analysis.schema.json`;
  `scripts/validate-analysis.sh` checks every field and invalid replies are
  rendered raw under a visible marker instead of silently accepted.

- **Prompt templates.** `prompts/*.md` with `{{VAR}}` slots filled by
  `scripts/lib/prompts.sh`; role injection and the synthesis instructions
  (now with calibration rules) moved out of heredocs and skill prose.

- **Hermetic CLI test fixture.** Fake `codex`/`gemini` binaries on `PATH`
  (behavior via `COUNCIL_FAKE_BEHAVIOR`, invocations recorded as JSONL) let
  provider scripts, async jobs, and the stop gate run end-to-end in bats
  with no network. Suite grew from 132 to 196 tests.

### Changed

- **Malformed provider output is preserved, never dropped.**
  `format-output.sh` marks empty responses (`[empty response]`) and prints
  off-shape entries raw in a fenced block (`[unparseable response]`); a
  missing `round1` no longer crashes the formatter.

- **Provider status is two-tier with fix commands.** `check-status.sh`
  distinguishes installed-but-unauthenticated codex (via `codex login
  status`) from available, and every failure state prints the exact
  remediation (`export KEY=...`, `codex login`, install command).

### Fixes

- **`check-status.sh` died before its summary line.** `((available++))`
  under `set -e` aborted the script as soon as any provider was available;
  the summary now always prints.

- **Perplexity status probe rejected by the API.** Perplexity now requires
  `max_tokens >= 16` for sonar; the probe sent 1 and read as HTTP 400.

- **Pane text was invisible on light terminal themes.** The waiting-list
  provider colors are now mid-tone shades, and the markdown renderer's
  bold/italic emphasis adapts to the detected terminal theme (OSC 11
  background query in the pane, `COLORFGBG` fallback, attribute-only when
  unknown; force with `COUNCIL_THEME=light|dark`).

- **Closing the streaming pane early failed the query.** `display_pane_close`
  returned 1 once the watcher had cleaned up its watch dir, and as the last
  command under `set -e` that became query-council's exit code, making
  run-council swallow the outfile path. The function now treats a missing
  watch dir as already closed.

### Other

- Simplify pass: memoized job-state resolution, single-jq JSON reads in the
  stop gate and job commands, theme forwarded via `tmux -e` instead of a
  file, shared `unset_provider_keys`/`assert_blank` test helpers, and the
  validator now enforces the schema's 1-5 recommendation bound.

## 2026.6.1

### Fixes

- **`grok-build` models now get the reasoning token bump.** `grok-build-*`
  (e.g. `grok-build-0.1`) is a reasoning model that was missing from Grok's
  token-bump list, so responses were capped at the 2048 default and truncated
  long answers mid-sentence. It now gets the 32768 cap. xAI caps `max_tokens`
  on grok-build's *visible* output only (internal thinking is uncapped), so the
  bump guards against long answers being cut off.

- **Perplexity reasoning models now get the token bump.** `sonar-reasoning*`
  and `*deep-research*` were documented and unit-tested as bump-eligible, but
  the logic was never wired into `perplexity.sh` — so the default
  `sonar-reasoning-pro` stayed capped at 2048, risking truncation of its visible
  `<think>` chain-of-thought. The bump is now applied (verified live: default
  model sends `max_tokens=32768` with search and citations intact).

### Docs

- Corrected a stale README claim that Gemini and Grok "use the base limit
  directly" — both apply the bump (Gemini combines reasoning+output; Grok caps
  visible output only).
- Fixed the `tokens.bats` test count in TESTING.md (8 → 9).

## 2026.5.3

### Fixes

- **Bash 3.2 silent corruption fixed.** Three sites used `declare -A`
  (associative arrays, bash 4+) which crashed on macOS system bash 3.2
  (`/bin/bash`). Worse than a clean error: bash 3.2 evaluates string
  subscripts arithmetically on unset names, collapsing every key to
  index 0 and silently corrupting membership lookups. Concrete user-
  visible bug: a user with only `OPENAI_API_KEY` configured (no codex
  CLI) had openai silently dropped from every council query because
  `prefer_cli_over_api` thought every provider's CLI shadow was already
  present. Affected: `prefer_cli_over_api`, `--list-available`, the
  watcher.sh streaming-pane state map.

- **codex CLI: bypass trusted-directory guard.** Pass
  `--skip-git-repo-check` to `codex exec` so the council can run from
  any cwd. The guard exists for interactive coding sessions that may
  edit files; our headless exec only reads stdout. Mirrors the existing
  `--skip-trust` flag in gemini-cli.sh.

- **Default request timeout raised: 120s → 300s.** Reasoning models
  (gpt-5.5-pro, grok-4.20-reasoning, sonar-reasoning-pro) routinely
  exceeded 120s on hard architectural questions, surfacing as confusing
  timeouts. The deep-execution per-agent override is also raised
  (240s → 500s).

### Other

- Internal: `display.sh` watcher's per-provider state moved from three
  associative arrays to parallel arrays + `provider_index` helper using
  the `printf -v` out-variable idiom (matches existing
  `provider_color_rgb` pattern). No behavior change.

## 2026.5.2

### Features

- **`--list-default` flag** for `query-council.sh` — returns the providers
  that would actually run for a default query (post CLI-prefers-API filter).
  The slash command (`/ask`) now uses it to size its provider-selection
  AskUserQuestion correctly: with both API keys and CLIs configured, it shows
  4 options (the queryable set) instead of 6 (the full discovered set).

- **`--list-available` is now human-readable**: multi-line output with the
  default query set and a "Shadowed by CLI policy" section that names which
  CLI is preferred. Use `--list-default` for tooling.

### Docs

- **README restructured** for marketplace readers. Quick start (install +
  example query + sample output) now leads, followed by Usage above
  Configuration, with deep config (model selection, reasoning models,
  Perplexity recency, retry/timeout, terminal integration) consolidated
  under a new "Reference" section. Added a small ToC after the tagline.

### Other

- New `shadow_origin` helper in `lib/providers.sh` — single source of truth
  for the API↔CLI shadow pairs (codex⇄openai, gemini-cli⇄gemini). Both
  `prefer_cli_over_api` and the `--list-available` display annotation now
  use it. Adding a future pair is a one-line change instead of three.
- New `default_provider_set` helper — collapses the
  `discover_providers | prefer_cli_over_api` chain that appeared at three
  call sites into a single function call.
- Two new tests (`cli-providers.bats` is now 18, up from 16) covering
  `--list-available`'s shadow annotation and `--list-default`'s
  machine-readable contract.

## 2026.5.1

### Features

- **Codex and gemini CLI providers.** `codex` and `gemini` CLIs are now
  first-class council members alongside the existing API providers,
  discovered automatically when their binaries are on `PATH`. They use
  your existing CLI subscription auth — no API key, no per-call cost.

  When both an API and a CLI sibling are configured, the council prefers
  the CLI by default: `codex` shadows `openai`, `gemini-cli` shadows
  `gemini`. Explicit `--providers=openai` (or `gemini`) bypasses the
  policy. Listing both in `--providers=gemini,gemini-cli` runs them
  side-by-side for direct comparison.

  Vendor-grouped colors and emojis: codex shares OpenAI's white square
  (🔳), gemini-cli shares Gemini's blue square (🟦) — across both the
  rendered output and the streaming tmux pane. Real model names
  (`gpt-5.5`, `gemini-3-flash-preview`) flow through to pane headers and
  JSON metadata via constants matching the CLIs' own current defaults.

### Fixes

- **`discover_providers` portability.** Replaced bash 4+ `${name^^}`
  with portable `tr` so the script's fallback case runs cleanly under
  `/bin/bash` 3.2 (macOS system bash). Was a latent crash for users
  whose only configured provider was perplexity.

- **`query-council.bats` setup leak.** Now also unsets `XAI_API_KEY`,
  which was silently aliased to `GROK_API_KEY` via `keys.sh`'s
  `resolve_grok_key`. On developer machines with `XAI_API_KEY` set, grok
  was sneaking through "no providers" tests.

- **`display.bats: should_open_pane is true inside tmux by default`**
  now unsets the global `COUNCIL_NO_PANE=1` test guard before exercising
  the default code path. Test was contradicting itself silently.

### Docs

- README: new "CLI Providers (subscription auth, no API key)" section
  with the prefer-CLI policy and override examples.
- ARCHITECTURE.md: file structure and tests trees include the new
  providers, lib, and bats file; query box updated to show 6 providers;
  config table adds `CODEX_MODEL` and `GEMINI_CLI_MODEL`.
- TESTING.md: test coverage table includes `cli-providers.bats` (16),
  refreshed counts for `query-council.bats` (18) and `verbosity.bats`
  (9). New "CLI Providers" feature test scenario added.
- `plugin.json` description and keywords now mention codex / cli.

### Other

- New `scripts/lib/providers.sh` is the single source of truth for
  everything keyed on provider name: discovery, the CLI-prefers-API
  policy, `get_model` defaults, and the vendor `provider_color` /
  `provider_emoji` helpers. Previously these were duplicated across
  `query-council.sh`, `format-output.sh`, and `check-status.sh`.
- `check-status.sh` adds a `check_cli_provider` for binary-presence +
  `--version` health probes, and now uses the consolidated emoji/color
  helpers instead of hardcoded literals.
- `tests/cli-providers.bats` — 16 tests covering CLI discovery, the
  CLI-prefers-API policy, flag parsing, plus 2 gated end-to-end tests
  behind `COUNCIL_E2E=1`.

## 2026.4.5

### Features

- **Verbosity controls** — new `COUNCIL_VERBOSITY` env var and `--verbosity`
  flag let you shape provider responses by style and depth, not just length:
  - `brief` — 3-5 sentences max, bullets where possible, no code unless asked
  - `standard` — current default, balanced thoroughness (no directive prepended)
  - `detailed` — thorough analysis with code examples, edge cases, trade-offs

  The `/ask` slash command now combines provider selection and verbosity into
  a single AskUserQuestion screen so both decisions resolve in one prompt.
  Standard is the recommended default; the question is skipped when
  `--verbosity` is passed explicitly.

### Other

- New `scripts/lib/verbosity.sh` houses both the verbosity directive helper
  AND a `BASE_SYSTEM_PROMPT` constant shared by all four providers. The base
  prompt was previously duplicated 5× across provider scripts. One source of
  truth now — future prompt-engineering changes touch one location instead
  of five. Perplexity continues to append its citation clause inline.
- `validate_verbosity` helper extracted to verbosity.sh, mirroring the
  existing `validate_roles` pattern.
- All providers now follow a consistent "compute verbosity prefix once at
  startup, reuse in SYSTEM=" pattern.
- `tests/verbosity.bats` — 9 tests covering directive content, fallback,
  validation, and base-prompt presence.

### Docs

- README: new "Verbosity" section with the level → output mapping.
- ARCHITECTURE.md: `verbosity.sh` in lib tree, `verbosity.bats` in tests
  tree, `COUNCIL_VERBOSITY` in config table.
- TESTING.md: `verbosity.bats` row.
- `commands/ask.md`: spec includes the verbosity AskUserQuestion step.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.4.4...v2026.4.5

## 2026.4.4

### Fixes

- **Reasoning-model response truncation** — Gemini 3.x, Grok 4.x reasoning,
  and Perplexity sonar-reasoning models share `maxOutputTokens` between
  internal "thinking" and visible output. With the 2048 default, the model
  could burn most of the budget on chain-of-thought before emitting the
  response, then run out mid-sentence (silently — the API returns success).
  All three providers now auto-bump to `max(base * 8, 32768)` for known
  reasoning model patterns, mirroring OpenAI's existing logic. Extracted
  the bump into a shared `scripts/lib/tokens.sh` helper.
- **Bats tests no longer spawn orphan tmux panes** — `query-council.bats`
  invokes `query-council.sh` with fake API keys to test argument parsing.
  Each invocation called `display_pane_open` before the auth check failed,
  leaving an open pane waiting for keypress. Across a full run, ~10 panes
  per invocation accumulated. Tests now set `COUNCIL_NO_PANE=1` and
  `COUNCIL_AUTO_CLOSE=1` in the bats helper.

### Other

- New `COUNCIL_AUTO_CLOSE` env var: when `=1`, the streaming pane skips
  the keypress wait and exits when the watcher's `.done` sentinel arrives.
  Used by `scripts/dev/demo-pane.sh` and the test helper. Interactive
  `/ask` runs are unaffected (default keeps the keypress wait so users
  can scroll back through responses).
- New `tests/tokens.bats` (8 tests) covering the reasoning-model bump
  helper.
- `/ask` slash command spec now puts "All providers (Recommended)" as
  the first option in provider selection — matches the project's general
  preference for select-all defaults in multi-select prompts.
- Untrack `.claude/settings.local.json` (per-developer config; mirrors
  the existing `.claude/*.local.md` rule). History rewritten via
  `git filter-repo` to remove this file from prior commits, so all
  post-v2026.4.3 commit hashes have changed (release tags were re-pointed
  and remain valid).

### Docs

- README: generalize the reasoning-model token bump description from
  OpenAI-specific to all four providers with their model patterns.
- ARCHITECTURE.md: document `COUNCIL_AUTO_CLOSE` env var, add `tokens.sh`
  to the lib tree, add `tokens.bats` to the tests tree.
- TESTING.md: add `tokens.bats` row to the test coverage table.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.4.3...v2026.4.4

## 2026.4.3

### Features

- **Streaming tmux pane** — when running `/ask` inside tmux, council opens a side pane
  that streams each provider's response as it lands. Each provider gets a colored
  banner (blue/white/red/green for gemini/openai/grok/perplexity) with the model
  name and `(timing)` inline. Disable per-call with `--no-pane` or globally via
  `COUNCIL_NO_PANE=1`.
- **iTerm2 lifecycle integration** — when the outer terminal is iTerm2, council
  drives tab color (yellow → green/red), dock attention bounce on slow queries
  (gated by `COUNCIL_ATTENTION_THRESHOLD`, default 2000 ms), and OSC 1337 SetMark
  before each response so Cmd+Shift+↑/↓ navigates between providers.
- **In-house markdown renderer** — fast perl-based renderer that handles
  headings (H1–H6), bold/italic/strikethrough, inline + fenced code, bullets and
  nested bullets, numbered lists, blockquotes, links, horizontal rules, borderless
  tables with column alignment, and `<think>...</think>` reasoning blocks
  (rendered as a dim italic sidebar with line wrapping).
- **Multi-line error rendering** — providers that fail show their full error
  message in the pane (indented dim red) instead of a bare "error" label.

### Other

- New `scripts/lib/display.sh` and `scripts/dev/demo-pane.sh` (visual test harness).
- New `tests/display.bats` (17 tests for detection, wrappers, manifest writes).
- `CHANGELOG.md` introduced; release flow now maintains it per release.
- `scripts/release.sh` resets the `BUILD` counter when the month rolls over.
- `provider_color_rgb` uses `printf -v` instead of subshells (~1000 fewer forks
  per query); status-line parsing replaces 4× `cut|echo` with a single `read`.

### Docs

- README documents `--no-pane`, `COUNCIL_NO_PANE`, `COUNCIL_ATTENTION_THRESHOLD`,
  and Display & Terminal Integration section.
- ARCHITECTURE.md updated for new files in scripts/lib and tests trees.
- TESTING.md now lists `keys.bats` and `display.bats`.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.4.2...v2026.4.3

## 2026.4.2

### Features

- **`XAI_API_KEY` support** — recognize xAI's canonical env var name for Grok credentials.
  `GROK_API_KEY` continues to work as a legacy alias; `XAI_API_KEY` wins when both are set.
- New `scripts/lib/keys.sh` shared helper resolves the env var at each entry point.
- New `tests/keys.bats` covering precedence, fallback, and silent-conflict policy.

### Other

- Untrack `.cs/` and `.claude-crawl/` (per-machine state, not shared artifacts).
- Remove `AGENTS.md` (referenced an unused `bd` workflow).
- History rewritten via `git filter-repo` to remove the above paths from prior commits.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.4.1...v2026.4.2

## 2026.4.1

### Other

- Documentation updates for release.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.4.0...v2026.4.1

## 2026.4.0

### Features

- Upgrade default OpenAI model to `gpt-5.5-pro` and Grok model to `grok-4.20-reasoning`.

### Fixes

- Fix stale model defaults and documentation inaccuracies.

**Full Changelog**: https://github.com/hex/claude-council/compare/v2026.3.4...v2026.4.0
