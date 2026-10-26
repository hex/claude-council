# Architecture

## System Overview

```
                           USER REQUEST
                                |
                                v
                    +------------------------+
                    |   /claude-council:ask  |
                    |     (commands/ask.md)  |
                    +------------------------+
                                |
                                v
+------------------------------------------------------------------------+
|                        query-council.sh                                 |
|------------------------------------------------------------------------|
|  1. Parse Arguments (--providers, --roles, --debate, --file, etc.)     |
|  2. Discover Available Providers (API key OR CLI binary on PATH)       |
|  3. Apply CLI-prefers-API policy (codex shadows openai, etc.)          |
|  4. Resolve Roles (expand presets, assign to providers)                |
|  5. Build Context (--file content, auto-context detection)             |
+------------------------------------------------------------------------+
                                |
                                v
                    +------------------------+
                    |     ROUND 1: Query     |
                    +------------------------+
                                |
        +-------+-------+-------+-------+-------+-------+
        |       |       |       |       |       |       |
        v       v       v       v       v       v       v
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+ +---------+
   | gemini | |open | | grok | |perp | | kimi | |  codex    | | anti-   |
   |  .sh   | | .sh | |  .sh | |.sh  | |  .sh | |   .sh     | |grav .sh |
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+ +---------+
   (API)      (API)   (API)    (API)   (API)    (CLI)         (CLI)

         +------------+ +----------+ +----------+ +------------+ +----------+
         | openrouter | | grok-cli | | kimi-cli | | cursor-cli | |  ollama  |
         |    .sh     | |   .sh    | |   .sh    | |    .sh     | |   .sh    |
         +------------+ +----------+ +----------+ +------------+ +----------+
         (API, router)  (CLI)        (CLI)        (CLI)          (local)
        |               |               |               |
        |    +----------+----------+----------+        |
        +--->|      lib/cache.sh   |<---------+--------+
             | (check/store cache) |
             +---------------------+
                      |
        +-------------+-------------+
        |             |             |
        v             v             v
   [CACHE HIT]   [CACHE MISS]   [ERROR]
        |             |             |
        |             v             |
        |      +-------------+      |
        |      | lib/retry.sh|      |
        |      | (exp backoff|      |
        |      |  429/5xx)   |      |
        |      +-------------+      |
        |             |             |
        +------+------+------+------+
               |
               v
    +---------------------+
    | Collect R1 Results  |
    | {provider: {status, |
    |   response, cached, |
    |   role, model}}     |
    +---------------------+
               |
               +------ [if --debate] ------+
               |                           |
               v                           v
    +-------------------+       +------------------------+
    | Output R1 Results |       |   ROUND 2: Rebuttals   |
    +-------------------+       +------------------------+
                                           |
                        +------------------+------------------+
                        |                  |                  |
                        v                  v                  v
                  +-----------+      +-----------+      +-----------+
                  | Provider A|      | Provider B|      | Provider C|
                  | sees B,C  |      | sees A,C  |      | sees A,B  |
                  | responses |      | responses |      | responses |
                  +-----------+      +-----------+      +-----------+
                        |                  |                  |
                        +--------+---------+--------+---------+
                                 |
                                 v
                      +---------------------+
                      | Collect R2 Results  |
                      +---------------------+
                                 |
               +-----------------+
               |
               v
    +---------------------+
    |   Build JSON Output |
    |---------------------|
    | {                   |
    |   metadata: {...},  |
    |   round1: {...},    |
    |   round2: {...}     |  <-- only if debate
    | }                   |
    +---------------------+
               |
               v
    +---------------------+
    | format-output.sh    |
    | (terminal display)  |
    +---------------------+
               |
               v
    +---------------------+
    | lib/export.sh       |  <-- if --output
    | (markdown file)     |
    +---------------------+
```

## Component Details

### Provider Scripts (`scripts/providers/*.sh`)

Each provider follows a consistent interface:

```
INPUT:  --prompt-file <path>  the prompt; the orchestrator always uses this so a
                              large prompt stays off the argv (see ARG_MAX below)
        --image-file <path>   base64 image, passed only to vision-capable providers
        --image-mime <type>   the image's MIME type (pairs with --image-file)
        $1                    a literal prompt, for direct/manual invocation
OUTPUT: stdout = AI response text
EXIT:   0 = success, non-zero = failure (error to stderr)
        3 = the requested model is unavailable for this key/region — the
            orchestrator's model-fallback wrapper retries with a fallback
            model instead of surfacing the error (see Model Fallback below)
ENV:    scrubbed by provider_env_scrub (lib/providers.sh) in the subshell
        that execs the script: base, proxy/CA and Windows variables,
        COUNCIL_*, the provider's vendor prefixes and exact names (claude-cli
        keeps CLAUDE_CODE_OAUTH_TOKEN and CLAUDE_CONFIG_DIR; copilot-cli keeps
        COPILOT_GITHUB_TOKEN and COPILOT_HOME, not GH_TOKEN or GITHUB_TOKEN;
        opencode keeps OPENCODE_MODEL, OPENCODE_CONFIG and OPENCODE_CONFIG_DIR,
        no other OPENCODE_* name and no vendor key), and COUNCIL_PASS_ENV
        names stay; every other exported variable is unset. Nothing goes
        on an env -i argv, where ps would show a key.
```

Two flavors share the interface:

- **API providers** (`gemini`, `openai`, `grok`, `perplexity`, `kimi`,
  `openrouter`), gated on `{PROVIDER}_API_KEY`, talk to vendor APIs over HTTPS,
  charge per call. `openrouter` is a router rather than a vendor: it forwards to
  whichever upstream serves the id in `OPENROUTER_MODEL`, so its answer travels
  one hop further than the others' and its vendor is a runtime fact, not a
  static one. It is also the one script that can seat more than once: with
  `OPENROUTER_MODELS` set it is discovered as `openrouter-1..N`, one seat per
  listed model. The council's unit of identity is the seat — one header, one
  model label, one cache key, one role — so N models is N seats rather than one
  seat that varies. There is no `openrouter-N.sh`: `provider_script_path` routes
  every numbered seat back to the one script, and the orchestrator exports
  `COUNCIL_SEAT` so that script can resolve its own model instead of the
  default. `--list-default-models` reports the default set with each name paired
  to its model, which is the only way a caller outside the library can label a
  numbered seat — the name alone does not say which model it carries. Without that the three seats would post one model behind three
  headers each claiming a different one.
- **CLI providers** (`codex`, `antigravity`, `grok-cli`, `kimi-cli`, `cursor-cli`), gated on the
  binary being on `PATH`, use the user's existing CLI subscription auth, no per-call
  cost. When both an API and CLI sibling exist (codex+openai, antigravity+gemini,
  grok-cli+grok, kimi-cli+kimi), the orchestrator prefers the CLI by default; explicit
  `--providers` wins over the policy. If a CLI provider fails at query time, the
  council retries through its API sibling (when that key is set and the sibling
  is not already a selected provider) and marks the slot as a fallback: `fallback`
  names the sibling and `fallback_reason` holds the CLI's error text.
  `format-output.sh` prints the reason under the "fell back to … API" header in
  both rounds, and the pane row's state is `fallback` with the model shown as
  `<model> via <sibling> API`. A CLI that times out or fails reports one line,
  `Error from <cli> CLI: …`, built by `cli_failure_message` (lib/cli-stderr.sh):
  the timeout, or the last 500 bytes of the CLI's stderr with colour codes
  removed. `codex` runs with stdin from `/dev/null`, since `codex exec` reads a
  stdin that is not a terminal. `cursor-cli` has no sibling: the council has no Cursor API
  seat, so its failure is final. It is gated on `cursor-agent`, not the `agent`
  name the installer links beside it, because the grok CLI ships an `agent` too.
- **`claude-cli`** runs Claude Code itself (`claude -p`) on the user's claude.ai
  login. Discovery never seats it, unlike every other CLI provider: `claude` is
  on `PATH` for every user of this plugin, so it joins only when named in
  `--providers` or `COUNCIL_PROVIDERS`. It runs with `--safe-mode --setting-sources "" --tools ""
  --no-session-persistence`, so no CLAUDE.md, settings file, plugin, hook or MCP
  server reaches it; admin policy and an organisation's server-side instructions
  still do. Its scrubbed environment keeps `CLAUDE_CLI_*`,
  `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CONFIG_DIR` and drops `ANTHROPIC_API_KEY`,
  and `check-status.sh` probes `claude auth status` under that same environment.
  `get_model` reports `CLAUDE_CLI_MODEL` or `default`, never the model in
  `settings.json`, which the seat does not load. It has no API sibling, and the
  synthesis prompt counts its agreement as one voice, since Claude writes the
  synthesis too.
- **`copilot-cli`** runs the GitHub Copilot CLI (`copilot`) on the user's Copilot
  plan, with the prompt on stdin. Discovery never seats it either: each question
  spends a premium request, so it joins only when named. It runs with
  `--no-custom-instructions --disable-builtin-mcps --available-tools=none
  --no-auto-update`; an allowlist naming no real tool is what leaves the model
  with none, since an empty one reads as no allowlist. MCP servers in the user's
  `mcp-config.json` still start without reaching the model, and each run lands
  in the CLI's session history; no flag stops either. Its scrubbed environment
  keeps `COPILOT_CLI_*`, `COPILOT_GITHUB_TOKEN`, `COPILOT_HOME`, `GH_CONFIG_DIR`
  and the `GH_HOST`/`COPILOT_GH_HOST` pair by name, so
  `GH_TOKEN`, `GITHUB_TOKEN` and `COPILOT_ALLOW_ALL` (which would load the
  working directory's hooks) never reach it. A
  `gh` login still works, since copilot runs `gh` from `PATH`. `check-status.sh`
  checks only that the binary runs: copilot has no auth status command, and a
  prompt would spend a premium request. `get_model` reports `COPILOT_CLI_MODEL`
  or `default`, never the `settings.json` model, which a headless run did not
  use. It has no API sibling.
- **`opencode`** runs the OpenCode CLI (`opencode run --standalone --format
  json`) on whichever provider the user logged it in to, with the prompt on
  stdin. Discovery never seats it: each question bills that provider, so it
  joins only when named. `--standalone` gives the run a private server rather
  than the user's background service, which holds the environment and config
  it started with. An empty `OPENCODE_CONFIG_DIR`, with `OPENCODE_CONFIG`
  unset, keeps the user's global config, plugins and MCP servers out,
  `OPENCODE_CONFIG_PROJECT_DISABLE=1` (the name the CLI reads, so an inherited
  `0` would win) and `OPENCODE_DISABLE_PROJECT_CONFIG=1` (the name the CLI's docs
  give) keep the working directory's `opencode.json` and `AGENTS.md`
  out, all set by `opencode_blind_env`, which the status probe shares, and an
  inline `OPENCODE_CONFIG_CONTENT` that denies every permission sends the model
  no tool. The CLI saves every run in its session history and no flag stops
  that, so the exit trap deletes the run's session with `opencode session
  delete --standalone`; a delete that fails leaves it. A provider error exits 1 with stderr
  empty and arrives as an `error` event on stdout, which is what the seat
  reports. Its scrubbed environment keeps `OPENCODE_MODEL`, `OPENCODE_CONFIG`
  and `OPENCODE_CONFIG_DIR`, which `get_model` reads, and drops every other
  `OPENCODE_*` name and every vendor key, so it runs on the logins in
  `auth.json` under `XDG_DATA_HOME`. `check-status.sh` probes `opencode auth
  list --standalone` under that environment, the same empty config dir and
  project-disable pair, with `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT`
  unset, and reads `No authenticated
  integrations` as logged out. The empty config dir hides the user's model
  too, so `get_model` reads it before the seat swaps the dir in, and the seat
  passes it as `-m`: `OPENCODE_MODEL`, else `.model` from an `OPENCODE_CONFIG`
  file, else from `opencode.json` or `opencode.jsonc` in `OPENCODE_CONFIG_DIR`
  or `${XDG_CONFIG_HOME:-~/.config}/opencode`, else `default` and no `-m`.
  It has no API sibling.
- **`ollama`**, also gated on the binary being on `PATH`, but local and keyless:
  it shadows nothing, has no API sibling, and costs nothing per call.

**Seat isolation.** A CLI seat answers the prompt every other seat gets, so
none of the user's own agent setup may ride along: skills, plugins, hooks, MCP
servers, rules files, or the instruction files of the project the user asked
from. Each provider script sets this up itself, after the orchestrator's
environment scrub, so it binds the council run and the heads-up check alike.
The shared mechanics live in `lib/seat-isolation.sh`:
- Every CLI seat runs from `${TMPDIR:-/tmp}/claude-council-seat`, an empty
  directory outside any repository. It stays one fixed directory, not one per run,
  because cursor's `--trust`, grok's trusted folders, kimi's workspace list,
  agy's projects and copilot's trust list each record state per directory.
  The directory keeps a project's config files (`AGENTS.md`, `CLAUDE.md`,
  `CLAUDE.local.md`, `.cursor/mcp.json` and the like) from loading. It does not
  limit what a seat can read: codex's read-only sandbox, for one, reads any
  file by absolute path. A seat enters it with `seat_enter_scratch`, one line
  in each provider script.
- A seat whose CLI finds the user's config through `HOME` runs under a home of
  its own, `${TMPDIR:-/tmp}/claude-council-seat-home/<seat>`, also stable. It
  holds only links to where that CLI keeps its login; the CLI's caches and state
  stay there between runs. The seat links to the user's real home and never writes it.
- The seat creates both with mode 700. A symlink at either path, or a directory another
  user owns (a shared `/tmp` on Linux), stops the seat with an error naming
  the path. The seat keeps a link that already points right and replaces a wrong
  one; a real file or directory where a link goes is an error. Concurrent council
  runs build the same home safely.
- A seat under a home of its own would fall back to its CLI's built-in model,
  so where that model lives in the real home (cursor, antigravity) the script
  reads it first, through `get_model`, and passes it as the model flag only
  when the user's config names one or the `*_MODEL` override is set.
- On Windows (`uname -s` reads `MINGW*`, `MSYS*` or `CYGWIN*`) the seats keep the
  user's home: the native CLIs resolve it from `USERPROFILE`, so a `HOME` swap
  would change nothing. The scratch directory still applies.

Per seat:

| Seat | Runs under | No longer loads | Still loads |
|---|---|---|---|
| `cursor-cli` | A home holding `Library/Keychains` (macOS, where the login is a keychain item) or `.config/cursor` from `${XDG_CONFIG_HOME:-~/.config}` (Linux, the login file; read from the CLI's bundle, not run on Linux) | Skills from `~/.cursor`, `~/.claude` (plugins too), `~/.codex`, `~/.grok` and `~/.agents`; hooks from `~/.cursor/hooks.json` and Claude's `settings.json`; `~/.cursor/mcp.json`; the project's `.cursor` rules and MCP servers, `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` | Team commands from the Cursor dashboard (read from the CLI's bundle, not seen in a run) |
| `grok-cli` | A home holding `Library/Keychains` on macOS (grok signed in through it with no `auth.json`) and `.docker/run` when `~/.docker/run` exists (Docker Desktop points `/var/run/docker.sock` into it, and the read-only sandbox refuses to start on a socket link it cannot resolve); `GROK_HOME` on the user's `~/.grok`, `GROK_MEMORY=0`, `--cwd` the scratch directory | Claude plugins (their hooks, MCP servers and agents), `~/.agents` skills, cross-session memory, the project's `CLAUDE.md` and `AGENTS.md`; the `GROK_{CLAUDE,CURSOR}_*_ENABLED=0` variables already drop Claude's and Cursor's own hooks, rules, skills and MCP servers | `~/.grok`: its config, and the hooks in `~/.grok/hooks`. `GROK_CONFIG` only overlays a few tables (models, features, toolset) on that config, and grok 1.0.62 lists a `hooks` overlay as "set but ignored", so no setting drops them. The model comes from that config, so the seat passes no `-m` |
| `antigravity` | A home holding `Library/Keychains` on macOS; the user's home on Linux, where agy keeps its login in the OS keyring or in a file nobody has located yet | (macOS) `~/.gemini` rules, skills, MCP servers (`agy mcp list` lists none), plugins and saved conversations; everywhere, the project's `GEMINI.md`, `AGENTS.md` and `.agents` skills | (Linux) everything under `~/.gemini` |
| `opencode` | An empty home, `XDG_DATA_HOME` on the real one (`~/.local/share` when unset), where the login and session history live | The `~/.claude` and `~/.agents` config roots, with their skills, agents and `CLAUDE.md`, which the empty config dir leaves in | Nothing of the user's beyond the login |
| `codex` | A `CODEX_HOME` of its own per run (`lib/codex-home.sh`), removed with the run: the user's model and effort, a link to their `auth.json`, plugins, apps, hooks, memories and skills instructions off | Everything in `~/.codex` beyond those, and the project's `AGENTS.md` and skills | The login. A custom `model_provider` or a `profile`, or no login at all, stops the seat with the reason, as in the heads-up check. A login kept only in the system keyring (`cli_auth_credentials_store` `keyring` or `auto`, no `auth.json`, no `CODEX_API_KEY` or `OPENAI_API_KEY`) cannot follow: codex 0.164.0 names the keyring entry after a hash of the `CODEX_HOME` path. That seat runs under the user's own codex home, as before isolation, and prints a `note: codex: login is in the system keyring ...` line on stderr, which the council shows above the answer and the stop-gate drops. The heads-up check refuses that case |
| `claude-cli` | The user's home, `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1` | The git status block and commit and PR instructions a repository would add | Admin policy and an organisation's server-side instructions, as before |
| `kimi-cli` | The user's home | A project's `.mcp.json` servers (its agent file already keeps `AGENTS.md`, skills and the directory listing out) | The hooks in `~/.kimi-code/config.toml`, which also holds the login |
| `copilot-cli` | The user's home | The project's skills, hooks and `.github` files | Skills under `~/.copilot` and `~/.agents`, and servers in the user's `mcp-config.json` (started, never handed to the model) |

Environment-based configuration:
- `{PROVIDER}_API_KEY` - Required authentication for API providers
- `{PROVIDER}_MODEL` - Model override (also applies to CLI providers via
  `CODEX_MODEL` / `ANTIGRAVITY_MODEL` / `GROK_CLI_MODEL` / `KIMI_CLI_MODEL` / `CURSOR_CLI_MODEL` /
  `CLAUDE_CLI_MODEL` / `COPILOT_CLI_MODEL` / `OPENCODE_MODEL`)
- `COUNCIL_MAX_TOKENS` - Response length limit (API providers only; `ollama`
  raises its own base to 4096)
- `COUNCIL_DEBUG` - Enable verbose logging

### Vision / Image Input (`--image`)

A single image can be attached with `--image=path` (png/jpg/jpeg/webp/gif,
≤10 MB). `query-council.sh` validates it once at the edge, base64-encodes it to a
temp file, and folds only its SHA-256 into the cache key (`COUNCIL_IMAGE_HASH`) —
the bytes never enter the prompt string.

Per-provider disposition when an image is attached:
- **gemini, openai, grok, perplexity, kimi** (vision-capable) receive the image —
  gemini as an `inlineData` part, openai as `input_image` (Responses API) or
  `image_url` (Chat Completions), grok as an OpenAI-compatible `image_url`
  data-URI on its `/chat/completions` endpoint, perplexity as an `input_image`
  part on the Agent API's `/v1/agent`.
- **codex, antigravity, grok-cli, kimi-cli** (CLI, cannot accept an image) route
  to their vision API sibling — codex→openai, antigravity→gemini, grok-cli→grok,
  kimi-cli→kimi — with the image. The route is taken only when the sibling is
  itself vision-capable, its key is set and it is not already a selected
  provider; otherwise the CLI answers text-only, prefixed with
  `(answered without the image)`. **cursor-cli**, **claude-cli**,
  **copilot-cli** and **opencode** have no sibling and answer text-only.
- **openrouter** accepts an image on its curated default, which is
  vision-capable. An `OPENROUTER_MODEL` override names one of hundreds of routed
  models whose modalities are not knowable from here, so it is treated as
  text-only until `OPENROUTER_VISION=1` says otherwise.
- **kimi** reads images on its default model. `kimi.sh` has always built the
  OpenAI-shaped `image_url` payload; only the capability table said otherwise,
  which routed images away from a provider that could read them. `kimi-k2` and
  its variants are text-only while `k2.5` and later are not, so a `KIMI_MODEL`
  override opts in with `KIMI_VISION=1`.
- **ollama** answers text-only, prefixed with `(answered without the image)`.

Privacy invariant: only the image's SHA-256 keys the cache. The base64 lives
solely in a temp file passed to providers; it is never written to cache entries
or the saved `council-*.md` transcripts.

### Cache Layer (`scripts/lib/cache.sh`)

```
Cache Key = SHA256("provider:model:verbosity:max_tokens:image_sha256:prompt")
  (verbosity, token cap, and any attached-image hash all bust the cache, so a
   --verbosity or --image change re-queries instead of reusing a stale answer)

cache_get(key) -> response | empty
cache_set(key, provider, model, prompt, response)
cache_clear()

Storage: $COUNCIL_CACHE_DIR/{key}.json
TTL: $COUNCIL_CACHE_TTL seconds (default 3600)
```

### Cancelling a seat (`scripts/query-council.sh`, `mods/council-pane`)

While round 1's seats are out (the first pass and the retry), `await_seats`
polls them in 0.2 s ticks (bash 3.2 has no `wait -n`) and looks for
`cancel/<provider>` in the pane's watch dir, which the mod pane writes when
its cancel button is pressed (its band's cancel all writes one per querying
seat); with no pane the seats are waited on. On a
marker, the seat's whole process tree (`process_tree`, lib/deadline.sh) is
listed once and sent TERM in one `kill`, parent first, so neither a CLI's own
retry nor the API-sibling fallback can start, and KILL five seconds later for
whatever trapped or ignored it; the slot becomes an error reading `cancelled
from the pane` (its role kept), the seat's error file is removed, a
`cancelled` status line is logged, and only then is the marker removed, so
the pane draws the seat as cancelling (a bare grey track) meanwhile. A press that finds the
seat's slot already on disk, whatever it says, is spent: the seat's work is
done. Round 1 removes its seats' markers before launching, so a press that
landed after the round collected is spent too. A cancelled seat is not
offered for retry, sits out round 2 and gets no rebuttal block from
`format-output.sh`; round 2 logs no pane rows, so it has no cancel and is
waited on. The result JSON and the synthesis see it as an error like any
other.

### Retrying a seat from its row

The same loop looks for `retry/<provider>`, which the mod pane writes when
the `retry` button on a seat's error row is pressed. A seat that ended in an
error of its own keeps its place in the loop with no job, and the run names
it in `retriable/`, so the pane offers the button only while a press can be
honoured; the name goes at the relaunch, and every parked seat's name goes
when the loop returns. The launch is the one `launch_seat` the round and the
band's retry use, so the seat gets exactly the query it failed, with its
role, and it spends any marker from before. `launch_seat` records every
launch (`LAUNCHES`): a seat launched twice has had its one retry, from its
row or from the band, so it is neither parked again nor offered by the band.
The pane draws a pressed seat as `retrying` while its name is in both
folders, and a plain error row again once the run withdrew the offer. The
loop only runs while some seat is live, so a press that lands once the last
seat has ended is not honoured: the band's offer covers that case.

### Retry Logic (`scripts/lib/retry.sh`)

```
curl_with_retry():
  - Retries on: 429 (rate limit), 5xx (server error)
  - Fails fast on: timeout, other 4xx (client error)
  - Backoff: exponential (1s, 2s, 4s...)
  - Max retries: $COUNCIL_MAX_RETRIES (default 3)

curl_secret_config(header...):
  - writes the auth header(s) to a mode-600 temp file and echoes its path
  - callers pass it via `curl --config <file>` so API keys never ride the
    process argv (ps-visible) or a URL query string
```

### Model Fallback (`scripts/lib/retry.sh`, `scripts/lib/model_fallback.sh`)

```
is_model_unavailable_error(body):        # retry.sh
  - true only for a 403/404, or a 400 whose message names the model
  - excludes 401/429/5xx: no other model fixes those
  - reads .http_status, stamped onto every >=400 body by ensure_error_body
    (handles xAI's bare-string .error as well as the usual .error.message)

model_fallback_for(provider) -> model    # model_fallback.sh
  - one verified fallback per API provider (openai, grok, gemini, perplexity,
    kimi, and the single openrouter seat)
  - empty for CLI providers, which degrade to their API sibling instead, for
    ollama, whose models are whatever is installed locally, and for numbered
    openrouter-N seats, which run exactly the model their roster entry names

model_unavailable_cached/remember(provider, model, key_hash):
  - TTL-cached "unavailable" verdict, scoped to provider + preferred model + key
  - written only once the fallback model has actually answered
  - independent of the response cache; tunable via COUNCIL_AVAILABILITY_TTL
```

`query-council.sh`'s `run_provider_with_model_fallback` wraps a provider
script: a preferred-model exit 3 (see Provider Scripts below), or a cached
verdict, retries once with the fallback. The substitution is reported on the
response header, on stderr, and folded into the synthesis prompt.

### The Empty Answer (every API provider, plus cursor-cli, claude-cli, copilot-cli, opencode, kimi-cli and ollama)

A provider that returns no visible text is an error even when HTTP says the
call succeeded, so each of these seats asks whether the answer holds any
character that is not whitespace rather than testing `-z`: the council would otherwise cache a model that answers with
a single space and weigh it in the synthesis like any other vote.

This case never reaches the machinery above. `ensure_error_body` stamps a message
and `.http_status` onto every body of 400 or worse, and `retry_error_body`
covers timeout and network, so an empty answer that reaches the error branch
with no top-level `.error` arrived as a 2xx. Three unrelated failures look
identical there, and each seat names them from its own response shape rather
than printing one word for all three:

```
gemini.sh:      .promptFeedback.blockReason  -> "prompt blocked (X)"
                .candidates[0].finishReason  -> "empty response (finishReason: X,
                                                 thoughts tokens: N/M)"

openrouter.sh:  .choices[0].error            -> "provider error (502): ..."
                                                (a mid-generation upstream
                                                failure; OpenRouter answers 200
                                                and puts the error on the choice)
                .choices[0].finish_reason    -> "empty response (finish_reason: X,
                                                 native: Y, reasoning tokens: N/M,
                                                 reasoning chars: K)"
```

`reasoning chars` counts an answer the upstream left in `.message.reasoning`
instead of `.content`; `finish_reason: length` with reasoning tokens near the
completion total means the model spent `max_tokens` thinking, which the
separate `reasoning.max_tokens` budget exists to prevent. Under `COUNCIL_DEBUG`,
`openrouter.sh` also dumps the raw body on this branch as the catch-all for a
shape not listed here.

Every `.error` read branches on `(.error | type)` before indexing. A bare-string
`.error` (xAI at the top level, some upstreams on the choice) raises in jq
rather than yielding null, `//` does not catch a raise, and jq's postfix `?`
binds only to the term before it, so `.error?.message` still raises. Under
`set -eo pipefail` that kills the script before it prints anything at all.

### Role System (`scripts/lib/roles.sh`)

```
config/roles.json defines:
  - Individual roles (security, performance, etc.)
  - Role presets (balanced, security-focused, etc.)

Role injection prepends instructions to prompt:
  "As a [ROLE], focus on [CONCERNS]..."

Assignment: a bare --roles list is positional (role[i] -> provider[i] in
discovery order); provider=role pairs bind by name. The two forms cannot mix,
and a pair naming an absent provider, or one provider twice, is refused.
```

### Prompt Templates (`scripts/lib/prompts.sh`, `prompts/*.md`)

```
load_prompt_template(name):  reads prompts/<name>.md
interpolate_template(t, KEY=VALUE...): fills {{KEY}} slots
  - unfilled slots collapse to empty
Templates: role-injection, synthesis (calibration rules),
           stop-review-gate (ALLOW:/BLOCK: first-line contract)
```

### Job Store (`scripts/lib/jobs.sh`)

```
State dir: $COUNCIL_JOBS_DIR, else
           $CLAUDE_PLUGIN_DATA/jobs/<cwd-hash>, else tmp
Per job:   <id>.json (status, pid, outfile, timestamps) + <id>.log
Lifecycle: queued -> running -> completed | failed | cancelled
  - run-council.sh --async re-execs itself detached as --job-worker=<id>
  - worker exit trap converts crashes to failed
  - --result echoes the outfile path (exit 2 while in flight)
  - --cancel marks cancelled first, then kills the process tree
  - jobs_prune drops oldest terminal jobs beyond COUNCIL_MAX_JOBS
```

### Output Contract (`schemas/`, `scripts/validate-analysis.sh`)

```
schemas/agent-analysis.schema.json is the deep-execution analyst's
reply contract. The workflow that runs the analysts enforces it as
their structured output: a reply that does not match is sent back
to the analyst, and one that never arrives is absent from the
result, never silently dropped. validate-analysis.sh mirrors the
schema executably with jq, listing every violation; the bats suite
keeps the two in sync.
```

### Heads-up side-check (`scripts/heads-up.sh`, `mods/council-pane/hooks/heads-up.ts`)

```
Opt-in via .claude/council-heads-up.json, read by the mod at each
turn.step of the main loop. heads-up.ts decides (cadence from the
step's index in its turn, backoff, one note per turn); pane.tsx forks
heads-up.sh --run-dir --session --seat --avoid-file [--model], which
returns its worker's pid at once. The worker: session-transcript.sh ->
transcript-digest.sh --tool-results (a Write or Edit slot carries
the text it wrote under a heading naming the file; window: the last N prompts,
typed or submitted by cs/cs-rotate, only typed ones shown; a
transcript with none is kind skipped: nobody
to warn, no seat asked, nothing leaves the machine) ->
prompts/heads-up.md ->
the one seat (codex: codex exec --output-schema from the run dir,
under a CODEX_HOME there holding the model, the effort and a link
to the user's auth.json when there is one, gated on turn.completed; others: providers/<seat>.sh, first-line NONE or
NOTE:, TAG:, TOPIC:, TITLE: and POINT: lines) -> result.json
{kind: note|none|skipped|failed, ...} (temp name, mv) -> .done.
The pane polls .done, settles $.state (claude-council.headsUp),
draws the band; a skipped check is logged once per reason, draws
nothing and counts no outcome; the checks shown by /heads-up status
are the outcomes added up, never stored. Each seat outcome may carry
usage {input, cached, output, reasoning}, from codex's turn.completed
or the COUNCIL_USAGE_FILE a provider writes (lib/usage.sh); the
totals live in $.store under heads-up-tokens. Seen/known topics
live in $.store under heads-up.
Seat names pass provider_allowlisted (lib/providers.sh), the one
list, derived from providers/<name>.sh; the stop gate uses it too.
```

### Stop Gate (`hooks/hooks.json`, `scripts/stop-review-gate.sh`)

```
Stop hook, opt-in via .claude/council-stop-gate.json.
Reviews `git diff HEAD` through one provider using the
stop-review-gate prompt; blocks only on first-line BLOCK:.
Loop guards: stop_hook_active check + per-session block
counter capped at max_iterations. Reviewer failure => allow.
```

## Data Flow

### Standard Query

```
User -> parse args -> discover providers -> check cache
                                               |
                    +-----------+--------------+
                    |           |
               [HIT]         [MISS]
                 |              |
                 |         query API -> store cache
                 |              |
                 +------+-------+
                        |
                    format output -> display
```

### Debate Mode

```
User -> Round 1 (parallel queries)
             |
        collect responses
             |
        Round 2 (each sees others' R1)
             |
        collect rebuttals
             |
        combined output with debate insights
```

### Agent-Enhanced Mode (--agents)

```
User -> ask.md detects --agents flag (or NL trigger)
             |
        one Workflow: N analyst agents in parallel
        (schema-enforced structured output, resumable)
             |
    +--------+--------+--------+--------+
    |        |        |        |        |
    v        v        v        v        v
 Analyst: Analyst: Analyst: Analyst:  ...
 Gemini   OpenAI   Grok     Perplexity
    |        |        |        |
    | Each analyst independently:
    | 1. Runs provider curl script
    | 2. Evaluates response quality
    | 3. Retries with reformulated prompt if poor
    | 4. Asks follow-up questions for depth
    | 5. Returns structured analysis:
    |    - Key recommendations
    |    - Confidence level
    |    - Unique perspective
    |    - Blind spots
    |        |        |        |
    +--------+--------+--------+
             |
        orchestrator collects all analyses
             |
        enhanced synthesis:
        - confidence-weighted consensus
        - cross-provider blind spot analysis
        - divergence with context
             |
        save to council-cache
```

Key difference from standard mode: the analysts do meaningful analytical
work beyond the API call, pre-digesting each response before synthesis. The
Workflow returns validated objects, so no analysis passes through the
orchestrator's context as text to be pasted and checked; a killed run resumes
with the finished analysts served from cache.

### Local Council Mode (--local / no providers)

```
User -> ask.md (--local, or accepts the offer when no providers found)
             |
        skill asks how many members (unless --roles given); local_council_roles
        resolves that many from a diverse order (default 4, up to 8)
             |
        spawn one general-purpose subagent per role (background, blind to each other)
        (Agent fan-out, not a Workflow: members return display-verbatim markdown
         with nothing to enforce, and this is the no-keys path, so it keeps
         the smaller tool requirement)
             |
    +--------+--------+--------+
    |        |        |        |
    v        v        v        v
 Member:  Member:  Member:  Member:
 devil    simplicity security scalability
    |        |        |        |
    | Each member (Claude, general-purpose subagent):
    | - Answers the role-injected question on its own
    | - Returns Position / Key points / Risks & blind spots / Confidence
    |        |        |
    +--------+--------+
             |
        orchestrator collects all perspectives
             |
        honest synthesis (angles, NOT consensus):
        - shared starting points to pressure-test
        - genuine tensions between roles
        - cross-member blind spots
             |
        save to council-cache
```

Key difference from agent mode: members do **not** call any provider — each one
*is* the answerer (Claude under a role). Because they share a model, the
synthesis is framed around independent angles and blind-spot coverage, never as
cross-vendor consensus. This is the zero-provider fallback so the plugin is
usable on a Claude subscription alone.

## File Structure

```
claude-council/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── .github/
│   ├── dependabot.yml           # Weekly bumps for the pinned GitHub Actions
│   └── workflows/
│       ├── hol-plugin-scanner.yml  # HOL plugin scanner; fails on a high finding or a score under 80
│       ├── stale.yml            # Closes idle issues and PRs
│       └── tests.yml            # bats on ubuntu, macos and 4 windows shards; shellcheck blocks a merge
├── agents/
│   └── council-advisor.md       # Proactive suggestions
├── assets/
│   ├── banner.svg               # Plugin name and description
│   ├── council-run.svg          # Captured run inside Claude Code
│   ├── heads-up.svg             # Captured note and unsent draft
│   ├── tmux-pane.svg            # Captured streaming tmux pane
│   ├── capture/                 # Capture scripts, converter, raw frames, provenance
│   └── icon.png                 # 512x512 listing icon, named by plugin.json's icon
├── commands/
│   ├── advise.md                # /advise — put this conversation to the council
│   ├── ask.md                   # Main /ask command
│   ├── result.md                # /result — fetch/list/cancel background jobs
│   └── status.md                # /status command
├── config/
│   └── roles.json               # Role definitions
├── docs/
│   ├── ARCHITECTURE.md          # This file
│   ├── REFERENCE.md             # Every flag, provider, variable, default and limit
│   └── USAGE.md                 # Each workflow, with examples
├── evals/                       # `claude plugin eval` cases: prompt.md + graders/ per case
│   ├── .gitignore               # Keeps eval run output (results/) out of the repo
│   └── _shared/                 # Grader text the cases link to, file by file
├── hooks/
│   └── hooks.json               # Stop hook registration (stop gate) and the council-pane module
├── mods/
│   └── council-pane/            # Experimental Claude Code mod: the pane drawn inside Claude Code
│       ├── README.md            # Settings, watch-dir files, limits, the council tool, the heads-up
│       ├── DESIGN.md            # Colour and layout rules; every colour lives in hooks/theme.ts
│       ├── HEADS-UP.md          # The heads-up side-check's design and its implementation record
│       ├── types/index.d.ts     # The $.state contract plugin.json names under "types"
│       ├── tsconfig.json        # Type check against the locally generated plugin types
│       ├── hooks/               # pane.tsx wires the engine; the other modules are pure
│       └── tests/               # bun tests for the pure modules
├── prompts/
│   ├── role-injection.md        # {{VAR}} template for role-wrapped prompts
│   ├── synthesis.md             # Synthesis structure + calibration rules
│   ├── stop-review-gate.md      # Stop-gate reviewer contract
│   ├── heads-up.md              # Side-check prompt: one finding or NONE, {{AVOID}} and {{DIGEST}} slots
│   └── kimi-cli-agent.md        # No-tools agent definition passed to the kimi CLI
├── schemas/
│   └── agent-analysis.schema.json  # Deep-execution analyst reply contract
├── scripts/
│   ├── query-council.sh         # Main orchestrator
│   ├── run-council.sh           # Query + format pipeline, sync and --async
│   ├── format-output.sh         # Terminal formatter
│   ├── check-status.sh          # Provider health check
│   ├── stop-review-gate.sh      # Opt-in Stop hook reviewer
│   ├── heads-up.sh              # Detached side-check runner: digest, one seat, result.json
│   ├── heads-up.schema.json     # Codex answer contract for the side-check, passed as --output-schema
│   ├── seat-info.sh             # The pane's seat questions: discover, a seat's model, allowlisted
│   ├── session-transcript.sh    # Conversation id to transcript path, refusing ambiguity
│   ├── transcript-digest.sh     # Session JSONL to a markdown digest for /advise and the side-check
│   ├── validate-analysis.sh     # Executable mirror of the agent-analysis schema (test suite)
│   ├── release.sh               # Version bump and tagging
│   ├── dev/
│   │   └── demo-pane.sh         # Visual test harness for the streaming pane
│   ├── providers/
│   │   ├── gemini.sh            # API
│   │   ├── openai.sh            # API
│   │   ├── grok.sh              # API
│   │   ├── perplexity.sh        # API
│   │   ├── kimi.sh              # API (Moonshot)
│   │   ├── openrouter.sh        # API (router; any model on openrouter.ai)
│   │   ├── codex.sh             # CLI (subscription auth, shadows openai)
│   │   ├── antigravity.sh       # CLI (subscription auth, shadows gemini)
│   │   ├── grok-cli.sh          # CLI (subscription auth, shadows grok)
│   │   ├── kimi-cli.sh          # CLI (subscription auth, shadows kimi)
│   │   ├── cursor-cli.sh        # CLI (subscription auth, no API sibling)
│   │   ├── claude-cli.sh        # CLI (Claude subscription, seated only when named)
│   │   ├── copilot-cli.sh       # CLI (Copilot plan, seated only when named)
│   │   ├── opencode.sh          # CLI (the user's own provider login, seated only when named)
│   │   └── ollama.sh            # Local (no key, no sibling)
│   └── lib/
│       ├── cache.sh             # Caching utilities
│       ├── cli-stderr.sh        # The error line a CLI provider reports on a timeout or failure (the end of its stderr, colour codes removed)
│       ├── clock.sh             # Millisecond clock shared by the scripts that time a seat or a run
│       ├── count.sh             # require_count: a count argument must be a whole number of 1 or more, read base-10
│       ├── codex-home.sh        # The CODEX_HOME a codex seat runs under, for the council seat and the heads-up check
│       ├── deadline.sh          # Wall-clock bound for a command (no GNU timeout on macOS or Git Bash) + process-tree signalling
│       ├── display.sh           # Streaming tmux pane + iTerm2 lifecycle
│       ├── export.sh            # Markdown export
│       ├── hash.sh              # Portable SHA-256 helper (shasum / sha256sum)
│       ├── jobs.sh              # Background job store
│       ├── keys.sh              # API key resolution (XAI_API_KEY ↔ GROK_API_KEY)
│       ├── model_fallback.sh    # Fallback model per provider + TTL-cached unavailable verdicts
│       ├── pane-watcher.sh      # Runs in the tmux pane: streams status + rendered responses, re-renders them all on resize, offers a retry of failed providers
│       ├── prompts.sh           # Template loading + {{VAR}} interpolation
│       ├── providers.sh         # Discovery, CLI-prefers-API policy, vendor display, model resolution from each CLI's own config
│       ├── render.pl            # Dependency-free markdown renderer (perl fallback)
│       ├── render.py            # Council-tuned Rich markdown renderer
│       ├── retry.sh             # Retry with backoff + off-argv secret config
│       ├── roles.sh             # Role management
│       ├── seat-isolation.sh    # The scratch working directory and the home of its own each CLI seat runs under
│       ├── tokens.sh            # Reasoning-model token-cap bumping
│       ├── usage.sh             # emit_usage: a seat call's tokens, {input, cached, output, reasoning}, to COUNCIL_USAGE_FILE
│       └── verbosity.sh         # Shared system prompt, inline-answer guard, verbosity directives
├── skills/
│   ├── council-execution/
│   │   └── SKILL.md             # Standard query execution
│   ├── deep-execution/
│   │   ├── SKILL.md             # Agent-enhanced execution (--agents)
│   │   └── agent-prompt-template.md  # Analyst prompt: query, judge, follow up, structured analysis
│   ├── local-council-execution/
│   │   ├── SKILL.md             # Local Claude-only council (--local / no providers)
│   │   └── agent-prompt-template.md  # Council-member prompt template
│   └── provider-integration/
│       ├── SKILL.md             # Adding providers guide
│       └── api-patterns.md      # API integration patterns
├── tests/
│   ├── run_tests.sh             # Test runner
│   ├── shards/                  # Which bats files each Windows CI shard runs
│   ├── test_helper.bash         # Shared test utilities
│   ├── e2e/                     # Run by hand, not by run_tests.sh; each script has a recorded passing run
│   │   ├── heads-up-e2e.sh      # The heads-up side-check in a real Claude Code, driven through tmux, with the fake codex as the seat
│   │   ├── heads-up-e2e.expected.txt
│   │   ├── heads-up-codex-e2e.sh  # One real check against the logged-in codex on a session you name; sends that session off the machine
│   ├── fixtures/
│   │   ├── fake-clis.bash       # Fake codex/agy/grok/kimi/cursor-agent/claude/copilot/opencode/ollama binaries on PATH
│   │   └── status-fakes.bash    # Recording curl + jq for the check-status tests
│   ├── agent-analysis.bats
│   ├── argmax.bats              # ARG_MAX marshalling round-trip guards
│   ├── cache.bats
│   ├── check-status.bats
│   ├── check-status-probe.bats  # The probes themselves: endpoints, --max-time, keys off the argv
│   ├── cli-providers.bats       # CLI providers (codex, antigravity, grok-cli, kimi-cli, cursor-cli, claude-cli, copilot-cli, opencode, ollama)
│   ├── deadline.bats            # run_with_deadline: stdin passthrough, own status, 143 at the deadline
│   ├── display.bats
│   ├── export.bats
│   ├── fake-clis.bats
│   ├── format-output.bats
│   ├── heads-up.bats            # heads-up.sh with the fake CLIs: one seat, result.json, deadlines, refusals before the fork
│   ├── image.bats               # Vision / --image routing + privacy guards
│   ├── jobs.bats
│   ├── keys.bats
│   ├── model_fallback.bats      # Classifier, fallback pairs, verdict cache, gated real-API test
│   ├── pane-watcher.bats
│   ├── prompts.bats
│   ├── providers.bats           # API provider payloads + secret hygiene
│   ├── release.bats
│   ├── retry.bats
│   ├── roles.bats
│   ├── router-seats.bats        # OPENROUTER_MODELS -> openrouter-1..N, one script, many seats
│   ├── seat-info.bats           # The pane's seat questions: discover, model, allowlisted exit codes, usage
│   ├── session-transcript.bats  # Session id to transcript path
│   ├── shards.bats              # Every bats file is named in a Windows shard list
│   ├── stop-gate.bats
│   ├── theme.bats
│   ├── tmpdir.bats              # Temp files honour TMPDIR
│   ├── tokens.bats
│   ├── transcript-digest.bats   # Session JSONL to the markdown digest /advise sends
│   ├── verbosity.bats
│   └── query-council.bats
├── .gitattributes
├── .gitignore
├── .shellcheckrc               # Points shellcheck at the sourced libs
├── CHANGELOG.md
├── LICENSE
├── README.md
├── SECURITY.md
├── TESTING.md
└── tsconfig.json               # Extends the generated plugin types' tsconfig under .claude-plugin/types
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_API_KEY` | - | Google AI Studio key |
| `GEMINI_THINKING_BUDGET` | - | Cap on Gemini's internal reasoning tokens (`thinkingConfig.thinkingBudget`); unset, the model decides. Keeps room for the visible answer when reasoning would consume the whole `maxOutputTokens` and return an empty 200 |
| `OPENAI_API_KEY` | - | OpenAI API key |
| `XAI_API_KEY` | - | xAI API key (preferred) |
| `GROK_API_KEY` | - | xAI API key (legacy alias; `XAI_API_KEY` wins if both set) |
| `PERPLEXITY_API_KEY` | - | Perplexity API key |
| `OPENROUTER_API_KEY` | - | OpenRouter API key |
| `KIMI_API_KEY` | - | Moonshot/Kimi API key; the only var that makes `kimi` discoverable |
| `MOONSHOT_API_KEY` | - | Read as a fallback by `kimi.sh`, but does not satisfy discovery |
| `{PROVIDER}_MODEL` | varies | Model override (API providers) |
| `CODEX_MODEL` | (unset) | Model passed to `codex exec -m`, only when set (else the codex CLI's own configured model) |
| `ANTIGRAVITY_MODEL` | (unset) | Model passed to `agy --model` (else the model selected in the Antigravity app, read from the real home's settings and passed the same way; with neither, no `--model`) |
| `GROK_CLI_MODEL` | (unset) | Model passed to `grok -m`, only when set (else the grok CLI's own default) |
| `KIMI_CLI_MODEL` | (unset) | Model passed to `kimi -m`, only when set (else the kimi CLI's own configured model) |
| `CURSOR_CLI_MODEL` | (unset) | Model passed to `cursor-agent --model` (else the model picked in the CLI, read from the real home's `cli-config.json` and passed the same way; with neither, no `--model`, since a free plan rejects every named model). The CLI writes the passed model as its picked model into the `.cursor/cli-config.json` of the home it runs under, which is the seat's own on macOS and Linux and the user's on Windows, even when the plan rejects it |
| `CLAUDE_CLI_MODEL` | (unset) | Model passed to `claude --model`, only when set (else the account's default model; the seat does not read `settings.json`) |
| `COPILOT_CLI_MODEL` | (unset) | Model passed to `copilot --model`, only when set (else the CLI's automatic pick, which can change per question; a plan can reject every named model) |
| `OPENCODE_MODEL` | (unset) | `provider/model` passed to `opencode run -m` (else the `model` from the user's `opencode.json`; with neither, no `-m` and the CLI's built-in default) |
| `OPENROUTER_MODEL` | `anthropic/claude-fable-5.1` | Any id from openrouter.ai/models (single seat) |
| `OPENROUTER_MODELS` | (unset) | Comma-separated ids; each becomes a seat `openrouter-N`, replacing the single seat |
| `OPENROUTER_<N>_MODEL` | (unset) | Overrides roster seat N's entry, as `<PROVIDER>_MODEL` does for any provider; the exit-3 degrade path sets it so a roster entry never resends the model that just failed |
| `COUNCIL_SEAT` | (set by the orchestrator) | Which seat a provider script is running as; only the router reads it |
| `OPENROUTER_REASONING_TOKENS` | 8000 | Thinking budget sent as `reasoning.max_tokens` on every routed request; `0` sends none and the model decides. Bounds the thinking alone, where `max_tokens` bounds thinking plus answer: a routed model that would think for 20k tokens on a long prompt otherwise outlasts `COUNCIL_TIMEOUT`. Effort-only upstreams map the number to an effort level; adaptive models ignore it |
| `OPENROUTER_VISION` | (unset) | Set to `1` to declare an `OPENROUTER_MODEL` override image-capable |
| `KIMI_VISION` | (unset) | Set to `1` to declare a `KIMI_MODEL` override image-capable |
| `COUNCIL_AGENT_MODEL` | `sonnet` | Model the `--agents` ANALYSTS run on (`sonnet`/`opus`/`haiku`/`fable`); not a provider model |
| `OLLAMA_MODEL` | (unset) | Local model id; when unset, whichever model `ollama list` shows first |
| `OLLAMA_HOST` | http://localhost:11434 | Ollama server, following Ollama's own convention |
| `COUNCIL_PROVIDERS` | (unset) | Comma-separated roster queried by default, ahead of discovery; `--providers` still wins per call |
| `COUNCIL_ARGV_LIMIT` | 24000 | Prompt length past which `antigravity` writes the question to a file and points `agy` at it, since Windows caps a command line at 32k |
| `COUNCIL_MAX_TOKENS` | 2048 | Max response tokens (`ollama` uses a 4096 base) |
| `COUNCIL_MAX_RETRIES` | 3 | Retry attempts |
| `COUNCIL_RETRY_DELAY` | 1 | Initial retry delay (s) |
| `COUNCIL_TIMEOUT` | 300 | Per-request timeout for API providers (s); set explicitly it also overrides the CLI bound |
| `COUNCIL_CLI_TIMEOUT` | 1200 | Bound for a CLI provider run (s). Higher because CLI providers get one attempt while API providers retry, so a shared value would be `COUNCIL_MAX_RETRIES + 1` times stricter for a CLI |
| `COUNCIL_CACHE_DIR` | .claude/council-cache | Cache location |
| `COUNCIL_CACHE_TTL` | 3600 | Cache lifetime (s) |
| `COUNCIL_AVAILABILITY_TTL` | 86400 | Model-unavailable verdict cache lifetime (s); `0` re-checks every query |
| `COUNCIL_JOBS_DIR` | per-workspace under `$CLAUDE_PLUGIN_DATA` | Background job state location |
| `COUNCIL_MAX_JOBS` | 20 | Terminal-status jobs kept before pruning |
| `COUNCIL_PROMPTS_DIR` | prompts/ | Prompt template location |
| `COUNCIL_USAGE_FILE` | - | A file a provider writes the tokens its call used to, as `{input, cached, output, reasoning}`, when the vendor reported them. The heads-up runner sets it per check; nothing else does |
| `COUNCIL_PASS_ENV` | - | Comma-separated variable names every provider receives on top of its scrubbed environment (see `provider_env_scrub`) |
| `COUNCIL_DEBUG` | - | Enable debug output |
| `COUNCIL_NO_PANE` | - | Set to `1` to disable the streaming tmux pane globally |
| `COUNCIL_MOD_PANE_DIR` | - | An existing directory a run writes its watch dir into, opening no tmux pane. Only the council-pane mod sets it; `COUNCIL_NO_PANE` still wins |
| `/config` rows `pane_host`, `collapse_when_done`, `wake_on_async_done`, `council_tool`, `heads_up` | ask, on, off, on, off | The council-pane mod's settings, read from the plugin's `userConfig`; `mods/council-pane/README.md` describes each |
| `COUNCIL_HEADS_UP_SEAT_SECONDS` | 60 | The heads-up seat's deadline per check (s) |
| `COUNCIL_HEADS_UP_TURNS` | 5 | Prompts (typed, or submitted by cs/cs-rotate) the heads-up digest window covers, from the Nth-last to the end |
| `COUNCIL_HEADS_UP_RESULTS` | 8 | Tool results inside that window the heads-up digest carries, 2000 characters each; a Write or Edit slot carries the text it wrote |
| `COUNCIL_RENDERER` | auto | `perl` forces the built-in perl renderer; otherwise the pane prefers Rich when a Rich-capable Python exists (python3 with a modern rich, else `uv run --no-project --with rich`), with perl as the fallback |
| `COUNCIL_RICH_PROBE_TIMEOUT` | 10 | Seconds before the pane-open uv probe for Rich is abandoned (guards against a cold uv cache on a dead network stalling pane opening) |
| `COUNCIL_THEME` | auto-detected | Force pane render palette (emphasis + muted text): `light` / `dark` (else OSC 11 query; `COLORFGBG` only asserts `light`, never `dark` since it goes stale; otherwise attribute-only emphasis that inherits the foreground, and muted text keeps faint/bright-black) |
| `COUNCIL_AUTO_CLOSE` | - | Set to `1` to auto-close the pane on completion (skip the keypress wait); used by tests/demos |
| `COUNCIL_RETRY_WAIT` | 45 | Seconds the pane's offer to retry failed providers stays open; the run waits for the answer. `0` disables the offer; `--async` workers default to `0` |
| `COUNCIL_ATTENTION_THRESHOLD` | 2000 | iTerm2 dock-bounce threshold in ms (only triggers if total elapsed >= this) |
| `COUNCIL_VERBOSITY` | standard | Response style: `brief` / `standard` / `detailed` (prepended to all providers' system prompts) |
| `OPENAI_REASONING_EFFORT` | medium | Reasoning model effort |
| `PERPLEXITY_RECENCY` | - | Search recency filter |
