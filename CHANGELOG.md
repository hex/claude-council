# Changelog

All notable changes to claude-council are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to a `YYYY.M.BUILD` versioning scheme where `BUILD` resets each month.

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
