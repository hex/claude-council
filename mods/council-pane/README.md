# council-pane

A Claude Code mod that draws the council's streaming pane inside Claude Code, so it works without tmux.

Mods are early access. You need `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, and the API can change between Claude Code releases. I built it against 2.1.278. The tmux pane is still the default and nothing here replaces it.

## Run it

The mod ships with the plugin: `hooks/hooks.json` at the repo root names `pane.tsx` as a module, so an installed council loads it whenever the variable is set. Without the variable Claude Code skips the module and the tmux pane works as before.

```
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude
```

Then run `/claude-council:ask` as usual. From a checkout, add `--plugin-dir .` to run this tree's copy over the installed one.

## How it hooks in

At session start the mod creates a directory under `$TMPDIR`. Just before Claude runs `run-council.sh`, the mod sets `COUNCIL_MOD_PANE_DIR` to that directory, or clears it when the pane belongs to tmux. The run inherits it.

When the variable is set, `run-council.sh` writes its watch directory there and skips tmux. The mod polls that directory twice a second and draws what it finds. The files are the same ones the tmux watcher reads, plus a few the mod needs:

| File | Written by | Holds |
|---|---|---|
| `status` | the run | one line per provider event: name, state, milliseconds, model |
| `responses/<name>.md` | the run | each answer |
| `errors/<name>.txt` | the run | each error |
| `colors` | the run | each provider's banner color as `r;g;b` |
| `pid` | the run | the run's process id, so a run that was killed is not waited on |
| `job-id` | an `--async` run | the background job's id |
| `job-file` | an `--async` run | the path of the job's record, which says when the result can be fetched |
| `retry-offer` | the run | seconds the offer stays open, then the failed providers |
| `.retry` / `.retry-declined` | the pane | the answer to the offer |
| `.done` | the run | the run has finished |

Without the mod the variable is never set and the scripts behave as before.

## What you get

- A status list with one row per provider, in the provider's color. A provider still querying shows a spinner and a running time. When the run ends it collapses to one summary line and a row of names.
- A banner per answer with the model and the time it took. Errors show in red.
- Tables wider than the pane are rewritten as one record per row. Claude Code sizes tables to the terminal, so a wide one wraps into noise otherwise.
- The synthesis, below the answers, once Claude has written it. Press `0` to jump to it.
- While a run is live, a `COUNCIL` band above the prompt reads like the specialist band: how many providers finished (`3 of 6`, an error counting as finished), a thin line that fills with them, an `m:ss` clock since the run started, the latest event (`gemini answered`, `asking kimi`), and a button to open the pane. On a narrow pane the event gives way first. The pane lists who is still out.
- `retry` and `skip` buttons with a countdown bar when a provider fails. They sit in the band above the prompt, so they stay in view while the pane scrolls. Click them, or press ctrl+x tab to give the band the keys and then `r` or `s`. Typing goes to the prompt until you do.
- Press `1` to `9` in the focused pane to jump to that provider's answer.
- When a run ends, a `COUNCIL` notice sits above the prompt for 20 seconds with buttons to open the pane or dismiss it. This covers `--async` jobs too, and the notice names the job.
- `/council-pane` reopens the pane with the last run.

## Settings

They show up in `/config`. Changing one reloads the mod.

| Setting | Default | What it does |
|---|---|---|
| `pane_host` | `ask` | Where the pane opens. `claude-code` always draws it here, `tmux` always leaves it to tmux. `ask` puts the question once, the first time a run starts inside tmux, and remembers the answer across sessions; the row's label shows what it remembered. `/council-pane ask` forgets it. Outside tmux, `ask` opens the pane here without asking. |
| `collapse_when_done` | on | Off keeps the full status list after a run. |
| `wake_on_async_done` | off | Submits a prompt when a background job's result can be fetched. That starts a model turn and costs tokens. A job that fails wakes nobody. |
| `council_tool` | on | Registers `mcp__claude-council__ask` so the model can call the council as a tool. Each call asks you first. |
| `specialists` | `[]` | Every Codex specialist, as a JSON list of objects. Hidden from the menu; set up with `/specialists`. See [Specialists](#specialists). |

The council sends your question to third-party providers, and a tool is easier for the model to call unprompted than a slash command. Every call opens a dialog quoting the question and naming the providers, and nothing leaves the machine unless you choose `Send to the council`. `Don't send` or dismissing the dialog refuses the call. Anything you type under Other goes back to the model as a plain tool result, not a refusal, so it reads as your answer rather than an error. The specialist's finish dialog does the same. A `claude -p` run has no one to ask and gets the same refusal.

## Specialists

A specialist is a Codex agent that writes code for you on its own model, in its own git worktree. You name it, pick its model, say when it fits, and optionally give it instructions. Claude offers one when a task matches and starts it only once you ask or agree. The start itself opens no dialog; only a finish asks you first.

Run `/specialists` to set them up. It opens a screen with your specialists as a table in an orange frame: name, model, effort and use-when, one line each; a long use-when is cut with `…`, and the instructions stay in the form. The header has a neutral grey fill and dim bars separate the columns. Efforts get warmer as they rise, and every other row is shaded; the row you edit, and the one under the pointer, take the selection colour. Pick one to edit it in the form below, or add a new one. You type the name, the use-when and the instructions, and pick the model and the effort from lists:

- The models come from `codex debug models`. Listed models come first, and hidden ones carry `(hidden)`.
- The efforts are the ones Codex offers for the chosen model, each with Codex's own description, plus `default`, which keeps your own Codex default. If you switch to a model that lacks the chosen effort, the effort goes back to `default` and the screen says so.
- Use when is for Claude: it reads this to decide when to offer the specialist.
- Instructions are for the specialist: they open every new task it starts. Leave them blank and it just follows the task.

Save checks the specialist against Codex's catalog and writes it into the list: in place of the one you opened, or at the end for a new one. You can keep as many as you like. If a field is wrong, the screen names it and what it accepts, and writes nothing. The form marks unsaved changes. Opening another specialist or adding one over them asks first, and so does Remove, which takes the specialist out of the list. Discard changes drops your edits and keeps the screen open. With `/specialists` open in two sessions, a Save builds on the newest list either one wrote, and a specialist that changed in the other session since you opened it refuses to save over that change. Each session keeps its own form: a write in one reloads the other, which comes back on its own draft, unsaved changes included. Esc closes the screen and keeps a changed draft for the next `/specialists`. The screen opens at once and fills in the models when Codex answers; if Codex cannot list them, a Retry button asks again. Each save reloads the mod, so the transcript shows the engine's `options changed — reloaded` line. If `codex` is missing or logged out, the list and Remove still work, and Save shows Codex's error. On a phone, the screen asks you to use the terminal or the desktop app.


Disable, set apart from Save and Discard, switches a specialist off at once without removing it. It keeps its place in the table, in grey italics with a hollow `○` and `off ·` before its use-when, the header counts it (`SPECIALISTS (3 · 1 off)`), and Claude neither offers it nor can start it. A run it already has open still takes follow-ups and a finish. Enable, in the same place, turns it back on. The form stays open, so unsaved changes in it survive the switch.

You can also describe one to Claude, for example "add a specialist for Postgres migrations on gpt-6-luna, high effort". Claude opens the same screen with the fields filled in, and the screen saves nothing until you press Save. This works with no specialists set up yet. If you have unsaved changes on the screen, it opens on them instead, and the mod tells Claude to wait until you save or discard them.

### Templates

The mod ships no specialists. While you have none, the screen offers two templates under the empty table: `Use test-writer` and `Use bug-fixer`. Each opens a new form with the template's name, use-when and instructions, on the first model Codex lists. Pick the model and effort you want and press Save. The screen saves nothing before that, and over unsaved changes the button asks first. The templates name no model because the models depend on your Codex account.

| Name | Use when | Instructions |
|---|---|---|
| `test-writer` | The task is to add or extend tests for existing behaviour that has a spec. | Follow the repository's test layout and helpers. Take expected values from the spec, not from what the code returns. Change production code only when you cannot write the test otherwise, and say why. |
| `bug-fixer` | A bug reproduces, the expected behaviour is clear, and the fix stands apart from the current work. | Reproduce the failure first and name the failing test or command. Find the cause before changing code. Make the smallest fix. Never weaken or skip a test to make it pass. Report what you ran. |

### Hand edits

The list lives in one settings field, `specialists`, which `/config` does not show. It holds a JSON list with one object per specialist:

```json
[
  {"name": "sec", "model": "gpt-6-sol", "when": "auth, crypto, untrusted input"},
  {"name": "mig", "model": "gpt-6-luna", "effort": "high", "when": "schema changes",
   "instructions": "Review migrations for locks and rollbacks."}
]
```

Each entry needs `name`, `model` and `when`; `effort` and `instructions` are optional, `"enabled": false` switches it off, and the mod refuses any other key by name. The name is lowercase letters, digits and dashes. The model goes to `codex exec -m` as written. `effort` must be one of the levels Codex offers for that model; without it, your own Codex default applies. `when` is what Claude matches tasks against, one line of up to 200 characters. `instructions` are one line of up to 400 characters that open every new task. Setting the whole list by hand, as `/config claude-council.specialists=[...]`, goes through the same checks as a Save, and a refusal names the entry and the reason. While a Remote Control connection may be live, Claude Code hides that reason and prints `Couldn't save this setting (detail withheld on this connection).` instead, and the stored list is unchanged. The check asks Codex for its catalog, so it takes about a second. At session start the mod skips an entry that still does not parse, for example one written straight into `settings.json`, and the session log says which one and why. If the mod cannot read the stored list itself, the screen says why, and Save and Remove stay off until you fix it with `/config`. The mod registers `mcp__claude-council__specialist` in every session; with no specialists it only offers to set one up, and follow-ups, results and finishes for a run that is still open.

The tool takes five calls. Only a finish opens a dialog:

- Start, `{specialist, task}`: creates the worktree from `HEAD` and starts round 1. When you have uncommitted changes, the reply says the worktree lacks them.
- Follow-up, `{run, message}`: continues the same Codex session in the same worktree.
- Finish, `{run, finish}`: asks `Merge <branch> (N commits, M files) into <branch>?` or `Discard run <id> and delete its branch?`
- Result, `{run, result: true}`: returns the last round's result.
- Setup, `{setup: {name, model, effort, when, instructions}}`, every field optional: opens the setup screen with those fields filled in. The screen saves nothing until you press Save. With no specialists set up, this is the only call the tool takes.

A round runs in the background: start and follow-up return at once, and you can keep talking to Claude. When the round ends, the mod commits it and submits a prompt asking Claude to fetch the result and review it. The prompt carries only the run id; the specialist's own words reach Claude as a tool result. While a round runs, a `SPECIALIST` band above the prompt shows the specialist, its model, the time so far and its latest step: the command it runs, the file it edits, or the first line of what it says. `o · open pane` opens a pane that lists every step of the round under a header naming the specialist, its model, the round and its time: Codex's messages as markdown, its short reasoning summaries in dim italics, each command on one line, and each edited file, with a mark for each command and edit that is running, done or failed. While the round runs, a spinner and its time close the list, so the pane moves even while Codex only thinks. The pane follows new steps; scrolling up stops that, and scrolling back to the bottom resumes it. The pane keeps the last round after it ends. Codex ends each round with a report in the shape of `scripts/specialist-report.schema.json`: a summary, each test command it ran with pass, fail or not run, and its open questions. The pane shows the summary and questions. The result carries that report, the diff stat for the round and for the whole run, the branch and the worktree path. A last message that is not such a report reaches Claude as written, marked as off-schema. Claude reviews that and runs the tests in the worktree before asking you how to finish.

Worktrees go beside the repository, in `../<repo>.specialists/<name>-<time>`, on a branch `specialist/<name>/<time>`. The mod commits each round's changes on that branch, with the task's first line as the subject. The prompt asks Codex not to commit, so each round lands as one commit the mod made and its diff is exactly what that round changed. A merge is a `--no-ff` merge into the branch you have checked out. The mod refuses it when your uncommitted changes touch the files the branch changed, or when you are on a detached `HEAD`. It aborts a conflicting merge and keeps the worktree and branch. When git refuses to start the merge, for example over an untracked file in the way, the result carries git's own message. Merge and discard remove the worktree and the branch. Nothing else cleans them up.

To carry gitignored local files into a new specialist worktree, list their relative paths in the repository root's `.worktreeinclude`, one per line. Blank lines and lines starting with `#` are ignored; missing paths are skipped. This repository lists `.claude/types` so the pane's TypeScript check can use locally generated plugin types.

Network access is on inside the Codex sandbox. The worktree limits where a specialist can write, not what it can send: a specialist can read the worktree and reach the network, so it can send what it reads anywhere. Codex runs with your own `~/.codex/config.toml` and global instructions, so your extra writable roots, MCP servers and house rules apply to specialists too. The mod forwards no API keys; Codex uses its own login.

The mod records the detached round subshell's pid and process start time before Codex begins; launch fails if it cannot record a start time. A different live start time or a vanished pid marks a round without an exit file as lost. If the process check fails, the round stays running and the pane logs the failure once. Rounds started before start times were recorded use the pid existence check. Codex's pid is kept separately for stopping Codex; its exit does not mean the round subshell has finished writing the result.

## Limits

- A run that is killed outright writes no `.done`. The mod checks the run's pid every five seconds and, once the process is gone, shows `stopped before it finished` and moves on.
- The pane follows one run at a time. If a second run starts while one is live, the pane picks it up when the first ends.
- Saving a file in the mod or changing a setting reloads it and clears the pane. Run `/claude-council:ask` again.
- The mod parses the synthesis out of Claude's reply, between the `## Synthesis` heading and the `Full output saved` line. If the council skill changes that format, the section stops appearing.
- Answer bodies use Claude Code's own markdown styling. The Rich renderer's fitted tables and code highlighting are tmux only.
- The mod cuts a single paragraph over 10,000 characters mid-text, because one `Markdown` element holds no more than that. A cut inside a code fence breaks the rendering of what follows.
- A round has no time limit and no cancel. To stop one, kill the pid in `../<repo>.specialists/.state/<run>/codex-pid`; the round then ends with Codex's exit code, and the mod reports it as failed without committing.
- One specialist round runs at a time, across every session: they share the run records. A round outlives the session that started it: the next session that loads the mod follows it, or closes it if it ended meanwhile.
- A mod reload does not stop Codex. One round, measured, kept running through a reload.
- Nobody has tested specialists on Windows.
- The drawing has no automated test. The docs describe `claude plugin test`, but 2.1.278 does not have it. `bun test` covers the logic. Only a person looking at the pane checks the drawing.

## Development

```
(cd mods/council-pane && bun test && bunx tsc -p .)
claude plugin validate .
```

The types come from `/plugin-types`, which writes `.claude/types/` at the repo root. Regenerate them after a Claude Code update. Run with `--debug` and look for `claude-council` in the log when something does not draw.

Colours, type, glyphs and components follow [DESIGN.md](DESIGN.md), and every colour lives in `hooks/theme.ts`. Most are the engine's own theme keys, so the mod follows a light, dark or colour-blind theme and keeps its contrast on each.

`claude plugin validate` enforces one rule `tsc` does not: you can pass `$` only to functions declared at the top of the hooks module, never to a closure inside `register`.
