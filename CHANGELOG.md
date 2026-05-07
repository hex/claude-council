# Changelog

All notable changes to claude-council are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to a `YYYY.M.BUILD` versioning scheme where `BUILD` resets each month.

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
