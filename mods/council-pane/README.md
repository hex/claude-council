# council-pane

A Claude Code mod that draws the council's streaming pane inside Claude Code, so it works without tmux.

Mods are early access. You need `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, and the API can change between Claude Code releases. The heads-up side-check needs Claude Code 2.1.302 or later; the rest of the mod runs on 2.1.278. The tmux pane is still the default and nothing here replaces it.

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
| `status` | the run | one line per provider event: name, state (`querying`, `complete`, `cached`, `error`, `fallback`, `cancelled`), milliseconds, model. A `fallback` line's model reads `<model> via <sibling> API` |
| `responses/<name>.md` | the run | each answer |
| `errors/<name>.txt` | the run | each error, and for a seat its API sibling answered, why the seat itself did not. A cancelled seat has none: the run removes it |
| `colors` | the run | each provider's color as `r;g;b`: the tmux pane's banner, the edge of the mod's seat row |
| `pid` | the run | the run's process id, so a run that was killed is not waited on |
| `job-id` | an `--async` run | the background job's id |
| `job-file` | an `--async` run | the path of the job's record, which says when the result can be fetched |
| `retry-offer` | the run | seconds the offer stays open, then the failed providers |
| `.retry` / `.retry-declined` | the pane | the answer to the offer |
| `cancel/<name>` | the pane | cancel that seat. The run removes it once the seat is logged `cancelled`, or at once if the seat's answer was already written or the seat had already ended; a marker that lands after the run stopped waiting on its seats stays, and goes with the watch dir |
| `retriable/<name>` | the run | that seat failed and a row press can re-query it: written while the run still waits on other seats, removed at the relaunch or when the run stops waiting. The pane shows the row's `retry` only for a name listed here |
| `retry/<name>` | the pane | re-query that seat from its error row. The run removes it at the relaunch; one that lands after the run stopped waiting stays, and the band's offer takes over |
| `.done` | the run | the run has finished |

Without the mod the variable is never set and the scripts behave as before.

## What you get

![Four real answers to the SQLite-or-Postgres question with a fake Kimi failure inside Claude Code](../../assets/council-run.svg)

Two subscription seats, two API seats, and a fake Kimi failure in a real Claude Code host.
Each seat has one row, with cancel while it queries and retry on the failed
seat. Answers fold when the synthesis arrives. The band above the prompt
tracks the run.

- One row per seat for the whole run: a `▌` edge in the provider's color, the seat's digit, a glyph for its state, its name, its model, a bar and its time. An amber `●` is live, a green `✓` answered, a blue `✓` with `cached` came from the cache, an amber `✓` with `fell back` was answered by its API sibling, a red `✗` failed and a grey `○` was cancelled. The bar says the same in its colour: a block sweeps a dotted track while the seat queries, it fills once the seat answers, a short stub stays at the left on an error, and a cancelled seat's track is bare. A live seat's time counts up and a settled seat's is final, in the same column. No seat appears twice.
- At the row's right edge sits what its digit does now: `cancel` while the seat queries, `retry` on a failed seat the run can still re-query, `open` or `fold` on a seat with an answer or an error to show, or the digit alone when it does nothing. Click it, or press ctrl+x tab and then the digit (`1` to `9`, then `0` for the tenth; an eleventh seat has the button and no digit). A seat keeps its digit through a retry and after the run ends. Cancel ends that seat and the run goes on without it: the row turns to a grey `○` at once and stays so once the run confirms. Retry re-queries the seat with the query it failed, once: the row shows an amber `●` until the run relaunches it. Once the last seat ends no row offers cancel or retry, and the band's own retry offer takes over for the seats that failed.
- A seat's answer, or its error text, hangs under its row while open. A new run starts with every section open, and when the synthesis lands the seats fold so it reads at the top. When a CLI seat fails and its API sibling answers, a dim amber `<name> fell back: <reason>` line sits above the answer. The synthesis header (`▾` open, `▸` closed) opens and closes on a click, or press ctrl+x tab, reach it with Tab or the arrows and press Enter.
- The pane's last line lists the keys that apply now: `a: fold` while two or more sections can fold and one is open, `a: expand` once they are all closed, `c: cancel all` while a seat is still querying, and `✕ close` for the pane's close mark. Press a key with the pane focused (ctrl+x tab), or click it.
- When the run ends a summary line leads (`4 of 5 answered · 1 error · 14.2s`), counting the seats that fell back, were cancelled or came from the cache apart; a seat its API sibling answered counts as answered. With `collapse_when_done` on, the synthesis follows it once Claude has written it, the folded seats below. Off, the synthesis stays below the seats.
- Tables wider than the pane are rewritten as one record per row. Claude Code sizes tables to the terminal, so a wide one wraps into noise otherwise.
- The pane holds at most 80,000 characters, counted after wide tables are rewritten for its width. Claude Code refuses to draw a pane carrying more than 100,000 and draws its own instead, so over the budget the answers are cut to an even share, each ending with how many characters were left out; the synthesis and the seat rows are never cut, an error is drawn at its first 2,000 characters, a closed section counts only its row, and `/claude-council:result` has every answer whole.
- While a run is live, a `COUNCIL` band above the prompt reads: how many providers finished (`3 of 6`, an error or a cancelled seat counting as finished), a bar that fills with them, an `m:ss` clock since the run started, the latest event (`gemini answered`, `asking kimi`, `grok-cli answered through its API`), a `c · cancel all` button while any seat is still querying, and a button to open the pane. Cancel all presses every querying row's cancel at once, with no confirmation, as clicking each row would; click it, or press ctrl+x tab and then `c`. On a narrow pane the event gives way first. The pane lists who is still out.
- `retry` and `skip` buttons with a countdown bar when a provider fails. They sit in the band above the prompt, so they stay in view while the pane scrolls. Click them, or press ctrl+x tab to give the band the keys and then `r` or `s`. Typing goes to the prompt until you do.
- When a run ends, a `COUNCIL` notice sits above the prompt for 20 seconds with buttons to open the pane or dismiss it. This covers `--async` jobs too, and the notice names the job.
- `/council-pane` reopens the pane with the last run.
- `/heads-up [setup | on [seat] | off | status]` sets the heads-up side-check up in Claude Code's own dialogs, switches it on for this project naming the one seat to ask, or off, or shows its state and counts. It runs at once mid-turn; since the engine draws a command's reply only when the turn ends, the status then also shows as a one-line toast. See [Heads-up side-check](#heads-up-side-check).

## Settings

They show up in `/config`, which lists each row by its title alone; the table below says what each one does. Changing one reloads the mod.

| Setting | Default | What it does |
|---|---|---|
| `pane_host` | `ask` | Where the pane opens. `claude-code` always draws it here, `tmux` always leaves it to tmux. `ask` puts the question once, the first time a run starts inside tmux, and remembers the answer across sessions; the row's label shows what it remembered. `/council-pane ask` forgets it. Outside tmux, `ask` opens the pane here without asking. |
| `collapse_when_done` | on | On, a finished run shows its summary, then the synthesis, then the folded seats. Off keeps the live order under the summary: the seats, then the synthesis. |
| `wake_on_async_done` | off | Submits a prompt when a background job's result can be fetched. That starts a model turn and costs tokens. A job that fails wakes nobody. |
| `council_tool` | on | Registers `mcp__claude-council__ask` so the model can call the council as a tool. Each call asks you first. |
| `heads_up` | off | Turns the heads-up side-check on in every project. A project's `.claude/council-heads-up.json` overrides it for that project. See [Heads-up side-check](#heads-up-side-check). |

The council sends your question to third-party providers, and a tool is easier for the model to call unprompted than a slash command. Every call opens a dialog quoting the question and naming the providers, and nothing leaves the machine unless you choose `Send to the council`. `Don't send` or dismissing the dialog refuses the call. Anything you type under Other goes back to the model as a plain tool result, not a refusal, so it reads as your answer rather than an error. A `claude -p` run has no one to ask and gets the same refusal.

## Heads-up side-check

Off by default. Two switches: the `/config` row "Heads-up side-check" (`heads_up`) turns it on everywhere, and a project's `.claude/council-heads-up.json` turns it on or off for that project and picks the seat and cadence: `{"enabled": true, "seat": "codex", "every": 3}` (`enabled` optional, `true` on, `false` off whatever the row says, absent follows the row; `seat` defaults to `codex`, `every` to 3, at least 2). A file that does not parse, a seat name that is not a plain lowercase word, or a `seats` or `models` key keeps it off and logs the reason once, with the row on too. Either switch is the consent; [HEADS-UP.md](HEADS-UP.md) is the design.

On the main loop's `turn.step`, every `every` model requests into a turn (the step's own index), the mod forks `scripts/heads-up.sh` with the session id, the seat and an avoid list of topics already shown. The request is never held up. While a check runs no other starts; a turn gets at most one note. The poll reads `result.json` once `.done` lands, or reports the check failed once the worker or its dir has vanished, and removes the dir. A transcript holding no prompt of the person's (typed, or submitted by cs) is a skipped check: logged once per reason, nothing drawn, not counted. A check whose seat failed logs one `heads-up:` line with the reason and shows it in red above the prompt for 20 seconds, with `x` to dismiss; a check that found nothing puts `heads-up: <seat> read <KB> in <s>, nothing to flag` on the dim hint under the empty prompt until the next keystroke or check.

`/heads-up setup` asks the engine's own dialog (scope: this project, every project, off here; seat, a single choice: the providers the council's own discovery finds here, codex first, four at most, a typed seat under Other; cadence: 3, 6, 9 or a typed number; the seat's model, codex's from `codex debug models`, and for codex an effort) and writes the file, the pick under `model` (`{model, effort}`, left out when empty; the runner gets it as `--model FILE`, exports the seat's `*_MODEL` and passes codex `-c model_reasoning_effort`), plus the `/config` row for every project, which reloads the mod. `/heads-up on` and `/heads-up off` write the project file with `enabled` set and its other fields kept, and `/heads-up on <seat>` also sets `seat` (one plain provider name, checked before the write; two names get the usage line instead) and drops a `model` picked for another seat; `/heads-up` or `/heads-up status` prints the effective state, which switch set it, the seat with its pick and the cadence, then the counts the mod keeps in the plugin store under `heads-up-counts` (checks, none, notes, repeats, failed, learn, tell, knew, understood, dismiss, turned off, typed past; checks is the other four added up, never stored; a read-add-write per event, so two sessions bumping at once can lose one). Nothing leaves the machine. The first session where the check is off adds `Tip: /heads-up on lets another model watch long turns and flag what Claude missed` to the dim hint under the empty prompt until the first typed character; the store flag `heads-up-intro-shown` keeps it from coming back.

A note sits above the prompt, after the finished and retry rows and before the progress band: ` ! <tag> · <headline>` (the badge, `!` for a Heads up and `?` for a You should know, white on Claude's orange; the tag bold: `Heads up` for this session's work, `You should know` for a concept that matters; the sentence wrapped under its first word), then the choices with the seat, its model, payload and time dimmed after them: `1: Learn more`, `2: Knew this already`, a dim `3: Turn off` (two presses, the second writes the project file off) and `0: Dismiss`. Learn more opens the note the way the builtin does, a bold title and three to six bullets with the action bold last, with `1: Understood`, `2: Tell Claude`, the dim `3: Turn off` and `0: Close`; tell Claude puts a draft quoting the note in the prompt box, and the person sends or edits it; nothing is hidden and nothing is sent for them. A prompt you type while a note shows is typing past it, and the mod skips that many later checks. The plugin store keeps seen and known topics across sessions, 50 each; the session's own state is in `$.state` under `claude-council.headsUp`, declared in `types/index.d.ts`.

The rules live in `hooks/heads-up.ts`, with their tests in `tests/heads-up.test.ts`; `pane.tsx` only feeds them events.

## Limits

- A run that is killed outright writes no `.done`. The mod checks the run's pid every five seconds and, once the process is gone, shows `stopped before it finished` and moves on.
- The pane follows one run at a time. If a second run starts while one is live, the pane picks it up when the first ends.
- Saving a file in the mod or changing a setting reloads it and clears the pane. Run `/claude-council:ask` again.
- The mod parses the synthesis out of Claude's reply, between the `## Synthesis` heading and the `Full output saved` line. If the council skill changes that format, the section stops appearing.
- Answer bodies use Claude Code's own markdown styling. The Rich renderer's fitted tables and code highlighting are tmux only.
- The mod cuts a single paragraph over 10,000 characters mid-text, because one `Markdown` element holds no more than that. A cut inside a code fence breaks the rendering of what follows.
- The drawing has no automated test. `claude plugin test` exists from Claude Code 2.1.295, but no test here imports its kit from `claude-code/testing`. `bun test` covers the logic. Only a person looking at the pane checks the drawing.

## Development

```
(cd mods/council-pane && bun test && bunx tsc -p .)
claude plugin validate .
```

The types come from `/plugin-types`, which writes `.claude/types/` at the repo root. Regenerate them after a Claude Code update. The heads-up state needs types from 2.1.302 or later, which declare `$.state`, `atom`, `read` and `update`. `claude plugin validate` checks the `$.state` key against `types/index.d.ts`, which `.claude-plugin/plugin.json` names under `"types"`. Run with `--debug` and look for `claude-council` in the log when something does not draw.

Colours, type, glyphs and components follow [DESIGN.md](DESIGN.md), and every colour lives in `hooks/theme.ts`. Most are the engine's own theme keys, so the mod follows a light, dark or colour-blind theme and keeps its contrast on each.

`claude plugin validate` enforces one rule `tsc` does not: you can pass `$` only to functions declared at the top of the hooks module, never to a closure inside `register`.
