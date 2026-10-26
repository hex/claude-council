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

# Run only the named files (how each Windows CI shard runs its tests/shards/N.txt)
./tests/run_tests.sh "tests/cache.bats tests/roles.bats"

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
| `cli-providers.bats` | 95 tests | codex/antigravity/grok-cli/kimi-cli/cursor-cli/ollama discovery, claude-cli, copilot-cli and opencode never seated by discovery, claude-cli's and copilot-cli's models never read from their own config, opencode's read from `.model` where the CLI reads it (an `OPENCODE_CONFIG` file over the config dir, `OPENCODE_CONFIG_DIR` over `XDG_CONFIG_HOME`, `opencode.jsonc` read unless it holds comments, `OPENCODE_MODEL` over all of them), a real claude-cli seat answering without a project CLAUDE.md, a real copilot-cli seat without a project AGENTS.md and a real opencode seat without the project's or the user's AGENTS.md (`COUNCIL_E2E=1`), CLI-prefers-API policy, shadow_origin↔api_sibling single source, --list-available / --list-default, flag parsing, coerce_result_json JSON guard, CLI→API fallback (dedup, cache reuse, missing-script, round 2), a new API seat riding the generic `<NAME>_API_KEY` branch into the default set, `--list-default-models` pairing each default provider with the model it would send and naming exactly what `--list-default` names, the fallback slot's `fallback_reason` and the pane's `fallback` row (`<model> via <sibling> API`, the reason in `errors/<provider>.txt`), gated E2E |
| `display.bats` | 53 tests | tmux/iTerm2 detection, wrapper no-op behavior, manifest writes, pane gating, tty probe, pane env forwarding, retry-await window floor, waiting-line truncation + autowrap guard, the mod pane's watch dir (`COUNCIL_MOD_PANE_DIR`, `pid`, `colors`, `job-id`, `job-file`, `.retry-declined`), a guard that no blank check strips a whole response, renderer selection (Rich feature probe, uv route + timeout, perl fallback, COUNCIL_RENDERER=perl, runtime fallback + stdout forwarding, think-block styling incl. unclosed tags, code-theme direction, link style, COLUMNS=0) |
| `keys.bats` | 7 tests | XAI_API_KEY ↔ GROK_API_KEY resolution, precedence, silent-conflict policy |
| `roles.bats` | 56 tests | presets, validation, prompt injection, positional and `provider=role` assignment (mixed forms, an absent provider and a duplicate provider all refused; roleless providers named on stderr; an empty roster refused under `set -u` on bash 3.2), local-council role resolution + member count |
| `tokens.bats` | 9 tests | reasoning-model token-cap bumping, glob patterns, floor, multi-pattern |
| `verbosity.bats` | 9 tests | brief/standard/detailed directives, fallback to standard |
| `query-council.bats` | 56 tests | argument parsing, each provider's environment scrubbed to the basics and its own vendor's variables (another vendor's key and unrelated secrets absent, `COUNCIL_PASS_ENV` names present, grok given its xAI key, claude-cli given its OAuth token and config dir but not the driving session's variables or `ANTHROPIC_API_KEY`, copilot-cli given `COPILOT_*` but not `GH_TOKEN` or `GITHUB_TOKEN`, opencode given `OPENCODE_MODEL`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR` and `XDG_*` but no other `OPENCODE_*` variable and no vendor key), error cases, flags, local-council fallback hint, hyphenated provider names (env-var prefix derivation), model-fallback wrapper (preferred-then-fallback retry, cached-verdict skip, explicit `<PROVIDER>_MODEL` opt-out, no verdict remembered when the fallback also fails), round 2 and CLI-sibling fallback carrying `model_fallback`, the pane's retry offer (offer file contents, r re-queries only the failed providers and clears the error list, expiry, pane closed at the offer, `COUNCIL_RETRY_WAIT=0`, no pane, a leaked non-watch-dir `COUNCIL_PANE_DIR` ignored), `metadata.pane_shown` (true for a live pane, false with no pane, a pane closed mid-run, or an `--async` job), a seat cancelled from the pane (its process tree ended, the slot an error reading `cancelled from the pane`, the `cancelled` status line, no retry offer for it, an answer that landed before the press kept, a round-1 cancel sitting out the debate, a marker older than the round spent rather than honoured, a tree that ignores SIGTERM killed after the grace period, the slot keeping its role, no cancel path touched without a pane), and a seat's row retry through a `retry/<provider>` marker (honoured while another seat still runs and re-querying with the same launch, not honoured once the last seat ended so the band offers instead, a stale marker spent by the band's relaunch, one press per seat with a second failure kept out of the band's offer, a cancelled seat ignoring it, no retry path touched without a pane) |
| `argmax.bats` | 4 tests | large response/prompt/debate-round-2 round-trip through final JSON (MSYS ARG_MAX marshalling guard) |
| `fake-clis.bats` | 146 tests | fixture self-checks, codex.sh/antigravity.sh/grok-cli.sh/kimi-cli.sh/cursor-cli.sh/claude-cli.sh/copilot-cli.sh/opencode.sh/ollama.sh against fake binaries (the tokens claude-cli and cursor-cli report with the cache added back to input, an error result's tokens kept, copilot's per-request usage events and opencode's per-step tokens summed, a copilot usage event or an opencode step with no input or output count leaving the call unreported; copilot-cli: the answer parsed from JSONL past the CLI's notices, its whole tool-less argv pinned, `COPILOT_ALLOW_ALL` never reaching the CLI, the logged-out text reported whole; opencode: the answer from the text events, its whole argv pinned, an empty config dir with project config off under both names the CLI reads, an inherited `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR` and `OPENCODE_CONFIG_PROJECT_DISABLE=0` replaced before the CLI starts while the model still comes from that config, `OPENCODE_CONFIG` unset and every permission denied, the model from the user's config passed as `-m`, the error event on stdout reported when stderr is empty, the run's session deleted afterwards on success and failure and nothing deleted when no session was named; kimi-cli: stream-json parsing, dirty-stream tolerance, array-form content, tool-call narration excluded, no-tools agent pinned; ollama: daemon-down diagnostic; antigravity: the argv spill past `COUNCIL_ARGV_LIMIT`, its dedicated `--add-dir` directory, the guard and system prompt staying on argv while only the question is written out, cleanup after a failing CLI and under a spaced `TMPDIR`; `COUNCIL_PROVIDERS` roster precedence and its agreement with `--list-default` and `--list-available`; per-CLI timeout bounds via `COUNCIL_CLI_TIMEOUT`, a CLI that exits 0 on the deadline's SIGTERM still reported as a timeout, and that a timeout reports only the timeout, never the shell's own signal notice; each CLI's failure keeping its cause at the end of a long, coloured stderr; codex given no stdin; each CLI's failure with a byte that is not valid UTF-8; grok-cli's deny rules and its one retry without `--sandbox`, on grok's refusal to start alone, not on a sandbox warning beside another failure; grok-cli's Claude and Cursor import switches off on both attempts; seat isolation: every CLI seat run from one read-only, empty scratch directory under `claude-council-<uid>`, a non-empty or unlistable one refused and left as found whatever its entries are named, a seat's attempted write into its working directory failing, the per-user root and its symlink and ownership refusals, each seat's own home holding only the links named (keychain, `.config/cursor`, `.docker/run`, the real `GROK_HOME` and `XDG_DATA_HOME`), a model passed only when the user's own config names one, the codex seat's per-run home, an API key with no `auth.json` and no keyring store run on the key in that home, and its keyring fallback, API key exported or not, with its note shown above the answer, Windows keeping the user's home, and the user's real home left byte-for-byte unchanged) |
| `format-output.bats` | 21 tests | defensive parsing: empty/missing/non-string responses, raw preservation, CLI→API fallback-note rendering and the fallback reason under it in both rounds, model-fallback note (preferred model named, absent when unset), the first provider key surviving CRLF from a Windows jq, the pane marker line present only when `pane_shown`, no rebuttal block for a seat with no round-2 slot |
| `prompts.bats` | 11 tests | template loading, {{VAR}} interpolation, role-injection rendering |
| `agent-analysis.bats` | 11 tests | validate-analysis.sh as the executable mirror of the agent-analysis schema, kept in sync with it |
| `check-status.bats` | 39 tests | two-tier CLI availability, the claude-cli row probed under its scrubbed environment, the copilot-cli row's seat hint and install remediation, the opencode row's seat hint, its `auth list --standalone` probe that sends no prompt and gets no inherited `OPENCODE_CONFIG_CONTENT`, with project config off, its logged-out and install remediations, remediation strings, HTTP probe branches (401/403/500/000), the inference probe after a passed key check (402 and each vendor's out-of-quota marker read `Inference blocked`, a plain 429 `Rate limited`, any other answer `inference unverified`, a rejected key gets no chat request), rejected-key classification (Gemini/xAI answer a bad key with 400, not 401) and its false-positive guards (a typo'd model is not a bad key), transfer-failure exit codes, curl writing nothing, unusable jq, Perplexity's minimum max_tokens, a Perplexity 403 read as a rejected key only on `invalid_api_key` (an HTML or typeless 403 is a plain error, its message on the row), a retired `PERPLEXITY_MODEL` shown as `Unsupported model` with no probe sent, every row's status beginning at the same column, a roster seat row keeping the export hint |
| `check-status-probe.bats` | 13 tests | the probes themselves rather than what they report: `-X POST` and `--max-time` on every probe, each inference probe's chat endpoint and 16-token cap, OpenRouter probed at `/api/v1/key` rather than the `/api/v1/models` endpoint that answers 200 without a key, Perplexity's minimum max_tokens, temp-file cleanup, keys off the curl argv, an unusable jq, curl writing nothing |
| `jobs.bats` | 19 tests | job store, --async lifecycle, --result/--jobs/--cancel (incl. the worker tree dying when jq emits CRLF), self-ignoring cache dir |
| `router-seats.bats` | 15 tests | `OPENROUTER_MODELS` splitting the one router script into numbered seats: per-seat `get_model` (roster entry, `<SEAT>_MODEL` override, out-of-range, zero, leading-zero and non-numeric seat numbers all reporting `unknown` rather than a neighbour's id or an arithmetic abort), discovery replacing rather than joining the single seat, `provider_script_path` mapping every seat back to one script, per-seat vision opt-in, colour and swatch not falling to the unknown-provider default, every provider's swatch drawing to the same width, every palette name provider_color asks for being defined by both rendering callers, and an end-to-end run asserting each seat both is labelled with and actually queried its own model |
| `stop-gate.bats` | 16 tests | opt-in gating, loop guards, BLOCK verdict, fail-open, the reviewer name checked against the providers on disk (a path-shaped name allows the stop), an allowlisted API seat actually reaching the reviewer, the reviewer given its own key and no other secret, config/event reads surviving CRLF from a Windows jq, a review several times what a pipe holds still blocking |
| `theme.bats` | 24 tests | terminal theme detection, theme-aware emphasis + muted-text (faint/gray) rendering |
| `providers.bats` | 128 tests | `provider_allowlisted` (a plain-word name with a script, never a path or a missing script), each API seat's tokens written to `COUNCIL_USAGE_FILE` in one shape (cached inside input, reasoning inside output whether the vendor counts it apart or not, a split the body leaves out null; no record for a body without usage or with another shape, a billed empty answer still recorded, an unwritable file changing nothing the provider prints or returns), API provider payloads (gemini, openai, grok, perplexity, kimi; gemini's multi-part text join, empty-200 diagnostics and the opt-in thinking cap), the default model each one queries and the reasoning-token cap its id earns (the `*-latest` aliases included), response parsing, endpoint routing, secret/payload hygiene (including a large prompt never reaching jq's argv, per provider, and the image base64 — the larger of the two payloads — never reaching it either, per vision provider, with and without perplexity's recency filter, since its input is built once either way), vision image injection (gemini inlineData, openai input_image/image_url, grok image_url, perplexity input_image), perplexity's preset or `provider/model` field, a retired `sonar-*` id or a typo refused before any request, and an unreadable 200 (no message item, non-array content, non-JSON) printing its raw body under the incomplete warning when `status` is `incomplete`, model-unavailable exit-3 classification per provider (grok 403 region block, openai/gemini/perplexity 404/400) vs. ordinary errors (401/500) still exiting 1, bare-string `.error` extraction without crashing, the temperature Moonshot's models accept, and a gated real-endpoint acceptance check per provider. OpenRouter carries its own block: errors arriving inside an HTTP 200 classified on `.error.code`, the live API's 400-for-an-unknown-slug separated from an ordinary bad-parameter 400 and both from 404, while 401/402/403/429/5xx exit 1, a null `.choices` content refused rather than answered, the routed `.model` logged to stderr only under debug, exactly one `model` id sent (never `models[]` or `route`), a slash/tilde model id surviving MSYS in the payload, a stale `COUNCIL_SEAT` the roster cannot have leaving the default model, and routed reasoning ids (r1, o-series, qwen) earning the token bump while an ordinary id keeps the plain cap |
| `heads-up.bats` | 43 tests | the detached side-check runner asking its one `--seat` with the fake CLIs: a seat name off the registry, or two names, exits 1 before the fork, the call returns before the seat answers, a codex note and a text seat's NOTE lines each land in `result.json`, each seat outcome's `usage` (codex's from `turn.completed` on a note and on none, a text seat's from its provider, absent for a seat that prints no counts and for a timeout), codex asked through `--output-schema` with prompt.md on stdin, codex none and a text seat `NONE.` are none, codex past its deadline is a recorded timeout and is ended, as is a seat whose wrapper obeys TERM while its child ignores it, codex exit 0 without `turn.completed` an error, a codex answer that fits the schema but has an empty topic or headline an error, codex or a text seat failing writes `failed` with the reason, codex's `turn.failed` message taking the place of its stderr as that reason, codex out of credits written as `quota` with codex's own words, `.done` after `result.json`, an off-contract text reply never a note, `bytes` equal to prompt.md, a transcript that cannot be resolved reported before the seat runs, a transcript holding no prompt written as `skipped` with its reason and no seat asked, a conversation cs opened for the person checked like a typed one, codex run from the run dir under a `CODEX_HOME` of its own there (its `config.toml` holding the user's model and effort, or the `--model` pick over them, a TOML-quoted model name, neither key when nobody names one, and the fixed sections that turn skills, plugins, apps, hooks and memories off; its `auth.json` the user's own file as codex starts, a write through it landing in the user's login and removing the run dir leaving that login, through a hard link where a symlink is refused or comes out as a copy), a relative `--run-dir` reaching codex as the run dir, and codex run with no login file under a `CODEX_API_KEY` or an `OPENAI_API_KEY` when the user has no `auth.json`, a refused check naming why with codex never run when the user's login is in the keyring (an API key exported too), the user has neither, or the user's config sets a `model_provider` other than `openai` or a `profile`, and a failed check naming why when `ln` cannot link the login, a malformed effort or deadline refused before the fork, and a tool result holding a secret reaching prompt.md on purpose |
| `image.bats` | 10 tests | --image validation (missing/bad-type/oversize), vision routing, CLI→sibling routing (only when the sibling can see), non-vision text-only tag, base64 never in the cache |
| `pane-watcher.bats` | 18 tests | standalone pane watcher: banner + response render, error notice (incl. text with no trailing newline, as the producer writes it), a seat its API sibling answered (the answer, `<model> via <sibling> API`, the reason under an amber `↪ fell back` notice), a cancelled seat's grey `○ cancelled` notice, retry offer (prompt + countdown, r hands back to the live loop, esc closes, withdrawn offer degrades to the plain close prompt, prompt clipped to the pane width with autowrap off, a second failure on retry replayed in its own words), SetMark, watch-dir cleanup, re-render of every shown block on a width change (mid-run and at the close prompt), replay order across responses and errors, no redraw while a drag is still moving, ctrl-d and closed-stdin exits |
| `export.bats` | 5 tests | markdown transcript export writing + formatting |
| `release.bats` | 5 tests | release.sh version bump/commit/tag, staged-index guard, green-suite gate |
| `retry.bats` | 11 tests | curl_with_retry backoff + status handling, curl_secret_config off-argv config file, ensure_error_body http_status stamping (object and string `.error`, Gemini's string `.error.status` left alone, synthesised message, 200 passthrough) |
| `model_fallback.bats` | 31 tests | is_model_unavailable_error classifier (positive/negative fixtures from real vendor bodies), model_fallback_for pairs (a numbered router seat has none) and the invariant that no provider degrades to the model it already prefers, verdict cache (TTL, provider+model+key scoping, corrupt/fractional-timestamp guards), model_fallback_key_hash, gated real-API test (default model or its fallback answers, end to end) |
| `deadline.bats` | 10 tests | run_with_deadline: the caller's stdin reaches the command, the command's own status passes through, status 143 at the deadline whatever the command did with the signal (a CLI that exits 0 on SIGTERM), SIGKILL after the grace period for one that ignores it and for a child that ignores it after its parent has exited, the command's own children not holding the captured stdout, no watchdog outliving a fast call, nothing on stderr for a signal-ended job, 0 = unbounded, a non-integer deadline rejected |
| `transcript-digest.bats` | 58 tests | session JSONL to markdown: the `--tool-results K --tool-result-chars N` mode (off by default so the two secret-stays-out cases hold; under it a tool result reaches the digest on purpose, a Write's content and an Edit's inserted text stand in for their one-line results under a heading naming the file while every other tool's input still stays out, a failed or deleting Edit keeps its result, a Write past the argument limit still digests, peer and notification rows still stay out, AskUserQuestion takes no slot, the cap with its tail, `[error]`, K counts only results inside the window, string and array content, a tool name that cannot forge a heading, a cap without the mode refused), the five-clause prompt filter (a tool result, a cross-session peer message carrying another Claude's prose, a compact summary, a prompt another mod such as a Slack relay submitted, and cs's exact rotation launch line all kept out of the text, while a person quoting that line stays; a prompt cs or cs-rotate submitted anchors the window without being shown), assistant replies interleaved in file order, thinking blocks and their signatures dropped, `--turns last:N` windowing, a bare session id refused with the lookup named rather than performed, AskUserQuestion exchanges emitted as question, options and pick (a decline stays a question, a pick does not count as a turn), and malformed records skipped, counted and named in the digest while a file with no readable record fails loudly |
| `seat-info.bats` | 7 tests | the pane mod's seat questions on the real script with no provider keys or CLIs: `discover` lists only the seat whose key a test sets, an XAI key alone seats grok, no keys prints nothing and succeeds; `model` resolves a default and a `<PROVIDER>_MODEL` override; `allowlisted` exits 0 for a provider and 1 for an unknown name, a path and a name with a space; a missing, unknown or extra argument exits 2 with the usage line |
| `session-transcript.bats` | 4 tests | session id to transcript path: resolution by glob across project directories, a loud failure for an unknown id, a refusal when one id matches two files, and a non-uuid rejected before it reaches a path |
| `shards.bats` | 1 test | every bats file is named in the shard lists the Windows CI job runs from |
| `tmpdir.bats` | 1 test | every temp file the scripts create honours `TMPDIR` |

**Total: 962 tests** across 33 `.bats` files.

The bats suite does not cover `mods/`. The council-pane mod has its own checks:

```bash
(cd mods/council-pane && bun test && bunx tsc -p .)
claude plugin validate .
```

`tests/e2e/heads-up-e2e.sh` drives the heads-up side-check in a real interactive Claude Code through tmux, with the suite's fake `codex` on PATH so the seat answers the fixture's note without a model: a throwaway project whose file says `enabled: false` with `every: 2`, the once-per-install intro on the prompt hint, `/heads-up` reading the state and `/heads-up on` writing the file, a three-command turn on Haiku that reaches the cadence, the band with its four choices and seat line, Learn more (title and bullets), Tell Claude (the draft in the prompt box, the topic in the store's `seen`), the draft sent and answered, `/heads-up status` showing the counts, and a `tokens` row covering every one of those checks, once every launched check has settled (no run dir left under `council-mod.<session>/heads-up/`), and `/exit` leaving no process. It seeds the trust flag for the throwaway path in your own `~/.claude.json` and removes it on exit, and puts back the plugin store's `heads-up`, `heads-up-counts`, `heads-up-tokens` and `heads-up-intro-shown` keys. Run it by hand; `tests/e2e/heads-up-e2e.expected.txt` is a recorded passing run.

`tests/e2e/heads-up-codex-e2e.sh <session-id>` runs one real check against the logged-in `codex` on the session you name: it sends that session's last turns and tool results, the text Claude wrote with Write or Edit included, off the machine, so pick a session whose content may go, and run it by hand. It prints the elapsed time, the prompt size and `result.json`, and passes on `none` or `note`; `skipped` means the session you named holds no typed or cs-submitted prompt.

### Hermetic CLI Fixture

`tests/fixtures/fake-clis.bash` installs real fake
`codex`/`agy`/`grok`/`kimi`/`cursor-agent`/`claude`/`copilot`/`opencode`/`ollama` executables into a temp dir prepended to
`PATH`, so provider scripts, async jobs, and the stop gate run end-to-end with
no network or real CLIs:

```bash
load fixtures/fake-clis
setup() { install_fake_clis; }
```

- `COUNCIL_FAKE_BEHAVIOR` switches scenarios: `valid` (default), `empty`,
  `malformed-json`, `block-verdict`, `rate-limit`, `auth-failure`,
  `slow` (honors `COUNCIL_FAKE_SLEEP`), `hang`, `hang-handled` (exits 0 on the
  deadline's SIGTERM, as the codex wrapper does), `error`, `noisy-error`
  (70 KB of stderr ahead of a coloured cause on its last line), `stdin-echo`
  (answers with whatever arrived on stdin), `long-block-verdict` (a BLOCK
  verdict followed by 200 KB of review), `binary-error` (a cause holding a
  byte that is not valid UTF-8) and, for one fake only: kimi's
  `dirty-stream`, `array-content` and `tool-narration`, cursor-agent's
  `bad-model`, and grok's `sandbox-failure` (the refusal grok prints when it
  cannot apply `--sandbox`) and `sandbox-warning` (the warning alone, beside
  an unrelated failure).
- `--version` always succeeds, mirroring real CLIs where the version probe
  works even when logged out.
- Every invocation appends `{bin, args}` to
  `$COUNCIL_FAKE_STATE_DIR/calls.jsonl`, so tests can assert exactly what a
  provider script sent (model flag, prompt assembly, subcommands).
- codex under `--output-schema` (the heads-up call) also keeps its stdin in
  `codex-stdin.txt`, its `CODEX_HOME` and working directory in
  `codex-home.json`, and a copy of `$CODEX_HOME/config.toml` in
  `codex-config.toml`.

### Real-endpoint tests (`COUNCIL_E2E=1`)

The hermetic tests drive a fake `curl` and fake CLI binaries, so they assert
what a provider sends and never what the endpoint does with it. A payload that
cannot succeed passes every one of them: Moonshot accepts no temperature but 1,
and `kimi.sh` sent 0.7 for as long as nothing called the real API.

Eleven tests close that gap, skipped by default and run with the gate set:

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
5. Add the file name to one of `tests/shards/*.txt`, the lightest list; `shards.bats` fails until every bats file is listed exactly once

### Windows

CI runs the suite on `windows-latest` under Git Bash, alongside Ubuntu and
macOS, split across four shards of about 9 minutes each (`tests/shards/`).
Every test pays about a second in process creation there, so a test that runs
`query-council.sh` end to end costs 3–4 s against 0.1–0.3 s on Linux.
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

### macOS (bash 3.2)

The macOS runner parses the suite with `/bin/bash` 3.2, where one construct
behaves differently from bash 5 on the other two legs:

- **3.2 scans comment text inside a process substitution instead of stripping
  it.** It reads the comment lines inside `< <( ... )` looking for quotes and
  parens before it strips comments, so two shapes break the run:

  - an odd number of `'` across those comment lines leaves the parser holding an
    open quote, which swallows the closing paren:
    ``bad substitution: no closing `)' ``
  - a stray `)` ends the substitution early:
    `/dev/fd/62 ...: No such file or directory`

  Write "the prompt reads it", never "the prompt's read", and keep parens out of
  those comments. Both failures happen when bash expands the word, not when it
  parses the file, so no static check finds them: `bash -n` reports the same
  thing before and after the fix, and on a `.bats` file it means nothing anyway
  (`@test NAME {` is not bash). Verify by running the test itself under
  `/bin/bash`. Ubuntu and Windows run bash 5 and accept both shapes, so only the
  macOS leg catches this.

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

## Plugin scanner (HOL)

CI also runs the HOL plugin scanner on every push to main and every pull
request (`.github/workflows/hol-plugin-scanner.yml`). It fails on a high finding
or a score under 80. Score a `git archive HEAD` export, not the working
directory, where untracked session files read as findings:

```bash
git archive HEAD | tar -x -C "$dir"
pipx run plugin-scanner lint "$dir" --format text
```

## Plugin Evals (`claude plugin eval`)

`evals/` holds a nine-case suite for when the council comes up. Seven cases
cover the unprompted suggestion that `commands/ask.md` describes: five prompts
where a competing-options choice, a stuck debugging thread, or a build-vs-buy
call should earn a named `/claude-council:ask` suggestion alongside a real
answer, and two where it must not. The other two cover a provider named in the
request: `08-named-provider` ("check with grok") must start the council, and
`09-neg-provider-mention`, which only asks about a provider's API, must not.
Every case runs twice, with the plugin and without, so the headline number
is the delta between the two arms, not a pass rate. The graders read the final
message only, except the two `tool_used: Skill` graders in cases 08 and 09. The
grader text lives once, in `evals/_shared/`; each case's `graders/` holds
per-file symlinks to it, because the runner rejects a symlinked `graders/`
directory but follows links to individual files. Edit the shared file, not a
case copy. The per-case graders are the negatives' `answers-directly.md`,
`08`'s `convenes-council.md` and `09`'s `no-skill.md`.

```bash
env -u ANTHROPIC_API_KEY claude plugin eval . --ablation with-without --judge-model sonnet
```

`env -u ANTHROPIC_API_KEY` matters on a machine whose shell exports a key the API
rejects: the eval child inherits it and every turn fails authentication. Add
`--no-publish` to keep the HTML report local. One full run is three passes per
case and takes under twenty minutes; `--runs 1` is the calibration pass.

Under `with-without` the runner treats a `tool_used: Skill` grader as a sign
the plugin fired, not as part of the score, so case 08 scores nothing there.
Run it on its own to have it count:

```bash
env -u ANTHROPIC_API_KEY claude plugin eval . --case '08-*' --ablation none
```

Two things the sandbox cannot do here, so no suite tests them: reach an
external provider (keys are stripped, CLI seats cannot open sockets), and read
the plugin's own directory or the session transcript from the main agent.

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

   Alternatively, install `codex`, `agy` (Antigravity), `grok`, `kimi` and/or `cursor-agent` CLIs.
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
- [ ] Codex banner uses OpenAI's colour dot (●); Antigravity uses Gemini's

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
- [ ] Grok CLI banner uses Grok's colour dot (●)

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
- [ ] codex's slot is answered by openai, antigravity's by gemini, grok-cli's by grok and kimi-cli's by kimi (each marked as a fallback), all seeing the image
- [ ] `ollama`, selected directly, answers text-only, prefixed `(answered without the image)`

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

## Releasing

Bump version in `.claude-plugin/plugin.json` on every release:

```json
{
  "version": "YYYY.M.PATCH"
}
```

Format: `YYYY.M.PATCH` where PATCH increments with each release. Examples: `2026.1.1`, `2026.1.2`, `2026.2.1`.

**Always bump version when:**
- Changing command behavior
- Fixing bugs
- Updating formatting/output
- Any change users should pull

Release checklist:

1. Make changes
2. Test locally
3. Bump version in `.claude-plugin/plugin.json`
4. Commit and push
5. Users update via `/plugin update claude-council`

## Adding New Providers

See the `provider-integration` skill for guidance on adding new AI providers.
