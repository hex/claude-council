![claude-council](assets/banner.svg)

A Claude Code plugin that asks AI coding agents the same question in
parallel. Compare their answers when one model's bias could mislead you:
architecture decisions, debugging dead ends, security reviews, or framework
choices.

![Codex, Antigravity, Gemini, and OpenAI answer the SQLite-or-Postgres question while fake Kimi fails](assets/council-run.svg)

[![Tests](https://github.com/hex/claude-council/actions/workflows/tests.yml/badge.svg)](https://github.com/hex/claude-council/actions/workflows/tests.yml)

## Install

You need `curl` and `jq` on macOS, Linux, or Windows through Git Bash.

```text
/plugin marketplace add hex/claude-marketplace
/plugin install claude-council
```

Give it at least one provider in the shell you start Claude Code from:

```bash
export OPENAI_API_KEY="..."
# Or GEMINI_API_KEY, XAI_API_KEY, PERPLEXITY_API_KEY,
# KIMI_API_KEY, OPENROUTER_API_KEY
```

The `codex`, `agy` (Antigravity), `grok`, `kimi`, and `cursor-agent` CLIs use
your existing subscriptions without an API key. A local `ollama` model needs
no key or external network. With none of these, `--local` uses Claude
subagents. See [provider selection](docs/REFERENCE.md#choosing-providers) and
[local councils](docs/USAGE.md#local-council---local).

## First run in 60 seconds

Read [what gets sent and saved](docs/REFERENCE.md#what-gets-sent-and-saved)
before asking about your code.

```text
/claude-council:status
/claude-council:ask "Should I use UUID or BIGINT primary keys for a SaaS users table?"
```

Each provider answers independently. Claude writes a synthesis of their
agreement, disagreements, and recommendation. Agreement is not verification:
the models share your description and its assumptions.
[The synthesis names the premise that could change the answer](docs/REFERENCE.md#reading-the-synthesis).

## Features

| Capability | Guide |
|---|---|
| Ask providers together, or name one in plain words | [Command examples](docs/REFERENCE.md#command-examples) |
| Choose providers and pin a standing roster | [Provider selection](docs/REFERENCE.md#choosing-providers) |
| Assign specialist roles | [Roles](docs/USAGE.md#specialized-roles) |
| Have providers challenge each other's answers | [Debate](docs/USAGE.md#debate-mode) |
| Gather code context with agents before asking | [Agent mode](docs/USAGE.md#agent-enhanced-analysis---agents) |
| Use Claude subagents without an external provider | [Local council](docs/USAGE.md#local-council---local) |
| Include relevant files or choose your own | [Auto-context](docs/USAGE.md#auto-context-injection) |
| Attach a screenshot | [Image input](docs/USAGE.md#image-input) |
| Ask about the current conversation | [`/advise`](docs/USAGE.md#asking-about-the-conversation-itself) |
| Run in the background and fetch the result | [Background jobs](docs/USAGE.md#background-jobs---async) |
| Export the answers to a file | [Export](docs/USAGE.md#export-to-file) |
| Show only the synthesis | [Quiet mode](docs/USAGE.md#quiet-mode) |
| Watch answers arrive and retry failed seats | [The pane](#the-pane) |
| Get a note from one seat while Claude works | [Heads-up side-check](#heads-up-side-check) |
| Have a second model review the diff before Claude stops | [Stop-gate review](docs/USAGE.md#stop-gate-review-opt-in-off-by-default) |
| Call the scripts without Claude Code | [Direct script usage](docs/REFERENCE.md#direct-script-usage) |

The [reference](docs/REFERENCE.md) lists every flag, variable, model default,
and limit. [Architecture](docs/ARCHITECTURE.md) covers the implementation.
[TESTING.md](TESTING.md) covers tests, releases, and adding a provider.

## Heads-up side-check

![The intro hint, a heads-up note, Learn more, and an unsent Tell Claude draft](assets/heads-up.svg)

Opt in through the "Heads-up side-check" row in `/config` or the project's
`.claude/council-heads-up.json`. One seat, codex by default, checks recent
turns and tool results while Claude works. For a Write or an Edit, it gets the
text Claude wrote. The note shows what went where.
Learn more expands it; Tell Claude puts a draft in the prompt without sending
it. Read the [data limits and off switch](docs/REFERENCE.md#what-gets-sent-and-saved)
and the [heads-up guide](docs/USAGE.md#heads-up-side-check-opt-in-off-by-default).

## The pane

With `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, the pane opens inside Claude Code,
as in the animation above. Each answer's banner names the seat, model, and
elapsed time. Answers fold when the synthesis arrives so it sits near the
top. Cancel a slow seat, fold sections, or reopen the last run with
`/council-pane`. Inside tmux, the mod asks once which pane you want.

Mods are early access. The [mod guide](mods/council-pane/README.md) lists
keys, settings, and limits. It also lets Claude call the council as a tool;
every call asks you first.

![Real SQLite-or-Postgres answers arrive in tmux beside a fake Kimi failure and the retry offer](assets/tmux-pane.svg)

Without the mod, tmux opens a side pane that streams answers and each
provider's status. It offers to retry failed seats. Esc closes it.
`--no-pane` or `COUNCIL_NO_PANE=1` turns it off. Outside both pane modes,
answers arrive in the chat. See [terminal integration](docs/REFERENCE.md#display--terminal-integration).

The council and tmux animations show real answers to
"Should a single-node demo app use SQLite or Postgres?" Codex and Antigravity
use subscriptions; Gemini and OpenAI use their APIs. Kimi is a rate-limit
fixture. The heads-up animation uses a fake seat and a real Claude Code host.
[Capture scripts and raw frames](assets/capture/README.md) record how to
reproduce them.

## Troubleshooting

| Problem | Fix |
|---|---|
| Cloned the repo and nothing loads | Don't clone into `~/.claude/plugins/`. `pluginDirectories` is not a setting. Follow [running from a local clone](docs/REFERENCE.md#running-from-a-local-clone). |
| No providers found | Run `/claude-council:status`. Export keys in the shell that starts Claude Code, or use `--local`. |
| A different model answered | A header such as `grok-4.7 (grok-latest unavailable)` records a [model fallback](docs/REFERENCE.md#model-fallback). Setting that provider's `_MODEL` variable disables fallback. |
| No pane | Use tmux or set `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` for the pane inside Claude Code. |
| Updating | Run `/plugin update claude-council`, then restart Claude Code. |
