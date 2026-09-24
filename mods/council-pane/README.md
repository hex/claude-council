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
- While a run is live, a `COUNCIL` band above the prompt shows a thin line and a percent that fill as providers finish, an error counting as finished, and the seconds since the run started, with a button to open the pane. The pane lists who is still out.
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
| `specialist_1` to `specialist_4` | empty | One Codex specialist per row. See [Specialists](#specialists). |

The council sends your question to third-party providers, and a tool is easier for the model to call unprompted than a slash command. Every call opens a dialog quoting the question and naming the providers, and nothing leaves the machine unless you choose `Send to the council`. `Don't send` or dismissing the dialog refuses the call. Anything you type under Other goes back to the model as a plain tool result, not a refusal, so it reads as your answer rather than an error. The specialist's finish dialog does the same. A `claude -p` run has no one to ask and gets the same refusal.

## Specialists

A specialist is a Codex agent that writes code for you on its own model, in its own git worktree. You name it, pick its model and the council perspective it works from, and say when it fits. Claude offers one when a task matches and starts it only once you ask or agree. The start itself opens no dialog; only a finish asks you first.

Each `/config` row holds one specialist:

```
sec = gpt-6-sol as security, when: auth, crypto, untrusted input
sec = gpt-6-sol as security, effort: high, when: auth, crypto, untrusted input
```

The name is lowercase letters, digits and dashes. The model goes to `codex exec -m` as written. `effort:` is optional and sets Codex's reasoning effort for every round of that specialist: `minimal`, `low`, `medium`, `high` or `xhigh`. Without it, your own Codex default applies. The perspective is a key of `config/roles.json` (`security`, `performance`, `maintainability`, `devil`, `simplicity`, `scalability`, `dx`, `compliance`), and its prompt opens every task. The text after `when:` is what Claude matches tasks against, up to 200 characters. The mod ignores an empty row and skips a row that does not parse; the session log says which row and why. With at least one valid row the mod registers `mcp__claude-council__specialist`.

The tool takes four calls. Only a finish opens a dialog:

- Start, `{specialist, task}`: creates the worktree from `HEAD` and starts round 1. When you have uncommitted changes, the reply says the worktree lacks them.
- Follow-up, `{run, message}`: continues the same Codex session in the same worktree.
- Finish, `{run, finish}`: asks `Merge <branch> (N commits, M files) into <branch>?` or `Discard run <id> and delete its branch?`
- Result, `{run, result: true}`: returns the last round's result.

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

`claude plugin validate` enforces one rule `tsc` does not: you can pass `$` only to functions declared at the top of the hooks module, never to a closure inside `register`.
