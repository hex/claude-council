# Changelog

All notable changes to claude-council are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to a `YYYY.M.BUILD` versioning scheme where `BUILD` resets each month.

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
