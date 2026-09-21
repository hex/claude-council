# council-pane

A Claude Code mod that draws the council's streaming pane inside Claude Code, so it works without tmux.

Mods are early access. You need `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, and the API can change between Claude Code releases. I built it against 2.1.278. The tmux pane is still the default and nothing here replaces it.

## Run it

From the repo root:

```
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude --plugin-dir . --plugin-dir mods/council-pane
```

Both flags matter. `--plugin-dir .` loads this checkout's scripts over the installed plugin, which does not know about the mod yet. Then run `/claude-council:ask` as usual.

## How it hooks in

At session start the mod creates a directory under `$TMPDIR` and exports its path as `COUNCIL_MOD_PANE_DIR`. Every Bash command Claude runs after that inherits it.

When the variable is set, `run-council.sh` writes its watch directory there and skips tmux. The mod polls that directory twice a second and draws what it finds. The files are the same ones the tmux watcher reads, plus a few the mod needs:

| File | Written by | Holds |
|---|---|---|
| `status` | the run | one line per provider event: name, state, milliseconds, model |
| `responses/<name>.md` | the run | each answer |
| `errors/<name>.txt` | the run | each error |
| `colors` | the run | each provider's banner color as `r;g;b` |
| `job-id` | an `--async` run | the background job's id |
| `retry-offer` | the run | seconds the offer stays open, then the failed providers |
| `.retry` / `.retry-declined` | the pane | the answer to the offer |
| `.done` | the run | the run has finished |

Without the mod the variable is never set and the scripts behave as before.

## What you get

- A status list with one row per provider, in the provider's color. When the run ends it collapses to one summary line and a row of names.
- A banner per answer with the model and the time it took. Errors show in red.
- Tables wider than the pane are rewritten as one record per row. Claude Code sizes tables to the terminal, so a wide one wraps into noise otherwise.
- The synthesis, below the answers, once Claude has written it. Press `0` to jump to it.
- `retry` and `skip` buttons with a countdown when a provider fails. Click them, or press `r` and `s` while the pane has focus.
- Press `1` to `9` in the focused pane to jump to that provider's answer.
- Progress in the status line (`council 3/6`) and a toast when a run ends. This covers `--async` jobs too, and the toast names the job.
- `/council-pane` reopens the pane with the last run.

## Settings

They show up in `/config`. Changing one reloads the mod.

| Setting | Default | What it does |
|---|---|---|
| `pane` | on | Off exports nothing, so runs go back to the tmux pane. |
| `collapse_when_done` | on | Off keeps the full status list after a run. |
| `wake_on_async_done` | off | Submits a prompt when a background job finishes. That starts a model turn and costs tokens. |
| `council_tool` | off | Registers `mcp__council-pane__ask` so the model can call the council as a tool. |

`council_tool` is off for a reason. The council sends your question to third-party providers, and a tool is easier for the model to call unprompted than a slash command. The plugin's eval suite checks that Claude does not convene the council on its own, but `claude plugin eval` does not load this mod, so those checks cannot see the tool.

## Limits

- The pane follows one run at a time. If a second run starts while one is live, the pane picks it up when the first ends.
- Saving a file in the mod or changing a setting reloads it and clears the pane. Run `/claude-council:ask` again.
- The mod parses the synthesis out of Claude's reply, between the `## Synthesis` heading and the `Full output saved` line. If the council skill changes that format, the section stops appearing.
- Answer bodies use Claude Code's own markdown styling. The Rich renderer's fitted tables and code highlighting are tmux only.
- The mod cuts a single paragraph over 10,000 characters mid-text, because one `Markdown` element holds no more than that. A cut inside a code fence breaks the rendering of what follows.
- The drawing has no automated test. The docs describe `claude plugin test`, but 2.1.278 does not have it. `bun test` covers the logic. Only a person looking at the pane checks the drawing.

## Development

```
cd mods/council-pane
bun test
bunx tsc -p .
claude plugin validate .
```

The types come from `/plugin-types`, which writes `.claude/types/` at the repo root. Regenerate them after a Claude Code update. Run with `--debug` and look for `council-pane` in the log when something does not draw.

`claude plugin validate` enforces one rule `tsc` does not: you can pass `$` only to functions declared at the top of the hooks module, never to a closure inside `register`.
