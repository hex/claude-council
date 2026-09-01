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
| `cli-providers.bats` | 66 tests | codex/antigravity/grok-cli/kimi-cli/ollama discovery, CLI-prefers-API policy, shadow_origin↔api_sibling single source, --list-available / --list-default, flag parsing, coerce_result_json JSON guard, CLI→API fallback (dedup, cache reuse, missing-script, round 2), a new API seat riding the generic `<NAME>_API_KEY` branch into the default set, gated E2E |
| `display.bats` | 44 tests | tmux/iTerm2 detection, wrapper no-op behavior, manifest writes, pane gating, tty probe, pane env forwarding, retry-await window floor, waiting-line truncation + autowrap guard, renderer selection (Rich feature probe, uv route + timeout, perl fallback, COUNCIL_RENDERER=perl, runtime fallback + stdout forwarding, think-block styling incl. unclosed tags, code-theme direction, link style, COLUMNS=0) |
| `keys.bats` | 7 tests | XAI_API_KEY ↔ GROK_API_KEY resolution, precedence, silent-conflict policy |
| `roles.bats` | 47 tests | presets, validation, prompt injection, assignment, local-council role resolution + member count |
| `tokens.bats` | 9 tests | reasoning-model token-cap bumping, glob patterns, floor, multi-pattern |
| `verbosity.bats` | 9 tests | brief/standard/detailed directives, fallback to standard |
| `query-council.bats` | 33 tests | argument parsing, error cases, flags, local-council fallback hint, hyphenated provider names (env-var prefix derivation), model-fallback wrapper (preferred-then-fallback retry, cached-verdict skip, explicit `<PROVIDER>_MODEL` opt-out, no verdict remembered when the fallback also fails), round 2 and CLI-sibling fallback carrying `model_fallback`, the pane's retry offer (offer file contents, r re-queries only the failed providers and clears the error list, expiry, pane closed at the offer, `COUNCIL_RETRY_WAIT=0`, no pane, a leaked non-watch-dir `COUNCIL_PANE_DIR` ignored) |
| `argmax.bats` | 4 tests | large response/prompt/debate-round-2 round-trip through final JSON (MSYS ARG_MAX marshalling guard) |
| `fake-clis.bats` | 63 tests | fixture self-checks, codex.sh/antigravity.sh/grok-cli.sh/kimi-cli.sh/ollama.sh against fake binaries (kimi-cli: stream-json parsing, dirty-stream tolerance, array-form content, tool-call narration excluded, no-tools agent pinned; ollama: daemon-down diagnostic; antigravity: the argv spill past `COUNCIL_ARGV_LIMIT`, its dedicated `--add-dir` directory, the guard and system prompt staying on argv while only the question is written out, cleanup after a failing CLI and under a spaced `TMPDIR`; `COUNCIL_PROVIDERS` roster precedence and its agreement with `--list-default` and `--list-available`; per-CLI timeout bounds via `COUNCIL_CLI_TIMEOUT`, a CLI that exits 0 on the deadline's SIGTERM still reported as a timeout, and that a timeout reports only the timeout, never the shell's own signal notice) |
| `format-output.bats` | 14 tests | defensive parsing: empty/missing/non-string responses, raw preservation, CLI→API fallback-note rendering, model-fallback note (preferred model named, absent when unset), the first provider key surviving CRLF from a Windows jq |
| `prompts.bats` | 11 tests | template loading, {{VAR}} interpolation, role-injection rendering |
| `agent-analysis.bats` | 11 tests | validate-analysis.sh as the executable mirror of the agent-analysis schema, kept in sync with it |
| `check-status.bats` | 31 tests | two-tier CLI availability, remediation strings, HTTP probe branches (401/403/500/000), rejected-key classification (Gemini/xAI answer a bad key with 400, not 401) and its false-positive guards (a typo'd model is not a bad key), transfer-failure exit codes, curl writing nothing, unusable jq, Perplexity's minimum max_tokens, every row's status beginning at the same column, `-X POST` and `--max-time` on every probe, OpenRouter probed at `/api/v1/key` rather than the `/api/v1/models` endpoint that answers 200 without a key, temp-file cleanup, keys off the curl argv, ms clock |
| `jobs.bats` | 18 tests | job store, --async lifecycle, --result/--jobs/--cancel (incl. the worker tree dying when jq emits CRLF), self-ignoring cache dir |
| `router-seats.bats` | 14 tests | `OPENROUTER_MODELS` splitting the one router script into numbered seats: per-seat `get_model` (roster entry, `<SEAT>_MODEL` override, out-of-range reporting `unknown` rather than a neighbour's id), discovery replacing rather than joining the single seat, `provider_script_path` mapping every seat back to one script, per-seat vision opt-in, colour and swatch not falling to the unknown-provider default, every provider's swatch drawing to the same width, every palette name provider_color asks for being defined by both rendering callers, and an end-to-end run asserting each seat both is labelled with and actually queried its own model |
| `stop-gate.bats` | 12 tests | opt-in gating, loop guards, BLOCK verdict, fail-open, an allowlisted API seat actually reaching the reviewer, config/event reads surviving CRLF from a Windows jq |
| `theme.bats` | 24 tests | terminal theme detection, theme-aware emphasis + muted-text (faint/gray) rendering |
| `providers.bats` | 76 tests | API provider payloads (gemini, openai, grok, perplexity, kimi; gemini's multi-part text join, empty-200 diagnostics and the opt-in thinking cap), the default model each one queries and the reasoning-token cap its id earns (the `*-latest` aliases included), response parsing, endpoint routing, secret/payload hygiene (including a large prompt never reaching jq's argv, per provider), vision image injection (gemini inlineData, openai input_image/image_url, grok/perplexity image_url), model-unavailable exit-3 classification per provider (grok 403 region block, openai/gemini/perplexity 404/400) vs. ordinary errors (401/500) still exiting 1, bare-string `.error` extraction without crashing, the temperature Moonshot's models accept, and a gated real-endpoint acceptance check per provider. OpenRouter carries its own block: errors arriving inside an HTTP 200 classified on `.error.code`, the live API's 400-for-an-unknown-slug separated from an ordinary bad-parameter 400 and both from 404, while 401/402/403/429/5xx exit 1, a null `.choices` content refused rather than answered, the routed `.model` logged to stderr only under debug, exactly one `model` id sent (never `models[]` or `route`), and a slash/tilde model id surviving MSYS in the payload |
| `image.bats` | 9 tests | --image validation (missing/bad-type/oversize), vision routing, CLI→sibling routing (only when the sibling can see), non-vision text-only tag, base64 never in the cache |
| `pane-watcher.bats` | 16 tests | standalone pane watcher: banner + response render, error notice (incl. text with no trailing newline, as the producer writes it), retry offer (prompt + countdown, r hands back to the live loop, esc closes, withdrawn offer degrades to the plain close prompt, prompt clipped to the pane width with autowrap off, a second failure on retry replayed in its own words), SetMark, watch-dir cleanup, re-render of every shown block on a width change (mid-run and at the close prompt), replay order across responses and errors, no redraw while a drag is still moving, ctrl-d and closed-stdin exits |
| `export.bats` | 5 tests | markdown transcript export writing + formatting |
| `release.bats` | 5 tests | release.sh version bump/commit/tag, staged-index guard, green-suite gate |
| `retry.bats` | 11 tests | curl_with_retry backoff + status handling, curl_secret_config off-argv config file, ensure_error_body http_status stamping (object and string `.error`, Gemini's string `.error.status` left alone, synthesised message, 200 passthrough) |
| `model_fallback.bats` | 29 tests | is_model_unavailable_error classifier (positive/negative fixtures from real vendor bodies), model_fallback_for pairs and the invariant that no provider degrades to the model it already prefers, verdict cache (TTL, provider+model+key scoping, corrupt/fractional-timestamp guards), model_fallback_key_hash, gated real-API test (default model or its fallback answers, end to end) |
| `deadline.bats` | 9 tests | run_with_deadline: the caller's stdin reaches the command, the command's own status passes through, status 143 at the deadline whatever the command did with the signal (a CLI that exits 0 on SIGTERM), SIGKILL after the grace period for one that ignores it, the command's own children not holding the captured stdout, no watchdog outliving a fast call, nothing on stderr for a signal-ended job, 0 = unbounded, a non-integer deadline rejected |

**Total: 603 tests** across 26 `.bats` files.

### Hermetic CLI Fixture

`tests/fixtures/fake-clis.bash` installs real fake
`codex`/`agy`/`grok`/`kimi`/`ollama` executables into a temp dir prepended to
`PATH`, so provider scripts, async jobs, and the stop gate run end-to-end with
no network or real CLIs:

```bash
load fixtures/fake-clis
setup() { install_fake_clis; }
```

- `COUNCIL_FAKE_BEHAVIOR` switches scenarios: `valid` (default), `empty`,
  `malformed-json`, `block-verdict`, `rate-limit`, `auth-failure`,
  `slow` (honors `COUNCIL_FAKE_SLEEP`), `hang`, `hang-handled` (exits 0 on the
  deadline's SIGTERM, as the codex wrapper does), `error`, and, for the kimi
  fake only, `dirty-stream`, `array-content` and `tool-narration`.
- `--version` always succeeds, mirroring real CLIs where the version probe
  works even when logged out.
- Every invocation appends `{bin, args}` to
  `$COUNCIL_FAKE_STATE_DIR/calls.jsonl`, so tests can assert exactly what a
  provider script sent (model flag, prompt assembly, subcommands).

### Real-endpoint tests (`COUNCIL_E2E=1`)

The hermetic tests drive a fake `curl` and fake CLI binaries, so they assert
what a provider sends and never what the endpoint does with it. A payload that
cannot succeed passes every one of them: Moonshot accepts no temperature but 1,
and `kimi.sh` sent 0.7 for as long as nothing called the real API.

Eight tests close that gap, skipped by default and run with the gate set:

```bash
COUNCIL_E2E=1 bats tests/providers.bats tests/cli-providers.bats
```

Each skips again when its own key or CLI is absent, so a partial setup runs the
part it can. They cost real tokens and depend on live services, which is why
they stay out of the default suite and out of CI.

### Adding Tests

1. Create `tests/your_feature.bats`
2. Load test helper: `load test_helper`
3. Use bats syntax: `@test "description" { ... }` — keep the name ASCII (see Windows below)
4. Run: `bats tests/your_feature.bats`

### Windows

CI runs the suite on `windows-latest` under Git Bash, alongside Ubuntu and
macOS. Budget ~22 minutes: MSYS emulates `fork`, so a test that runs
`query-council.sh` end to end costs 3–4 s there against 0.1–0.3 s on Linux.
What Windows does that the others do not, and how to test for it without a
Windows machine:

- jq's Windows build CRLF-terminates piped stdout, and a `read < <(jq ...)`
  keeps the `\r` (a `$(...)` strips it). `install_crlf_jq` in
  `test_helper.bash` puts a jq on PATH that does the same; prefix
  `PATH="$CRLF_BIN:$PATH"` on the one invocation under test.
- MSYS rewrites POSIX-looking paths in argv and in environment values before a
  native binary sees them, and its ARG_MAX is ~32 KB. Large or path-shaped
  values reach jq on stdin.
- bats on MSYS cannot look up a `@test` whose name has a non-ASCII character;
  it reports `unknown test name` and the count comes up short.

---

## Lint (shellcheck)

CI blocks a merge on this, so run it before pushing. The tree is clean; any
finding is one you introduced.

```bash
brew install shellcheck        # macOS
sudo apt install shellcheck    # Ubuntu/Debian

git ls-files '*.sh' | xargs shellcheck
```

CI lints every tracked `.sh`, so a script in a new directory cannot slip past it.

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
   export KIMI_API_KEY="your-key"
   ```

   Alternatively, install `codex`, `agy` (Antigravity), `grok` and/or `kimi` CLIs.
   They're discovered automatically via PATH and use your existing subscription
   auth. `ollama` is discovered the same way and needs no key at all.

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

### 2b. CLI Providers (codex / antigravity / grok-cli / kimi-cli) and local ollama

**Test A**: CLI providers explicitly
```bash
/claude-council:ask --providers=codex,antigravity "What is the most common cause of a SIGSEGV in C?"
```

**Expected**:
- [ ] Only queries Codex CLI and Antigravity (no API calls made)
- [ ] Header banners show `default` for CLI providers without a `*_MODEL` override
- [ ] Codex banner uses OpenAI's white square (🔳); Antigravity uses Gemini's blue square (🟦)

**Test B**: Default flow with CLI shadowing
```bash
# With BOTH GEMINI_API_KEY/OPENAI_API_KEY set AND codex/agy binaries installed:
/claude-council:ask "Should I use UUID or BIGINT for primary keys?"
```

**Expected**:
- [ ] Discovery finds 6 providers but only 4 are queried (codex, antigravity, grok, perplexity)
- [ ] With the `grok` CLI also installed, discovery finds 7 and shadows 3 API siblings (`openai`, `gemini`, `grok`), still only 4 queried (codex, antigravity, grok-cli, perplexity)
- [ ] With the `kimi` CLI also installed, `kimi-cli` shadows the `kimi` API provider the same way
- [ ] With `ollama` installed it is simply added: it shadows nothing and displaces no API provider
- [ ] No `openai` or `gemini` (API) entry in the output — they were shadowed
- [ ] To force the API instead, use `--providers=openai,gemini` explicitly

**Test C**: Grok CLI explicitly
```bash
/claude-council:ask --providers=grok-cli "What is the most common cause of a SIGSEGV in C?"
```

**Expected**:
- [ ] Only queries the Grok CLI (no API call made)
- [ ] Header banner shows the real model name (the grok CLI's own default, or `GROK_CLI_MODEL` if set)
- [ ] Grok CLI banner uses Grok's red square (🟥)

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
/claude-council:ask --image=screenshot.png --providers=gemini,openai,grok,perplexity "What does this screen show?"
```

**Expected**:
- [ ] Gemini, OpenAI, Grok, and Perplexity describe the actual image content (they received it)
- [ ] No base64 appears in the terminal output or the saved `council-*.md` transcript

**Test B**: Default set routes CLI providers to their vision siblings
```bash
/claude-council:ask --image=screenshot.png "Describe this"
```

**Expected**:
- [ ] codex's slot is answered by openai, antigravity's by gemini, and grok-cli's by grok (marked as a fallback), all seeing the image
- [ ] kimi-cli is NOT routed to its sibling: `kimi` cannot see, so kimi-cli answers text-only, prefixed `(answered without the image)`

---

## Edge Cases

### No API Keys and no CLI agents
```bash
unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY XAI_API_KEY PERPLEXITY_API_KEY KIMI_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY
# Strip /opt/homebrew/bin and ~/.nvm from PATH so codex/agy/grok/kimi/ollama aren't discovered (several install there via homebrew/npm)
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
