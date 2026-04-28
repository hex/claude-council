# Changelog

All notable changes to claude-council are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to a `YYYY.M.BUILD` versioning scheme where `BUILD` resets each month.

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
