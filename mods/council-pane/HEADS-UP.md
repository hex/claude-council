# Heads-up side-check design

The "You should know" side-agent: while Claude works a long turn, a council seat rereads the conversation and surfaces at most one thing the person may have missed, above the prompt, without the main agent seeing it unless the person asks. Synthesized from a four-candidate architect arena on 2026-10-18; the rulings below are Alex's and fixed.

## Problem

The trigger must leave its hook within milliseconds (`turn.step` runs before every model request), but a codex call takes about 27 s per 8 KB of prompt, so the check runs in a self-detaching script and the pane polls for its result, as council runs and specialist rounds already do. Codex ignores a prose output contract (measured: it opened with "Alex," under its `~/.codex` AGENTS.md instead of answering NONE), so NONE must be structural for that seat. The digest now carries tool results, which the existing `transcript-digest.sh` keeps out on purpose (its tests at :64 and :342 pin that), and `$.session.messages()` carries no origin field, so a live-memory digest cannot tell a human prompt from a peer message. `$.store` is shared by every session, `$.state.set` is refused during a render, `$` may only reach top-level functions, and the AbovePrompt band is one instance drawn by one hook.

Rulings (fixed): codex by default, a per-project panel, first non-NONE in seat order (amended 2026-10-19 by Alex: one seat per project, no panel; `seats codex, gemini` read as a panel when gemini was only a fallback), no synthesis; consent is the opt-in project file alone (amended 2026-10-19 by Alex: a `/config` row is a second switch, the file can still say no per project), no preview, the note shows payload size and seat; mid-turn trigger with the builtin's cadence, backoff and NONE test; the last few tool results in the digest capped near 2 KB each, peer messages excluded; shipped in this plugin.

## Usage (caller's view)

Opt in once per project:

```json
// .claude/council-heads-up.json   (malformed: off; absent: the /config row decides)
{ "enabled": true, "seat": "codex", "every": 3 }
```

`seat` defaults to `codex`, and an optional `model` holds its pick, `{"model": ..., "effort": ...}`; `every` is model requests per check, default 3. The `/config` row `heads_up` (off by default) turns the check on in every project; the file's `enabled: true` turns it on for one project, `enabled: false` turns it off there whatever the row says, and an absent `enabled` follows the row. Either switch is the consent.

During a long turn, above the prompt:

```
✦ Heads up · The migration test passed against the empty fixture DB, so the backfill path never ran.
  codex · gpt-6.1-sol · 12.4 KB · 27 s      1: Learn more   2: Knew this already   3: Turn off   0: Dismiss
```

- `1` expands the band the way the builtin does: a bold title (80 characters) and three to six bullets (200 characters each, under 120 words together), the last one the action, drawn bold. The expanded band offers `1 · Understood`, `2 · tell Claude`, the dim `3 · Turn off` and `0 · close`; `Understood` is the builtin's acknowledge after reading: it marks the topic known as `Knew this already` does, but counts apart from it, since a note the person already knew was redundant and a note they took in was useful, and the counts are the dogfood's signal. `tell Claude` puts a draft quoting the note in the prompt box ("A side check by codex (not you) flagged this: <headline>", then the title and bullets as a list, then a close that asks for a check before action: for a Heads up, verify the claim and report before acting on the last bullet; for a You should know, weigh it against the plan), and the person sends or edits it. Reading the note alone tells Claude nothing, and nothing is submitted on the person's behalf.
- `2` records the topic as known; `0` as seen. Both are fed back so no seat raises it again.
- `3` is dim and takes two presses, the builtin's Disable: the first relabels it `Press again to turn off` for this note (any other press disarms it), the second records the topic as seen and writes `enabled: false` to the project file, as `/heads-up off` does (Alex, 2026-10-19, after a read of the builtin's band: its post-dismiss feedback row, helpful / not relevant / couldn't understand, is telemetry nobody reads back, so it was not copied). Turn off is per project by ruling: when the /config row turned the check on, the press silences this project only and the row keeps every other project on (Alex, 2026-10-19, offered the switch-that-turned-it-on rule and declined it).
- Typing a prompt while a note is up is typing past it: the next `typedPastInARow` checks are skipped. Any press resets the counter.

A check that found nothing logs one line (`heads-up: codex · none · 12.4 KB · 27 s`), so every check reports its payload and seat. A check whose seat failed logs the reason once and draws nothing. A transcript holding no prompt, typed or submitted by a mod on the person's behalf (a teammate pane, an SDK-driven session), is a skipped check: `heads-up: skipped · digest: nothing in the window to review`, logged once per reason, no band, no seat asked, not counted.

Call sites in `pane.tsx`, the whole shell:

```ts
on('turn.step', async ($, e, next) => {
  const result = next(e)                                     // the request is never delayed
  if (e.agentId === undefined) void logFailure($, state, () => stepHeadsUp($, e))
  return result
})
// stepHeadsUp: session = (await $.state.get(HEADS_UP)).value ?? FRESH_SESSION; decide; write back on a change
// poll(): if (session.phase.kind === 'checking') await pollHeadsUp($)
// AbovePrompt, after finished and retry, before the progress band:
//   const band = bandView((await $.state.get(HEADS_UP)).value?.phase)   // a render read subscribes the band
//   if (band) return headsUpRow(ui, band, presses)
// prompt.submit (composer | bridge): typed past while showing| bridge): typed past while showing; the one-shot tell-Claude context
```

`$.state` owns `Session`; nothing in the closure mirrors it. Events and presses write it, the render reads it, and a read during a render subscribes that render, so no `$.ui.invalidate` call is needed for the band.

## Shape

Data first. Three owners and nothing else:

| State | Owner | Where | Why |
|---|---|---|---|
| `Memory` {seen, known, typedPastInARow, looksToSkip} | `applyAnswer` | `$.store['heads-up']` | crosses sessions like the builtin; lists capped at 50, counters global like the builtin |
| `Session` {turnBase, offeredTurn, phase} | pane shell via `decide` and `settle` | `$.state` (`PluginState['claude-council']['headsUp']`) | per session, survives hot reload; `phase` is a tagged union so "checking and showing at once" cannot be represented |
| run files | `scripts/heads-up.sh` | `council-mod.<sid>/heads-up/<checkId>/` | detached worker output; `result.json` written to a temp name and moved, `.done` last |

Flow: `turn.step` on main → `decide` (pure) → `launch` writes `avoid.txt`, forks `heads-up.sh --session <id>` → the worker resolves the transcript with `session-transcript.sh`, builds the digest with `transcript-digest.sh --tool-results`, asks the seat once → `result.json` + `.done` → the heads-up's own poll timer (started at the launch) → `parseRunResult` (the only place the wire shape is read) → `settle` → `bandView` → row.

Load-bearing decisions:

- **Digest = Path A, `transcript-digest.sh` extended with `--tool-results K --tool-result-chars N`, off by default.** One privacy filter, already under 37 tests, stays the single source of truth (per boundary-discipline). A TS filter over `$.session.messages()` would be a second copy of the same policy with no origin field to build it on. The mod passes `$.session.id()` (the main session's id, so the subagent trap `/advise` documents does not apply) and the runner resolves it through `session-transcript.sh`, the one resolver. `turn.step` fires after the previous records were appended, so the lag is one unanswered `tool_use` at most. Tool results: the last K=8 whose `tool_use` sits inside the `last:5` window, text only, 2000 characters each (jq slices codepoints), tool name kept and inputs left out, `is_error` shown as `[error]`, AskUserQuestion results skipped because `ANSWER_FILTER` already covers them. A Write or Edit result is a one-line acknowledgement, so its slot carries the Write's `content` or the Edit's `new_string` instead, under `Tool result · <name> · <file_path>`, and still counts toward K and the cap. A failed Write or Edit, and an Edit that deletes, keep their result. No other tool input goes. Measured on the largest transcript: about 7.3 KB of turns plus about 5 KB of results, 12.7 KB in all, 27 KB worst case; both under the 32K argv ceiling, and the codex path uses stdin anyway. `/advise` and its tests keep their meaning; new tests pin the opposite rule under the flag, and that peer and notification rows stay out.
- **Cadence reads the step's index in its turn.** `turn.step` carries `index`, the request's position in the turn from 0; the check fires when it is a positive multiple of `every`. The first design read `messageCount` deltas instead, taking a tool step for two messages; measured live (2026-10-19) the count grew by 14, 10 and 9 per step, since it counts every message the request carries, so a multiple of 6 landed by luck and a four-tool turn never checked. `Session.turnBase` went with it.
- **Offered-this-turn is stamped when a note lands, not when a check launches.** A NONE result leaves later cadence points of the same turn free to check again; several seat calls per long turn are accepted by ruling. `phase: checking` alone keeps checks from overlapping. A note that lands after its turn ended stamps the turn it was launched in.
- **Runner = `scripts/heads-up.sh`, the stop gate's direct-exec pattern, one seat.** `query-council.sh` joins every seat, caches, falls back to sibling models and merges stderr into answers; each of those contradicts "the named seat answered".
- **Codex NONE is structural: a direct `codex exec --json --output-schema` inside the runner, prompt on stdin, success gated on a `turn.completed` event** (codex exits 0 on SIGTERM). The schema `{none, tag, topic, headline, title, points}` is strict-required. Other seats get a first-line `NONE` / `NOTE:` + `TAG:` + `TOPIC:` + `TITLE:` + `POINT:` lines contract and the builtin's NONE regex; an off-contract reply is an error, never shown. The shared `providers/codex.sh` is untouched: a schema mode there would be a second way to call codex for one caller.
- **The seat list has one owner: `provider_allowlisted` in `lib/providers.sh`, derived from the registry the library already holds (a plain-word name whose `providers/<name>.sh` exists), not a third hand-written list.** `stop-review-gate.sh` moves onto it in this change. TypeScript checks only the name's shape (`^[a-z][a-z0-9-]+$`, so a name cannot carry a path) and never holds the list.
- **Errors fail open, reported once.** A seat timeout or error writes `kind: failed` with the reason, which the pane logs through `logFailure`. The band never nags about infrastructure. Deadline: 60 s for the seat, counted in ticks of `sleep 1`, never `$((SECONDS+N))`.
- **Learn more expands in place; tell Claude fills the prompt box.** Two presses, because reading more and telling Claude are different decisions. `$.prompt.submit` would start a turn the person did not ask for, and a hidden `prompt.submit` context vanished without a trace when pressed (seen live). `$.prompt.fill` puts a draft the person can read, edit and send, which is the builtin's behaviour and the promise: the main agent learns of a note only through the person.
- **Typed past = a `prompt.submit` whose `origin.kind` is `composer` or `bridge` while a note shows.** This plugin's own submits and continuation turns do not count. Turn end alone does not either: the person may not have looked yet.
- **Band priority: after finished and retry, before the progress band.** A note is one row and time-sensitive; the progress band returns when it is answered. Controls carry full-strength hotkey labels, no `dimColor`.
- **Settings: the file only.** A userConfig row would be a second switch, and `$.config.set` reloads the module.

Depth: `heads-up.ts` exports the types and eleven pure functions that hide cadence, backoff, dedupe, result validation and the band's words; `pane.tsx` calls `decide`, `settle`, `parseRunResult`, `bandView`, `applyAnswer` and `learnMoreContext` and never inspects a counter. `heads-up.sh` hides the codex schema handshake, the deadline and payload measuring behind one command with four flags and an optional `--model`.

## Synthesis decision

Base: candidate 1 (opus), judged 16/18 by a fable cross-judge and by my own reading: Path A behind an off-by-default flag, the cleanest single-owner table, Learn more without an unasked turn. Grafted from candidate 2 (fable, 15/18): the `$.state` + `PluginState` wiring, typed-past on `composer|bridge` (candidate 1's `human` kind does not exist), `provider_allowlisted` as the one seat list (candidate 1's TS `Seat` union was a hand-synced copy), `result.json` written to a temp name and moved, the NONE log line with seat, KB and seconds, offered-this-turn stamped on a drawn note, the `(2 * index) % every` cadence mapping, and the test case list with a fake codex that writes the `-o` file. From candidate 3 (sonnet, 12/18): `next(e)` before the check so the request is never delayed, and the explicit "the pane's drawing is untested" line. From candidate 4 (haiku, 11/18): a total run budget beside the per-seat one, and an `invalid` config variant logged once. Rejected: Path B digests (candidates 2 and 3; no origin field to filter on), `$.prompt.submit` on Learn more (candidates 2 and 3; an unasked turn), a `prompt.fill` draft (candidate 4; `isFilled: false` under a dialog), per-project memory keys (candidate 4; the builtin's memory is global), config knobs for window and caps (candidate 3; YAGNI, the runner's env carries them).

## Tradeoffs accepted

- We accept transcript-on-disk freshness (one unanswered `tool_use` at most) in exchange for one privacy filter instead of two.
- We accept that a seat's failure shows only in the log in exchange for never interrupting a turn with an error.
- We accept last-writer-wins on the store's counters across concurrent sessions (lists are union-merged) in exchange for no per-session store keys; a lost backoff increment is harmless.
- We accept no per-check consent prompt (ruling); the meta line shows bytes and seat every time, and a NONE check logs them.
- We accept touching `stop-review-gate.sh` in a feature change so the seat list has one owner; its 15 tests cover the move.
- We accept that the pane's drawing of the row is untested beyond its pure `bandView` words.

## Alternatives considered

- Path B (`$.session.messages()` + a TS filter): fresher and no path resolution, but `SessionMessage` has no origin field, so human and peer rows are told apart only by tag heuristics; a leak shows up only when the two filters drift. Lost on privacy. A future Path B needs a `session.append` listener, the one surface that carries origin and `isMeta`.
- A schema mode inside `providers/codex.sh`: one codex entry point, but a mode flag on a script every seat path shares, for one caller. Lost on blast radius.
- `query-council.sh --no-cache --no-pane` as the runner: parallel joins, fallback models and merged stderr; the answering seat stops being the named one. Lost.
- Learn more opens the council pane with the detail: the main agent never learns of it, and the pane is heavy UI for 600 characters. Lost.

## Implementation reconciliation

Accepted deviations, each by the lead on merge (2026-10-18):

- `Session`, `Phase` and `Note` live in `types/index.d.ts`, not `heads-up.ts`: `claude plugin validate` refuses a `$.state` key unless the manifest names a self-contained contract, and a contract cannot import. `plugin.json` names it under `types`. The mod needs Claude Code 2.1.302 or later (`$.state`, `atom`, `read`, `update`).
- `phase: checking` is written before the runner forks and reset to idle when the fork fails, so a step landing while the runner starts cannot launch a second check. The step's write carries `ifVersion`; a stale step does nothing.
- The check polls on its own 500 ms timer, started at the launch and stopped once nothing is checking and its failure notice has expired, so a check starts none of the council's timers; a reload with a check in flight restarts it at `session.start`. A run dir that vanishes without a result, or a dead worker without `.done`, settles as `failed`.
- Only a none, skipped or failed check logs its line; a note shows its bytes and seat on the band, which is the ruling's report.
- The runner's `--transcript PATH` became `--session ID`, resolved inside through `session-transcript.sh`. A failure before the seat ran (no transcript) is `kind: failed, bytes: 0, seats: []` with a top-level `detail`; `parseRunResult` reads it as the runner's own outcome. An empty digest is `kind: skipped` with the same `detail` shape (Alex, 2026-10-21): a cs rotation opens the new conversation with plugin-submitted prompts, and the digest's window on typed prompts alone saw nothing there, so every cadence point in the continued turn drew a red failure until the person typed. The digest now anchors its window on a typed prompt or one cs submitted in the person's own session (`origin.kind` plugin named cs or cs-rotate; those are command echoes with no prose, so they anchor without being shown, and other mods' prompts neither anchor nor show, as a Slack bot's carries other people's messages); peer messages and task notifications stay out as before. A transcript with neither has nobody to warn, which is a skip, not a fault. In a cs-opened conversation the window runs from the rotation prompt to the end, so the digest is larger: over 30 days on Alex's Mac, cs-opened p90 25 KB and max 79 KB against typed-opened p90 16 KB. Measured 2026-10-21: that 79 KB digest (86.5 KB prompt) got a note from codex `gpt-6-astra` in 17.7 s at `high`, 22.2 s at `low` and 56.9 s at `xhigh`, the same finding and points each time, so the 60 s deadline holds, no cap was added, and the runner keeps passing no effort unless the project file names one (a lower default bought nothing on this sample; `xhigh` sits at the deadline on the largest digests seen).
- Text seats get `COUNCIL_TIMEOUT` of the seat limit plus five seconds, so the runner's tick watchdog decides the timeout and the provider's own deadline is a backstop.
- The NONE regex for bash is `([].!?():;,[-]|$)`: a backslash is literal inside a bracket, so the builtin's `[.!?()\[\]:;,-]` never matched "NONE." there.
- The digest admits a tool-result row only when it has no `origin.kind` and no `isMeta` (unknown shapes refused, not known bad ones listed); tool names lose newlines and `\u0001` before they become a heading; a result whose text is empty still takes one of the K slots; `--tool-result-chars` without `--tool-results` is refused.
- `provider_allowlisted` is derived (a plain-word name whose `providers/<name>.sh` exists), which admits `claude-cli` and `copilot-cli` to the stop gate where the old hand-written list did not.
- `now_ms` moved to `scripts/lib/clock.sh` on its third copy.

- `every` counts model requests, not messages, after the live measurement above; default 3.
- A `/config` row `heads_up` joined the project file as a second switch (Alex, 2026-10-19: the file alone was undiscoverable); `parseConfig(text, rowOn)` holds the rule, a broken file stays off with the row on too.
- `/heads-up [on [seat,...] | off | status]` (Alex, 2026-10-19; its seat list, `models` map and `--models` flag are superseded by the one-seat ruling below): on and off write the project file through `withEnabled`, on with seats sets them (the tip must not read as codex-only, Alex), status prints `statusText`. Usage counts live in the store under `heads-up-counts`, a read-add-write per event (a concurrent bump can lose one; the numbers guide the dogfood decision, they are not billing), and are shown by this command rather than by `/claude-council:status`, whose bash script cannot read the plugin store. A seat may carry a model and, for codex, an effort (Alex, 2026-10-19): the file's `models` map, the runner's `--models`, `seat_model_var` in the runner mapping a seat to the variable `get_model` reads. `/heads-up setup` is a run of `$.ui.ask` dialogs (Alex asked for a wizard and whether a dialog beats a pane: for three questions it does, native look and no form plumbing; the four-option cap is covered by Other taking a typed list). A NONE check's receipt moved from a transcript row to the `PromptHint` tail (Alex: the row was noise); a failed check still logs. A once-per-install introduction (`introTail`) rides the `PromptHint` tail while the prompt is empty and the check is off; Alex found a transcript row for it ugly, and the engine's own prompt placeholder and InfoNotice rows are not a plugin's to write.
- The expanded note is the builtin's shape, a title and bullets, in place of the first cut's two or three sentences; `detail` became `title` and `points` on the wire (Alex, 2026-10-19, from a side-by-side with the builtin).
- One seat replaces the ordered panel (Alex, 2026-10-19): `seats codex, gemini` read as a panel when gemini was only a fallback. The file names `seat` and its one pick under `model`; a `seats` or `models` key keeps the check off with a problem naming the key, and nothing reads the old shape. `/heads-up on [seat]` takes one word, and naming a seat other than the file's drops the file's `model`, which belonged to the old seat. Setup asks a single-select seat question, then that seat's model and codex's effort once. The runner takes `--seat NAME` and `--model FILE`, asks once, and lost the 180 s run budget along with the seat loop; the `result.json` wire shape is unchanged, its `seats` list holding the one outcome.

Unresolved: the pane's drawing, the poll and the hook wiring have no automated test.

## Open questions and risks

- Is 60 s right for the seat? Should a note that lands after `turn.complete` still show? Proposed: yes, while the session is idle.
- A check reads the transcript as it stood mid-turn and answers 15 to 40 s later, so a note can land after the main agent's final reply has covered the point (seen live 2026-10-19: the 0.0.0.0 note arrived as the test Claude's own caveat printed). The builtin shares the race. When judging the dogfood week, count a note as a hit only when the final reply left it out; if duplicates are frequent, re-read the transcript before drawing the band.
- Topic dedupe is exact, case-folded, on the seat's own `topic`. If a seat rephrases, repeats get through; the `AVOID` list in the prompt is the first defence.
- Risk: codex time scales with prompt size; the first real measurement on a 13 KB digest decides the default deadline.

## Next implementation step

Add `--tool-results K --tool-result-chars N` to `transcript-digest.sh`, with bats tests written first: peer rows excluded, AskUserQuestion not duplicated, cap at 2000 characters, `[error]` shown, off by default.
