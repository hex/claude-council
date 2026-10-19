# Heads-up side-check design

The "You should know" side-agent: while Claude works a long turn, a council seat rereads the conversation and surfaces at most one thing the person may have missed, above the prompt, without the main agent seeing it unless the person asks. Synthesized from a four-candidate architect arena on 2026-10-18; the rulings below are Alex's and fixed.

## Problem

The trigger must leave its hook within milliseconds (`turn.step` runs before every model request), but a codex call takes about 27 s per 8 KB of prompt, so the check runs in a self-detaching script and the pane polls for its result, as council runs and specialist rounds already do. Codex ignores a prose output contract (measured: it opened with "Alex," under its `~/.codex` AGENTS.md instead of answering NONE), so NONE must be structural for that seat. The digest now carries tool results, which the existing `transcript-digest.sh` keeps out on purpose (its tests at :64 and :342 pin that), and `$.session.messages()` carries no origin field, so a live-memory digest cannot tell a human prompt from a peer message. `$.store` is shared by every session, `$.state.set` is refused during a render, `$` may only reach top-level functions, and the AbovePrompt band is one instance drawn by one hook.

Rulings (fixed): codex by default, a per-project panel, first non-NONE in seat order, no synthesis; consent is the opt-in project file alone (amended 2026-10-19 by Alex: a `/config` row is a second switch, the file can still say no per project), no preview, the note shows payload size and seat; mid-turn trigger with the builtin's cadence, backoff and NONE test; the last few tool results in the digest capped near 2 KB each, peer messages excluded; shipped in this plugin.

## Usage (caller's view)

Opt in once per project:

```json
// .claude/council-heads-up.json   (malformed: off; absent: the /config row decides)
{ "enabled": true, "seats": ["codex"], "every": 3 }
```

`seats` defaults to `["codex"]`; `every` is model requests per check, default 3. The `/config` row `heads_up` (off by default) turns the check on in every project; the file's `enabled: true` turns it on for one project, `enabled: false` turns it off there whatever the row says, and an absent `enabled` follows the row. Either switch is the consent.

During a long turn, above the prompt:

```
✦ Heads up · The migration test passed against the empty fixture DB, so the backfill path never ran.
  codex · gpt-6.1-sol · 12.4 KB · 27 s      1: Learn more   2: Knew this already   0: Dismiss
```

- `1` expands the band the way the builtin does: a bold title (80 characters) and three to six bullets (200 characters each, under 120 words together), the last one the action, drawn bold. The expanded band offers `1 · tell Claude` and `0 · close`; `tell Claude` puts a draft quoting the note in the prompt box ("A side check by codex (not you) raised this: <headline> <title>: <bullets> What do you make of it?"), as the builtin does, and the person sends or edits it. Reading the note alone tells Claude nothing, and nothing is submitted on the person's behalf.
- `2` records the topic as known; `0` as seen. Both are fed back so no seat raises it again.
- Typing a prompt while a note is up is typing past it: the next `typedPastInARow` checks are skipped. Any press resets the counter.

A check that found nothing logs one line (`heads-up: codex · none · 12.4 KB · 27 s`), so every check reports its payload and seat. A check whose seats all failed logs the reasons once and draws nothing.

Call sites in `pane.tsx`, the whole shell:

```ts
on('turn.step', async ($, e, next) => {
  const result = next(e)                                     // the request is never delayed
  if (e.agentId === undefined) void logFailure($, state, () => stepHeadsUp($, e))
  return result
})
// stepHeadsUp: session = (await $.state.get(HEADS_UP)).value ?? FRESH_SESSION; decide; write back on a change
// poll(): if (session.phase.kind === 'checking') await pollHeadsUp($)
// AbovePrompt, after finished and retry, before the specialist and progress bands:
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

Flow: `turn.step` on main → `decide` (pure) → `launch` writes `avoid.txt`, forks `heads-up.sh --session <id>` → the worker resolves the transcript with `session-transcript.sh`, builds the digest with `transcript-digest.sh --tool-results`, asks seats in order → `result.json` + `.done` → the pane's poll timer (started lazily) → `parseRunResult` (the only place the wire shape is read) → `settle` → `bandView` → row.

Load-bearing decisions:

- **Digest = Path A, `transcript-digest.sh` extended with `--tool-results K --tool-result-chars N`, off by default.** One privacy filter, already under 37 tests, stays the single source of truth (per boundary-discipline). A TS filter over `$.session.messages()` would be a second copy of the same policy with no origin field to build it on. The mod passes `$.session.id()` (the main session's id, so the subagent trap `/advise` documents does not apply) and the runner resolves it through `session-transcript.sh`, the one resolver. `turn.step` fires after the previous records were appended, so the lag is one unanswered `tool_use` at most. Tool results: the last K=8 whose `tool_use` sits inside the `last:5` window, text only, 2000 characters each (jq slices codepoints), tool name kept and inputs left out, `is_error` shown as `[error]`, AskUserQuestion results skipped because `ANSWER_FILTER` already covers them. Measured on the largest transcript: about 7.3 KB of turns plus about 5 KB of results, 12.7 KB in all, 27 KB worst case; both under the 32K argv ceiling, and the codex path uses stdin anyway. `/advise` and its tests keep their meaning; new tests pin the opposite rule under the flag, and that peer and notification rows stay out.
- **Cadence reads the step's index in its turn.** `turn.step` carries `index`, the request's position in the turn from 0; the check fires when it is a positive multiple of `every`. The first design read `messageCount` deltas instead, taking a tool step for two messages; measured live (2026-10-19) the count grew by 14, 10 and 9 per step, since it counts every message the request carries, so a multiple of 6 landed by luck and a four-tool turn never checked. `Session.turnBase` went with it.
- **Offered-this-turn is stamped when a note lands, not when a check launches.** A NONE result leaves later cadence points of the same turn free to check again; several seat calls per long turn are accepted by ruling. `phase: checking` alone keeps checks from overlapping. A note that lands after its turn ended stamps the turn it was launched in.
- **Runner = `scripts/heads-up.sh`, the stop gate's direct-exec pattern, sequential seats.** `query-council.sh` joins every seat, caches, falls back to sibling models and merges stderr into answers; each of those contradicts "first non-NONE in seat order, the named seat answered".
- **Codex NONE is structural: a direct `codex exec --json --output-schema` inside the runner, prompt on stdin, success gated on a `turn.completed` event** (codex exits 0 on SIGTERM). The schema `{none, tag, topic, headline, title, points}` is strict-required. Other seats get a first-line `NONE` / `NOTE:` + `TAG:` + `TOPIC:` + `TITLE:` + `POINT:` lines contract and the builtin's NONE regex; an off-contract reply is an error, never shown. The shared `providers/codex.sh` is untouched: a schema mode there would be a second way to call codex for one caller.
- **The seat list has one owner: `provider_allowlisted` in `lib/providers.sh`, derived from the registry the library already holds (a plain-word name whose `providers/<name>.sh` exists), not a third hand-written list.** `stop-review-gate.sh` moves onto it in this change. TypeScript checks only the name's shape (`^[a-z][a-z0-9-]+$`, so a name cannot carry a path) and never holds the list.
- **Errors fail open, reported once.** A seat timeout or error moves to the next seat; all seats failing writes `kind: failed` with each reason, which the pane logs through `logFailure`. The band never nags about infrastructure. Deadlines: 60 s per seat, 180 s per run, counted in ticks of `sleep 1`, never `$((SECONDS+N))`.
- **Learn more expands in place; tell Claude fills the prompt box.** Two presses, because reading more and telling Claude are different decisions. `$.prompt.submit` would start a turn the person did not ask for, and a hidden `prompt.submit` context vanished without a trace when pressed (seen live). `$.prompt.fill` puts a draft the person can read, edit and send, which is the builtin's behaviour and the promise: the main agent learns of a note only through the person.
- **Typed past = a `prompt.submit` whose `origin.kind` is `composer` or `bridge` while a note shows.** This plugin's own submits and continuation turns do not count. Turn end alone does not either: the person may not have looked yet.
- **Band priority: after finished and retry, before the specialist and progress bands.** A note is one row and time-sensitive; the progress bands return when it is answered. Controls carry full-strength hotkey labels, no `dimColor`.
- **Settings: the file only.** A userConfig row would be a second switch, and `$.config.set` reloads the module.

Depth: `heads-up.ts` exports the types and eleven pure functions that hide cadence, backoff, dedupe, result validation and the band's words; `pane.tsx` calls `decide`, `settle`, `parseRunResult`, `bandView`, `applyAnswer` and `learnMoreContext` and never inspects a counter. `heads-up.sh` hides seat order, the codex schema handshake, deadlines and payload measuring behind one command with four flags.

## Synthesis decision

Base: candidate 1 (opus), judged 16/18 by a fable cross-judge and by my own reading: Path A behind an off-by-default flag, the cleanest single-owner table, Learn more without an unasked turn. Grafted from candidate 2 (fable, 15/18): the `$.state` + `PluginState` wiring, typed-past on `composer|bridge` (candidate 1's `human` kind does not exist), `provider_allowlisted` as the one seat list (candidate 1's TS `Seat` union was a hand-synced copy), `result.json` written to a temp name and moved, the NONE log line with seat, KB and seconds, offered-this-turn stamped on a drawn note, the `(2 * index) % every` cadence mapping, and the test case list with a fake codex that writes the `-o` file. From candidate 3 (sonnet, 12/18): `next(e)` before the check so the request is never delayed, and the explicit "the pane's drawing is untested" line. From candidate 4 (haiku, 11/18): a total run budget beside the per-seat one, and an `invalid` config variant logged once. Rejected: Path B digests (candidates 2 and 3; no origin field to filter on), `$.prompt.submit` on Learn more (candidates 2 and 3; an unasked turn), a `prompt.fill` draft (candidate 4; `isFilled: false` under a dialog), per-project memory keys (candidate 4; the builtin's memory is global), config knobs for window and caps (candidate 3; YAGNI, the runner's env carries them).

## Tradeoffs accepted

- We accept transcript-on-disk freshness (one unanswered `tool_use` at most) in exchange for one privacy filter instead of two.
- We accept a direct codex call that repeats about 15 lines of `specialist.sh` in exchange for leaving `providers/codex.sh` unchanged. A third caller unifies them.
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
- The check rides the council's lazy poll timer; a reload with a check in flight restarts it at `session.start`. A run dir that vanishes without a result, or a dead worker without `.done`, settles as `failed`.
- Only a none or failed check logs its line; a note shows its bytes and seat on the band, which is the ruling's report.
- The runner's `--transcript PATH` became `--session ID`, resolved inside through `session-transcript.sh`. A failure before any seat ran (no transcript, an empty digest) is `kind: failed, bytes: 0, seats: []` with a top-level `detail`; `parseRunResult` reads it as the runner's own outcome. Seats skipped by the run budget are `outcome: timeout` with that reason.
- Text seats get `COUNCIL_TIMEOUT` of the seat limit plus five seconds, so the runner's tick watchdog decides the timeout and the provider's own deadline is a backstop.
- The NONE regex for bash is `([].!?():;,[-]|$)`: a backslash is literal inside a bracket, so the builtin's `[.!?()\[\]:;,-]` never matched "NONE." there. The TypeScript regex is the builtin's.
- The digest admits a tool-result row only when it has no `origin.kind` and no `isMeta` (unknown shapes refused, not known bad ones listed); tool names lose newlines and `\u0001` before they become a heading; a result whose text is empty still takes one of the K slots; `--tool-result-chars` without `--tool-results` is refused.
- `provider_allowlisted` is derived (a plain-word name whose `providers/<name>.sh` exists), which admits `claude-cli` and `copilot-cli` to the stop gate where the old hand-written list did not.
- `now_ms` moved to `scripts/lib/clock.sh` on its third copy.

- `every` counts model requests, not messages, after the live measurement above; default 3.
- A `/config` row `heads_up` joined the project file as a second switch (Alex, 2026-10-19: the file alone was undiscoverable); `parseConfig(text, rowOn)` holds the rule, a broken file stays off with the row on too.
- The expanded note is the builtin's shape, a title and bullets, in place of the first cut's two or three sentences; `detail` became `title` and `points` on the wire (Alex, 2026-10-19, from a side-by-side with the builtin).

Unresolved: the pane's drawing, the poll and the hook wiring have no automated test.

## Open questions and risks

- Is 60 s per seat right when a three-seat panel can then take three minutes? Should a note that lands after `turn.complete` still show? Proposed: yes, while the session is idle.
- A check reads the transcript as it stood mid-turn and answers 15 to 40 s later, so a note can land after the main agent's final reply has covered the point (seen live 2026-10-19: the 0.0.0.0 note arrived as the test Claude's own caveat printed). The builtin shares the race. When judging the dogfood week, count a note as a hit only when the final reply left it out; if duplicates are frequent, re-read the transcript before drawing the band.
- Topic dedupe is exact, case-folded, on the seat's own `topic`. If a seat rephrases, repeats get through; the `AVOID` list in the prompt is the first defence.
- Risk: codex time scales with prompt size; the first real measurement on a 13 KB digest decides the default deadline.

## Next implementation step

Add `--tool-results K --tool-result-chars N` to `transcript-digest.sh`, with bats tests written first: peer rows excluded, AskUserQuestion not duplicated, cap at 2000 characters, `[error]` shown, off by default.
