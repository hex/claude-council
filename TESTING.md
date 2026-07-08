# Testing Guide

Automated and manual testing procedures for claude-council features.

## Automated Tests (bats)

Unit tests using the [bats](https://github.com/bats-core/bats-core) framework.

### Installation

```bash
# macOS
brew install bats-core

# Ubuntu/Debian
sudo apt install bats

# Manual (any platform)
git clone https://github.com/bats-core/bats-core.git
cd bats-core
./install.sh /usr/local
```

### Running Tests

```bash
# Run all tests
./tests/run_tests.sh

# Run specific test file
bats tests/cache.bats
bats tests/roles.bats
bats tests/query-council.bats

# Verbose output
bats --verbose-run tests/cache.bats
```

### Test Coverage

| File | Tests | Coverage |
|------|-------|----------|
| `cache.bats` | 26 tests | cache_key (incl. verbosity/token/image components), cache_get/set, cache_valid, TTL, clear, self-ignoring dir |
| `cli-providers.bats` | 38 tests | codex/antigravity discovery, CLI-prefers-API policy, shadow_origin↔api_sibling single source, --list-available / --list-default, flag parsing, coerce_result_json JSON guard, CLI→API fallback (dedup, cache reuse, missing-script, round 2), gated E2E |
| `display.bats` | 43 tests | tmux/iTerm2 detection, wrapper no-op behavior, manifest writes, pane gating, tty probe, pane env forwarding, waiting-line truncation + autowrap guard, renderer selection (Rich feature probe, uv route + timeout, perl fallback, COUNCIL_RENDERER=perl, runtime fallback + stdout forwarding, think-block styling incl. unclosed tags, code-theme direction, link style, COLUMNS=0) |
| `keys.bats` | 7 tests | XAI_API_KEY ↔ GROK_API_KEY resolution, precedence, silent-conflict policy |
| `roles.bats` | 47 tests | presets, validation, prompt injection, assignment, local-council role resolution + member count |
| `tokens.bats` | 9 tests | reasoning-model token-cap bumping, glob patterns, floor, multi-pattern |
| `verbosity.bats` | 9 tests | brief/standard/detailed directives, fallback to standard |
| `query-council.bats` | 19 tests | argument parsing, error cases, flags, local-council fallback hint |
| `argmax.bats` | 4 tests | large response/prompt/debate-round-2 round-trip through final JSON (MSYS ARG_MAX marshalling guard) |
| `fake-clis.bats` | 14 tests | fixture self-checks, codex.sh/antigravity.sh against fake binaries |
| `format-output.bats` | 11 tests | defensive parsing: empty/missing/non-string responses, raw preservation, fallback-note rendering |
| `prompts.bats` | 11 tests | template loading, {{VAR}} interpolation, role-injection rendering |
| `agent-analysis.bats` | 11 tests | validate-analysis.sh contract enforcement, schema sync |
| `check-status.bats` | 25 tests | two-tier CLI availability, remediation strings, HTTP probe branches (401/403/500/000), rejected-key classification (Gemini/xAI answer a bad key with 400, not 401) and its false-positive guards (a typo'd model is not a bad key), transfer-failure exit codes, curl writing nothing, unusable jq, Perplexity's minimum max_tokens, `-X POST` and `--max-time` on every probe, temp-file cleanup, keys off the curl argv, ms clock |
| `jobs.bats` | 16 tests | job store, --async lifecycle, --result/--jobs/--cancel, self-ignoring cache dir |
| `stop-gate.bats` | 10 tests | opt-in gating, loop guards, BLOCK verdict, fail-open |
| `theme.bats` | 24 tests | terminal theme detection, theme-aware emphasis + muted-text (faint/gray) rendering |
| `providers.bats` | 16 tests | API provider payloads, response parsing, endpoint routing, secret/payload hygiene, vision image injection (gemini inlineData, openai input_image/image_url) |
| `image.bats` | 8 tests | --image validation (missing/bad-type/oversize), vision routing, CLI→sibling routing, non-vision text-only tag, base64 never in the cache |
| `pane-watcher.bats` | 3 tests | standalone pane watcher: banner + response render, error notice, SetMark, watch-dir cleanup |
| `export.bats` | 5 tests | markdown transcript export writing + formatting |
| `release.bats` | 5 tests | release.sh version bump/commit/tag, staged-index guard, green-suite gate |
| `retry.bats` | 6 tests | curl_with_retry backoff + status handling, curl_secret_config off-argv config file |

**Total: 367 tests** across 23 `.bats` files.

### Hermetic CLI Fixture

`tests/fixtures/fake-clis.bash` installs real fake `codex`/`agy`
executables into a temp dir prepended to `PATH`, so provider scripts, async
jobs, and the stop gate run end-to-end with no network or real CLIs:

```bash
load fixtures/fake-clis
setup() { install_fake_clis; }
```

- `COUNCIL_FAKE_BEHAVIOR` switches scenarios: `valid` (default), `empty`,
  `malformed-json`, `block-verdict`, `rate-limit`, `auth-failure`,
  `slow` (honors `COUNCIL_FAKE_SLEEP`), `error`.
- `--version` always succeeds, mirroring real CLIs where the version probe
  works even when logged out.
- Every invocation appends `{bin, args}` to
  `$COUNCIL_FAKE_STATE_DIR/calls.jsonl`, so tests can assert exactly what a
  provider script sent (model flag, prompt assembly, subcommands).

### Adding Tests

1. Create `tests/your_feature.bats`
2. Load test helper: `load test_helper`
3. Use bats syntax: `@test "description" { ... }`
4. Run: `bats tests/your_feature.bats`

---

## Lint (shellcheck)

CI blocks a merge on this, so run it before pushing. The tree is clean; any
finding is one you introduced.

```bash
brew install shellcheck        # macOS
sudo apt install shellcheck    # Ubuntu/Debian

shellcheck scripts/*.sh scripts/lib/*.sh scripts/providers/*.sh
```

`.shellcheckrc` in the repo root lets it follow `source "$SCRIPT_DIR/lib/*.sh"`.
Without it, shellcheck never opens the sourced files and calls every shared
definition unused. CI pins the version, so a newer local shellcheck may report
findings CI does not.

Silence a finding only where the code is right and the tool is wrong, and say
why on the line above:

```bash
# Ordering by mtime is the point, and find offers no portable way to sort.
# shellcheck disable=SC2012
ls -t "$dir"/*.json
```

---

## Manual Tests

Manual testing procedures for features that require API calls or Claude Code integration.

### Prerequisites

1. **API Keys configured** (at least one) OR a CLI agent installed:
   ```bash
   export GEMINI_API_KEY="your-key"
   export OPENAI_API_KEY="your-key"
   export XAI_API_KEY="your-key"          # GROK_API_KEY also accepted
   ```

   Alternatively, install `codex` and/or `agy` (Antigravity) CLIs — they're
   discovered automatically via PATH and use your existing subscription auth.

2. **Plugin loaded** in Claude Code:
   ```bash
   claude --plugin-dir /path/to/claude-council
   ```

3. **Verify provider status**:
   ```bash
   bash scripts/check-status.sh
   # Or via slash command:
   /claude-council:status
   ```
   Expected: At least one provider shows "Connected"

---

## Script-Level Tests (No Plugin Required)

These tests verify the bash implementation directly.

### JSON Output Structure
```bash
bash scripts/query-council.sh --providers=gemini "Test" 2>/dev/null | jq 'keys'
```
**Expected**: `["metadata", "round1"]`

### Argument Validation
```bash
bash scripts/query-council.sh --invalid-flag "Test" 2>&1
```
**Expected**: `Error: Unknown flag: --invalid-flag`

### Role Validation
```bash
bash scripts/query-council.sh --roles=nonexistent "Test" 2>&1
```
**Expected**: `Error: Unknown role: nonexistent` with available roles listed

### Role Preset Expansion
```bash
bash scripts/query-council.sh --providers=gemini,openai --roles=balanced "Test" 2>&1 | grep "Provider roles"
```
**Expected**: Shows security, performance, maintainability assignments

### Debate Mode JSON
```bash
bash scripts/query-council.sh --providers=gemini --debate "Test" 2>/dev/null | jq 'has("round2")'
```
**Expected**: `true`

### Formatter Test
```bash
echo '{"metadata":{"quiet_mode":false},"round1":{"gemini":{"status":"success","response":"Test","model":"test-model","role":"security"}}}' | bash scripts/format-output.sh
```
**Expected**: Formatted box with provider name, model, and role

### Quiet Mode Formatter
```bash
echo '{"metadata":{"quiet_mode":true},"round1":{"gemini":{"status":"success","response":"Test","model":"test"}}}' | bash scripts/format-output.sh
```
**Expected**: Only synthesis header shown (no provider response box)

---

## Feature Tests (Via Slash Command)

### 1. Basic Query

**Test**: Simple query to all providers
```bash
/claude-council:ask "What are the pros and cons of REST vs GraphQL?"
```

**Expected**:
- [ ] Shows "Querying N providers in parallel"
- [ ] Each provider shows status (success/cached/error)
- [ ] Response boxes with provider name + model
- [ ] Synthesis section with consensus/divergence table

---

### 2. Provider Selection (--providers)

**Test**: Query specific providers only
```bash
/claude-council:ask --providers=gemini,openai "Explain dependency injection"
```

**Expected**:
- [ ] Only queries Gemini and OpenAI
- [ ] Grok not included in output
- [ ] Synthesis only references queried providers

---

### 2b. CLI Providers (codex / antigravity)

**Test A**: CLI providers explicitly
```bash
/claude-council:ask --providers=codex,antigravity "What is the most common cause of a SIGSEGV in C?"
```

**Expected**:
- [ ] Only queries Codex CLI and Antigravity (no API calls made)
- [ ] Header banners show real model names (e.g. `gpt-5.5`, `Gemini 3.5 Flash (High)`)
- [ ] Codex banner uses OpenAI's white square (🔳); Antigravity uses Gemini's blue square (🟦)

**Test B**: Default flow with CLI shadowing
```bash
# With BOTH GEMINI_API_KEY/OPENAI_API_KEY set AND codex/agy binaries installed:
/claude-council:ask "Should I use UUID or BIGINT for primary keys?"
```

**Expected**:
- [ ] Discovery finds 6 providers but only 4 are queried (codex, antigravity, grok, perplexity)
- [ ] No `openai` or `gemini` (API) entry in the output — they were shadowed
- [ ] To force the API instead, use `--providers=openai,gemini` explicitly

---

### 3. File Context (--file)

**Test**: Include a specific file
```bash
/claude-council:ask --file=scripts/query-council.sh "Review this script for improvements"
```

**Expected**:
- [ ] File contents included in prompt to providers
- [ ] Responses reference specific code from the file
- [ ] Auto-context skipped (explicit file provided)

---

### 4. Export to File (--output)

**Test**: Save response to markdown
```bash
/claude-council:ask --output=test-output.md "What's the best way to handle errors in async code?"
```

**Expected**:
- [ ] File created at `test-output.md`
- [ ] Contains metadata header (Query, Date, Providers)
- [ ] Clean markdown (no ANSI codes, no box characters)
- [ ] All provider responses included
- [ ] Synthesis section present

**Cleanup**:
```bash
rm test-output.md
```

---

### 5. Quiet Mode (--quiet)

**Test**: Show only synthesis
```bash
/claude-council:ask --quiet "Should I use TypeScript or JavaScript?"
```

**Expected**:
- [ ] No individual provider response boxes shown
- [ ] Only synthesis section displayed
- [ ] Synthesis still references all provider opinions

---

### 6. Response Caching

**Test A**: First query (cache miss)
```bash
/claude-council:ask "What is the singleton pattern?"
```

**Expected**:
- [ ] All providers show "success" (not "cached")
- [ ] Cache files created in `.claude/council-cache/`

**Test B**: Repeat same query (cache hit)
```bash
/claude-council:ask "What is the singleton pattern?"
```

**Expected**:
- [ ] Providers show "cached" instead of "success"
- [ ] Response appears faster
- [ ] Same content as first query

**Test C**: Force fresh query
```bash
/claude-council:ask --no-cache "What is the singleton pattern?"
```

**Expected**:
- [ ] All providers show "success" (not "cached")
- [ ] Fresh responses from APIs

**Verify cache files**:
```bash
ls -la .claude/council-cache/
```

**Cleanup**:
```bash
rm -rf .claude/council-cache/
```

---

### 7. Auto-Context Injection

**Test A**: Question with code keywords
```bash
/claude-council:ask "How can I improve the caching implementation?"
```

**Expected**:
- [ ] Shows "Auto-included context (N files):"
- [ ] Lists files like `scripts/lib/cache.sh`
- [ ] Responses reference specific code from auto-included files

**Test B**: Disable auto-context
```bash
/claude-council:ask --no-auto-context "What are caching best practices?"
```

**Expected**:
- [ ] No "Auto-included context" message
- [ ] Generic response (not referencing local code)

**Test C**: Generic question (no code keywords)
```bash
/claude-council:ask "What's the weather like today?"
```

**Expected**:
- [ ] No auto-context injection (question doesn't reference code)

---

### 8. Specialized Roles (--roles)

**Test A**: Specific roles
```bash
/claude-council:ask --roles=security,performance,maintainability "Review this authentication approach: JWT stored in localStorage"
```

**Expected**:
- [ ] Shows "Provider roles:" before querying
- [ ] Each provider assigned different role
- [ ] Gemini focuses on security concerns
- [ ] OpenAI focuses on performance
- [ ] Grok focuses on maintainability
- [ ] Responses clearly reflect assigned perspectives

**Test B**: Role preset
```bash
/claude-council:ask --roles=balanced "How should I structure API endpoints?"
```

**Expected**:
- [ ] Preset expands to: security, performance, maintainability
- [ ] Same behavior as Test A

**Test C**: Fewer roles than providers
```bash
/claude-council:ask --roles=security "Review error handling in this approach"
```

**Expected**:
- [ ] First provider gets security role
- [ ] Other providers respond without role
- [ ] No errors

---

### 9. Debate Mode (--debate)

**Test**: Enable multi-round discussion
```bash
/claude-council:ask --debate "Should we use microservices or monolith for a new project?"
```

**Expected**:
- [ ] Shows "## Round 1: Initial Responses"
- [ ] All providers give initial answers
- [ ] Shows "## Round 2: Rebuttals"
- [ ] Each provider critiques others' responses
- [ ] Rebuttal headers use yellow color
- [ ] Synthesis includes:
  - [ ] Strongest criticisms
  - [ ] Consensus shifts
  - [ ] Unresolved tensions

**Test B**: Debate with roles
```bash
/claude-council:ask --debate --roles=security,scalability,simplicity "Review this database schema design"
```

**Expected**:
- [ ] Round 1: Each provider argues from their role
- [ ] Round 2: Rebuttals maintain role perspective
- [ ] Rich debate from different angles

---

### 10. Combined Flags

**Test**: Multiple flags together
```bash
/claude-council:ask --providers=gemini,openai --roles=security,performance --quiet --output=combined-test.md "Review this code pattern"
```

**Expected**:
- [ ] Only Gemini and OpenAI queried
- [ ] Roles assigned correctly
- [ ] Terminal shows only synthesis (quiet mode)
- [ ] File contains full output including individual responses

**Cleanup**:
```bash
rm combined-test.md
```

---

### 11. Vision / Image Input (--image)

**Test A**: Attach an image to vision-capable providers
```bash
/claude-council:ask --image=screenshot.png --providers=gemini,openai "What does this screen show?"
```

**Expected**:
- [ ] Gemini and OpenAI describe the actual image content (they received it)
- [ ] No base64 appears in the terminal output or the saved `council-*.md` transcript

**Test B**: Default set routes CLI providers to their vision siblings
```bash
/claude-council:ask --image=screenshot.png "Describe this"
```

**Expected**:
- [ ] codex's slot is answered by openai and antigravity's by gemini (marked as a fallback), both seeing the image
- [ ] grok / perplexity answer text-only, prefixed `(answered without the image)`

---

## Edge Cases

### No API Keys and no CLI agents
```bash
unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY XAI_API_KEY PERPLEXITY_API_KEY
# Strip /opt/homebrew/bin and ~/.nvm from PATH so codex/agy aren't discovered
bash scripts/query-council.sh "Test question" 2>&1
```
**Expected**: `Error: No providers configured.` followed by a hint to set an
API key OR install a CLI agent.

### Invalid Provider
```bash
bash scripts/query-council.sh --providers=invalid "Test" 2>&1
```
**Expected**: Attempts query but provider script not found (graceful error in JSON)

### Invalid Role
```bash
bash scripts/query-council.sh --roles=hacker "Test" 2>&1
```
**Expected**: `Error: Unknown role: hacker` with list of available roles

### Invalid --image (rejected before any provider runs)
```bash
bash scripts/query-council.sh --image=/nope.png --providers=gemini "Test" 2>&1
printf 'x' > /tmp/notes.txt
bash scripts/query-council.sh --image=/tmp/notes.txt --providers=gemini "Test" 2>&1
head -c 11000000 /dev/zero > /tmp/big.png
bash scripts/query-council.sh --image=/tmp/big.png --providers=gemini "Test" 2>&1
```
**Expected**, respectively:
- `Error: image not found: /nope.png`
- `Error: unsupported image type '.txt' (use png/jpg/jpeg/webp/gif)`
- `Error: image too large (... bytes; cap is 10485760)`

### Unknown Flag
```bash
bash scripts/query-council.sh --foobar "Test" 2>&1
```
**Expected**: `Error: Unknown flag: --foobar` with usage message

### Missing File
```bash
bash scripts/query-council.sh --file=/nonexistent "Test" 2>&1
```
**Expected**: `Error: File not found: /nonexistent`

### Empty Question
```bash
bash scripts/query-council.sh "" 2>&1
```
**Expected**: `Error: No prompt provided` with usage message

### Very Long Question
```bash
bash scripts/query-council.sh "$(cat README.md) - Summarize this" 2>/dev/null | jq '.metadata.prompt' | head -c 100
```
**Expected**: Handles gracefully, full prompt stored in metadata

---

## Performance Tests

### Cache TTL
1. Make a query
2. Wait > 1 hour (or set `COUNCIL_CACHE_TTL=10`)
3. Repeat query
**Expected**: Cache expired, fresh query made

### Timeout Handling
```bash
export COUNCIL_TIMEOUT=1
/claude-council:ask "Complex question requiring long response"
```
**Expected**: Timeout error, no retry

### Retry Logic
```bash
export COUNCIL_DEBUG=1
# (Requires simulating 429/5xx errors)
```
**Expected**: Retries with exponential backoff shown in debug output

---

## Checklist Summary

| Feature | Test Command | Status |
|---------|--------------|--------|
| Basic query | `/ask "question"` | [ ] |
| Provider selection | `--providers=gemini` | [ ] |
| File context | `--file=path` | [ ] |
| Export | `--output=file.md` | [ ] |
| Quiet mode | `--quiet` | [ ] |
| Cache hit | Same query twice | [ ] |
| Cache bypass | `--no-cache` | [ ] |
| Auto-context | Query with keywords | [ ] |
| No auto-context | `--no-auto-context` | [ ] |
| Roles | `--roles=security,perf` | [ ] |
| Role preset | `--roles=balanced` | [ ] |
| Debate | `--debate` | [ ] |
| Combined flags | Multiple flags | [ ] |
| Image input | `--image=shot.png` | [ ] |
