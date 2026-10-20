# README fact inventory

Baseline: `34bb74a`, before the SVG work. Each row records the old claim,
its destination, and implementation evidence. Examples retain their original
arguments unless the row names a correction.

| ID | Original fact | Fate and destination | Evidence |
|---|---|---|---|
| 01 | Claude Code plugin; parallel agents; side-by-side answers; cross-check model bias | Keep in README introduction and banner | `.claude-plugin/plugin.json`, `scripts/query-council.sh`, `mods/council-pane/hooks/view.ts` |
| 02 | Architecture, debugging, security, and framework decisions are example uses | Keep in README introduction | `commands/ask.md` accepts free-form questions; `config/roles.json` supplies review roles |
| 03 | Old screenshot shows twelve seats | Replace the illustration with five actual fixture seats, as the brief requires | `council-run.json` and its raw captures; no twelve-seat product limit was claimed |
| 04 | Answer banners name seat, model, and time; answers fold when synthesis arrives | Keep in README, The pane | `mods/council-pane/hooks/view.ts`, `mods/council-pane/hooks/pane.tsx` |
| 05 | Inline pane needs `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`; tmux fallback; chat outside both | Keep in README, The pane | `hooks/hooks.json`, `scripts/lib/display.sh`, `skills/council-execution/SKILL.md` |
| 06 | Quick-start, privacy, commands, providers, usage, and reference navigation | Replace old local section links with Install, First run, feature rows, and guide links | `check-links.py` checks new destinations |
| 07 | `curl`, `jq`; macOS, Linux, Windows through Git Bash | Keep in README, Install | `scripts/query-council.sh` dependency checks; `.github/workflows/tests.yml` |
| 08 | `/plugin marketplace add hex/claude-marketplace`; `/plugin install claude-council` | Keep verbatim in README, Install | Local `claude plugin marketplace add --help`, `claude plugin install --help`; plugin manifest name |
| 09 | Export a key in the shell that starts Claude Code | Keep in README, Install and Troubleshooting | `scripts/lib/providers.sh`, `scripts/lib/keys.sh` |
| 10 | `OPENAI_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `PERPLEXITY_API_KEY`, `KIMI_API_KEY`, `OPENROUTER_API_KEY` | Keep all six in README, Install | Provider scripts and `api_key_present` |
| 11 | `codex`, `agy` (Antigravity), `grok`, `kimi`, `cursor-agent` use subscription login without API keys | Keep in README, Install | `scripts/providers/{codex,antigravity,grok-cli,kimi-cli,cursor-cli}.sh` |
| 12 | Local Ollama needs no key or external network | Keep in README, Install; qualify as a local model | `scripts/providers/ollama.sh`, default localhost host |
| 13 | `--local` uses Claude subagents without these providers; local-council guide link | Keep in README, Install and feature row | `commands/ask.md`, `skills/local-council-execution/SKILL.md` |
| 14 | `/claude-council:status`, then UUID versus BIGINT SaaS users-table question | Keep verbatim in README, First run | `commands/status.md`, `commands/ask.md` |
| 15 | Independent answers, then Claude synthesis of agreement, split, recommendation | Keep in README, First run; expand in Reference, Reading the synthesis | `skills/council-execution/SKILL.md`, `prompts/synthesis.md` |
| 16 | Agreement is not verification; shared description; name the untested premise | Keep warning in README; move detail to Reference, Reading the synthesis | `prompts/synthesis.md` |
| 17 | Five providers recommend SQLite; single-node premise could flip the recommendation | Move illustrative example to Reference, Reading the synthesis; replace em dash with a period | Synthesis prompt requires this form of calibration; example stays explicitly illustrative |
| 18 | Each selected CLI/API vendor gets the question; OpenRouter plus upstream; local Ollama stays local | Move to Reference, What gets sent and saved; link before first run | `scripts/providers/*.sh`, `scripts/query-council.sh` dispatch |
| 19 | Auto-context: up to five files, about 10,000 tokens, list before sending | Move to Reference, What gets sent and saved | `commands/ask.md`, Auto-Context Injection |
| 20 | `--no-auto-context` disables selection; `--file=` replaces it; `--image=` only reaches capable providers | Move to Reference, What gets sent and saved | `commands/ask.md`, `scripts/query-council.sh` image routing |
| 21 | Full prompt, attached files, answers saved as plaintext in `.claude/council-cache/`; own `.gitignore`; no image bytes | Move to Reference, What gets sent and saved; describe normal commits rather than an absolute guarantee | `scripts/run-council.sh`, `scripts/lib/cache.sh`, `scripts/query-council.sh` temporary image cleanup |
| 22 | Provider gets own vendor variables; other vendor keys and unrelated secrets stripped; environment reference link | Move to Reference, What gets sent and saved; retain link to allowlist exceptions | `scripts/lib/providers.sh` provider environment construction |
| 23 | `/advise` previews size, turn count, opening lines and asks before sending conversation context | Move to Reference, What gets sent and saved | `commands/advise.md` |
| 24 | Heads-up is opt-in through `/config` or `.claude/council-heads-up.json`; then sends mid-turn without asking | Keep short README section; move full consent details to Reference | `mods/council-pane/hooks/heads-up.ts`, `mods/council-pane/hooks/pane.tsx` |
| 25 | Last five turns, eight tool results, 2,000 characters each; Bash output may hold secrets | Move to Reference, What gets sent and saved | `scripts/heads-up.sh`, `scripts/transcript-digest.sh` |
| 26 | One heads-up seat, codex default; displayed bytes and destination; row off or `enabled: false` stops it | Keep summary in README; move exact controls to Reference; keep Usage link | `mods/council-pane/hooks/heads-up.ts`, captured heads-up states |
| 27 | Ask example: Express authentication | Move unchanged to Reference, Command examples | `commands/ask.md` question input |
| 28 | `--providers=gemini,codex` example: caching | Move unchanged to Reference, Command examples | `commands/ask.md`, `scripts/lib/providers.sh` |
| 29 | `--file=src/auth.ts` example: implementation review | Move unchanged to Reference, Command examples | `commands/ask.md` explicit file handling |
| 30 | `--image=shot.png` example: off-center dialog | Move unchanged to Reference, Command examples | `commands/ask.md`, `scripts/query-council.sh` |
| 31 | `--roles=balanced` example: review | Move unchanged to Reference, Command examples | `config/roles.json`, `commands/ask.md` |
| 32 | `--debate` example: database schema | Move unchanged to Reference, Command examples | `commands/ask.md`, `scripts/query-council.sh` round two |
| 33 | `--quiet` example: Redis or Memcached | Move unchanged to Reference, Command examples | `commands/ask.md`, `skills/council-execution/SKILL.md` |
| 34 | `--output=docs/decision.md` example: REST or GraphQL | Move unchanged to Reference, Command examples | `commands/ask.md`, `skills/council-execution/SKILL.md` export |
| 35 | `--async` example: migration strategies; `/result <job-id>` | Move unchanged to Reference, Command examples | `commands/ask.md`, `commands/result.md`, `scripts/lib/jobs.sh` |
| 36 | `/advise "are we solving the right problem here?"`; `/status` | Move unchanged to Reference, Command examples | `commands/advise.md`, `commands/status.md` |
| 37 | "check with grok" selects that provider alone; flags and workflow links | Move to Reference, Command examples; feature row links there | `commands/ask.md` natural-language provider selection |
| 38 | Automatic discovery uses keys, CLI PATH, or "running ollama"; status shows results | Move to Reference, Choosing providers; correct "running" to installed, with server needed to answer | `scripts/lib/providers.sh` uses `command -v ollama`, no server probe |
| 39 | CLI shadows API: codex/openai, antigravity/gemini, grok-cli/grok, kimi-cli/kimi | Move all four pairs to Reference, Choosing providers | `scripts/lib/providers.sh` `SHADOW_PAIRS` |
| 40 | CLI failure falls back to API if key exists; header names fallback | Move to Reference, Choosing providers | `scripts/query-council.sh`, `scripts/format-output.sh` |
| 41 | `COUNCIL_PROVIDERS="codex,antigravity"` standing roster; per-call `--providers=` wins | Move exact example to Reference, Choosing providers; retain roster guide link | `scripts/lib/providers.sh` selection policy |
| 42 | OpenRouter any routed model, Claude default; `OPENROUTER_MODELS="a/b,c/d"` creates `openrouter-1`, `openrouter-2` | Move to Reference, Choosing providers | `scripts/lib/providers.sh` roster expansion and default model |
| 43 | `claude-cli` opt-in on Claude subscription, without CLAUDE.md, settings, plugins | Move to Reference, Choosing providers | `scripts/providers/claude-cli.sh`, explicit-only discovery branch |
| 44 | `copilot-cli` opt-in on Copilot plan, without AGENTS.md or tools | Move to Reference, Choosing providers | `scripts/providers/copilot-cli.sh`, explicit-only discovery branch |
| 45 | Links for keys, CLI details, default models, fallbacks | Keep as specific links in Reference, Choosing providers | Link check and corresponding provider sources |
| 46 | Tmux streams answers and live status, retries failures, Esc closes; `--no-pane` and `COUNCIL_NO_PANE=1` disable | Keep in README, The pane | `scripts/lib/display.sh`, `scripts/lib/pane-watcher.sh`, actual tmux captures |
| 47 | Inline mod asks once inside tmux; cancel, fold, reopen with `/council-pane` | Keep in README, The pane | `mods/council-pane/hooks/host.ts`, `mods/council-pane/hooks/pane.tsx`, `mods/council-pane/hooks/view.ts` |
| 48 | Mods early access; mod keys/settings/limits link; council tool asks on every call | Keep in README, The pane | Generated host type contract; `mods/council-pane/hooks/tool.ts` confirmation prompt |
| 49 | Roles, debate, agent mode, local council guide links | Keep as four feature rows with exact guide anchors | `commands/ask.md`, execution skills, `config/roles.json` |
| 50 | Background jobs, export, quiet guide links | Keep as three feature rows with exact guide anchors | `commands/ask.md`, `commands/result.md`, execution skill |
| 51 | Stop-gate: second model reviews diff before Claude stops; opt-in guide | Keep feature row | `hooks/hooks.json`, `scripts/stop-review-gate.sh` |
| 52 | Heads-up while Claude works, default codex, guide link | Keep feature row and section | Heads-up implementation and actual captures |
| 53 | All flags/variables/defaults/limits, direct scripts, architecture, testing/releases/adding-provider links | Keep reference paragraph and direct-script feature row | Link check; actual scripts, source tree, workflow and provider interface |
| 54 | Clone trap: don't clone into `~/.claude/plugins/`; `pluginDirectories` is not a setting; local-clone link | Keep Troubleshooting row | Local Claude `--help` and actual captures use `--plugin-dir`; host 2.1.304 contains 223 `enabledPlugins` literals and no `pluginDirectories` literal; [loading reference](https://code.claude.com/docs/en/plugins/loading) documents installed-plugin records and session-only directories |
| 55 | No providers: `/status`, export keys in host shell, or `--local` | Keep Troubleshooting row | `commands/status.md`, provider discovery, local execution skill |
| 56 | `grok-4.7 (grok-latest unavailable)` is model fallback; provider `_MODEL` disables it | Keep exact header example and guide link in Troubleshooting | `scripts/lib/model_fallback.sh`; `scripts/format-output.sh` |
| 57 | No pane: needs tmux or function-hooks variable | Keep Troubleshooting row | Display selection and mod hook registration |
| 58 | `/plugin update claude-council`, restart Claude Code | Keep Troubleshooting row | Local `claude plugin update --help` says restart required |

No product capability was removed. The twelve-seat still image was replaced
at the brief's request. The Ollama discovery condition was corrected against
the source. The cache wording now states what `.gitignore` guarantees:
normal commits exclude the files, but a user can force-add ignored files.
