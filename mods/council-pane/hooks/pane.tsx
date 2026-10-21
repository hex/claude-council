// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import { atom, read, update } from 'claude-code'
import type { Elements, EngineInterface, Register, RenderChildren, Timer } from 'claude-code'
import {
  applyAnswer, avoidList, bandView, checkLine, CONFIG_FILE, decide, onCadence, FRESH_SESSION, mergeMemory, parseConfig, parseMemory, parseRunResult, pressed, settle, STORE_KEY, tellClaudeDraft, typedPast,
  bumped, COMMAND as HEADS_UP_COMMAND, COUNTS_KEY, headsUpCommand, INTRO_KEY as HEADS_UP_INTRO_KEY, introTail, parseCounts, statusText, withEnabled, type Counts,
  seatsFromDiscovery, seatOptions, seatFromAnswer, everyFromAnswer, SCOPE, SCOPE_QUESTION, SEAT_QUESTION, EVERY_QUESTION, EVERY_LABELS, receiptLine, modelFile, type HeadsUpConfig, modelOptions, modelFromAnswer, effortOptions, effortFromAnswer, MODEL_QUESTION, EFFORT_QUESTION, type SeatPick,
  type Answer, type BandView, type Memory, type RunResult,
  EMPTY_MEMORY,
} from './heads-up'
import type { Note, Session } from '../types'
import { decideHost, HOST_LABELS, HOST_QUESTION, HOST_STORE_KEY, hostFrom, hostRowLabel, isCouncilRun, paneCommand, type HostSetting, type PaneHost } from './host'
import { abandonedNotice, FINISH_NOTICE_MS, finishNotice, jobOutcome, noticeIsLive, reopenReply, runPid, wakePrompt, type FinishNotice, progressBand } from './notices'
import { paneOptions, type PaneOptions } from './options'
import { parseRetryOffer, retrySection, type RetryOffer, type RetrySection } from './retry'
import { readText, readView, type Files } from './snapshot'
import { confirmOutcome, confirmQuestion, councilArgs, KEEP_LABEL, SEND_LABEL, TOOL_DESCRIPTION, TOOL_NAME, TOOL_SCHEMA } from './tool'
import { extractSynthesis } from './synthesis'
import { fitTables } from './tables'
import { shimmer } from './chip'
import { markdownBlocks, paneSections, queryingSince, seatFolds, seatsToCancel, unseenRun, type RunView, type Section } from './view'
import { COLOR, FILL } from './theme'
import { parseCatalog } from './catalog'

const PANE_ID = 'council'
const REOPEN_COMMAND = 'council-pane'
const RUN_TIMEOUT_MS = 600_000
const POLL_MS = 500
// Ten frames a second: the spinner's pace in the tmux pane.
const FRAME_MS = 100
// The worker records its result seconds after .done; a worker killed outright
// leaves its record at running, so the wait for it ends.
const WAKE_WAIT_MS = 120_000
// How often a run still going is asked whether its process is alive.
const PID_CHECK_MS = 5_000
// The store keys a specialists feature once kept; its records are removed at
// session start until none is left, then this list can go.
const SPECIALIST_STORE_KEYS = ['specialist-runs', 'specialists-latest', 'specialists-intro-shown']
// Every colour comes from theme.ts; DESIGN.md says which one serves what.
// A section header's mark: open shows its text, closed only the header.
const OPEN_MARK = '\u25be'
const CLOSED_MARK = '\u25b8'
// The /config row that turns the heads-up on for every project, as $.config names it.
const HEADS_UP_ROW_KEY = 'claude-council.heads_up'
// The heads-up runner forks and returns its pid; anything slower is a fault.
const HEADS_UP_LAUNCH_MS = 10_000

// The heads-up side-check's session state is the host's (its contract is
// types/index.d.ts), so a hot reload keeps a check in flight and a note on
// screen; the band reads it while drawing.
const HEADS_UP = { plugin: 'claude-council', key: 'headsUp' } as const
const headsUp = atom(HEADS_UP, FRESH_SESSION)

type PaneState = {
  root: string
  runDir?: string
  view?: RunView
  drawn: string
  isPolling: boolean
  shown: Set<string>
  lastError: string
  pidCheckedAtMs: number
  // When the heads-up check's worker was last asked whether it is alive.
  headsUpCheckedAtMs: number
  // The heads-up's own poll, from a launch until the check settles and its failure notice is gone.
  headsUpTimer?: Timer
  isPollingHeadsUp: boolean
  // The last config problem logged, so a broken file is reported once.
  headsUpProblem: string
  // The last heads-up failure logged (see logFailure).
  lastFailure: string
  // The intro tail on the prompt hint; '' once typed past, turned on, or never due.
  headsUpTip: string
  // The last check that found nothing, on the prompt hint until a keystroke or the next check.
  headsUpReceipt: string
  // The last skipped check logged; the same reason on the next cadence point is not logged again.
  headsUpSkipped: string
  // The last check that failed, drawn in red above the prompt for a while; the transcript keeps the reason.
  headsUpFailure?: FinishNotice
  // The note whose Turn off was pressed once; the second press turns the check off for this project.
  headsUpTurnOffArmed: string
  pendingWake?: { prompt: string; jobFile: string; untilMs: number }
  retry?: { offer: RetryOffer; seenAtMs: number }
  retryShown?: RetrySection
  synthesis?: string
  finished?: FinishNotice
  frame: number
  nowMs: number
  queryingSinceMs: Record<string, number>
  // The sections the person closed, by their fold; each run starts with all open.
  closed: Set<string>
  // When the pane picked the live run up; the progress band's clock.
  runStartedMs?: number
  // Each section's Markdown blocks, for the text they were cut from: a frame
  // redraws the tree, not the markdown.
  fitted: Map<string, { text: string; blocks: string[] }>
  // Each answer as rewritten for the pane's width (wide tables as records),
  // for the width it was rewritten at: a resize starts it over.
  tableFit: { columns: number; byText: Map<string, string> }
}

// The engine refuses $.fs passed as a value, so the snapshot reader gets the
// three calls it needs spelled out.
function files($: EngineInterface): Files {
  return {
    exists: path => $.fs.exists(path),
    read: path => $.fs.read(path),
    list: dir => $.fs.list(dir),
  }
}

// The model and effort lists come from Codex itself; a failure is kept as the
// catalog's error, never an empty list.
async function readCatalog($: EngineInterface) {
  const run = await $.process.run(['codex', 'debug', 'models'], { timeoutMs: 15_000 })
    .catch((err: unknown) => ({ exitCode: 127, stdout: '', stderr: String(err) }))
  return parseCatalog(run)
}

// The engine's own dialogs: scope, seat, cadence, then the seat's model and,
// for codex, its effort. The file is
// written first; "every project" then sets the /config row, which reloads
// this module, so the status that follows may not print.
async function setupHeadsUp($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<string | undefined> {
  const ask = (question: string, options: string[]) => $.ui.ask(question, { header: 'Heads-up', options }).catch(() => undefined)
  const closed = 'Setup closed; nothing changed.'
  const scope = await ask(SCOPE_QUESTION, [SCOPE.project, SCOPE.all, SCOPE.off])
  if (scope === undefined) return closed
  const file = await headsUpFile($)
  if (scope === SCOPE.off) {
    await $.fs.write(file.path, withEnabled(file.text, false))
    return headsUpStatus($, settings.headsUp)
  }
  if (scope !== SCOPE.project && scope !== SCOPE.all) return `Setup closed: ${JSON.stringify(scope)} is not one of the choices; nothing changed.`
  // The council's own discovery, so the seats offered are the seats a council run would seat.
  const discovered = await $.process.run(['bash', '-c', 'export PROVIDERS_DIR="$1/scripts/providers"; source "$1/scripts/lib/keys.sh"; resolve_grok_key; source "$1/scripts/lib/providers.sh"; discover_providers', '_', $.plugin.root])
  if (discovered.exitCode !== 0) return `Setup closed: seat discovery exited ${discovered.exitCode}: ${discovered.stderr.trim()}; nothing changed.`
  const seatAnswer = await ask(SEAT_QUESTION, seatOptions(seatsFromDiscovery(discovered.stdout)))
  if (seatAnswer === undefined) return closed
  const everyAnswer = await ask(EVERY_QUESTION, [...EVERY_LABELS])
  if (everyAnswer === undefined) return closed
  const chosen = seatFromAnswer(seatAnswer)
  if ('why' in chosen) return `Setup closed: ${chosen.why}; nothing changed.`
  const { seat } = chosen
  const unknown = await notASeat($, seat)
  if (unknown !== undefined) return `Setup closed: ${unknown}; nothing changed.`
  const every = everyFromAnswer(everyAnswer)
  if ('why' in every) return `Setup closed: ${every.why}; nothing changed.`
  // The seat's model; codex also takes an effort, from its own catalog.
  const current = (await $.process.run(['bash', '-c', 'source "$1/scripts/lib/providers.sh" && get_model "$2"', '_', $.plugin.root, seat]).catch(() => ({ stdout: '' }))).stdout.trim()
  const catalog = seat === 'codex' ? await readCatalog($) : undefined
  const slugs = catalog !== undefined && 'models' in catalog ? catalog.models.filter(m => m.listed).map(m => m.slug) : undefined
  const modelAnswer = await ask(MODEL_QUESTION(seat), modelOptions(current, slugs))
  if (modelAnswer === undefined) return closed
  const model = modelFromAnswer(modelAnswer)
  let pick: SeatPick = model === undefined ? {} : { model }
  if (seat === 'codex' && catalog !== undefined && 'models' in catalog) {
    const entry = catalog.models.find(m => m.slug === (model ?? current))
    const effortAnswer = await ask(EFFORT_QUESTION, effortOptions(entry?.efforts ?? [], entry?.defaultEffort ?? ''))
    if (effortAnswer === undefined) return closed
    const effort = effortFromAnswer(effortAnswer)
    if ('why' in effort) return `Setup closed: ${effort.why}; nothing changed.`
    if (effort.effort !== undefined) pick = { ...pick, effort: effort.effort }
  }
  // "Keep <current>" with no effort is no pick at all: the file's own model
  // stays, and withEnabled drops it only when the seat changed.
  await $.fs.write(file.path, withEnabled(file.text, scope === SCOPE.project ? true : undefined, seat, every.every, Object.keys(pick).length === 0 ? undefined : pick))
  state.headsUpTip = ''
  if (scope === SCOPE.all && !settings.headsUp) {
    const written = await $.config.set({ key: HEADS_UP_ROW_KEY, value: true })
    if (written.deny) return `The file is written, but the /config row was refused: ${written.deny}`
  }
  return headsUpStatus($, scope === SCOPE.all || settings.headsUp)
}

// What /heads-up status prints, from the project file as it stands.
async function headsUpStatus($: EngineInterface, rowOn: boolean): Promise<string> {
  const { text } = await headsUpFile($)
  return statusText(parseConfig(text, rowOn), rowOn, text, parseCounts(await $.store.get(COUNTS_KEY)))
}

// Once per install, while the check is off: the store flag is shared by every session.
async function introduceHeadsUp($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  const intro = introTail({ shown: (await $.store.get(HEADS_UP_INTRO_KEY)) === true, enabled: (await readHeadsUpConfig($, state, settings)).enabled })
  if (intro.tail !== undefined) {
    state.headsUpTip = intro.tail
    $.ui.invalidate('ui.render')
  }
  if (intro.markShown) await $.store.set(HEADS_UP_INTRO_KEY, true)
}

// Submits the wake prompt once the job's record says completed. A job that
// failed, or whose record never settles, wakes nobody: the prompt would send
// the model to fetch a result that is not there.
async function wakeWhenFetchable($: EngineInterface, state: PaneState): Promise<void> {
  const pending = state.pendingWake
  if (!pending) return
  const outcome = jobOutcome(await readText(files($), pending.jobFile))
  if (outcome === 'running' && (await $.clock.now()) < pending.untilMs) return
  state.pendingWake = undefined
  if (outcome === 'completed') await $.prompt.submit({ text: pending.prompt })
  else $.ui.log(`council job record ${pending.jobFile} did not complete (${outcome}); no wake prompt sent`)
}

// .done comes from the run's EXIT trap, which a SIGKILL skips. A run whose
// process is gone and that left no .done will never write one; without this
// the pane would follow it for the rest of the session and see no later run.
// lastCheck: which clock throttles the check, so the council run and the
// heads-up worker are each asked at the pid cadence.
async function runHasDied($: EngineInterface, state: PaneState, runDir: string, now: number, lastCheck: 'pidCheckedAtMs' | 'headsUpCheckedAtMs' = 'pidCheckedAtMs'): Promise<boolean> {
  if (now - state[lastCheck] < PID_CHECK_MS) return false
  state[lastCheck] = now
  const pid = runPid(await readText(files($), `${runDir}/pid`))
  if (!pid) return false
  const alive = await $.process.run(['kill', '-0', pid])
  if (alive.exitCode === 0) return false
  // The trap writes .done and then the process goes: look once more, so a run
  // that ended normally between the two reads is not called dead.
  return !(await $.fs.exists(`${runDir}/.done`))
}

async function poll($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  // Temp cleaners remove the root under a long session; runs find it again
  // only if it exists, so it is put back rather than reported.
  if (!(await $.fs.exists(state.root))) {
    await $.fs.write(`${state.root}/.keep`, '')
    state.runDir = undefined
    return
  }
  const now = await $.clock.now()
  state.nowMs = now
  if (state.finished && !noticeIsLive(state.finished, now)) {
    state.finished = undefined
    $.ui.invalidate('ui.render')
  }
  if (state.pendingWake) await wakeWhenFetchable($, state)
  if (!state.runDir) {
    const name = unseenRun(await $.fs.list(state.root), state.shown)
    if (!name) return
    state.shown.add(name)
    state.runDir = `${state.root}/${name}`
    state.synthesis = undefined
    state.finished = undefined
    state.queryingSinceMs = {}
    state.closed = new Set()
    state.runStartedMs = now
    state.fitted.clear()
    await $.ui.open({ id: PANE_ID, title: 'Council' })
  }
  const runDir = state.runDir
  state.view = await readView(files($), runDir)
  state.queryingSinceMs = queryingSince(state.queryingSinceMs, state.view.providers, now)
  state.view.queryingSinceMs = state.queryingSinceMs
  if (state.synthesis) state.view.synthesis = state.synthesis
  // The run waits on its offer for a window of seconds; the offer file going
  // away (accepted, declined or expired) withdraws the buttons.
  const offer = parseRetryOffer(await readText(files($), `${runDir}/retry-offer`))
  if (!offer) state.retry = undefined
  else if (!state.retry) state.retry = { offer, seenAtMs: now }
  state.retryShown = state.retry ? retrySection(state.retry.offer, state.retry.seenAtMs, now) : undefined
  const text = JSON.stringify([state.view, state.retryShown])
  if (text !== state.drawn) {
    state.drawn = text
    $.ui.invalidate('ui.render')
  }
  const hasDied = !state.view.isDone && (await runHasDied($, state, runDir, now))
  // A dead run is drawn as over: the spinners stop and the list collapses.
  if (hasDied) state.view = { ...state.view, isDone: true }
  // The run is over once .done lands: its dir is removed so the next run is
  // picked up, and the pane keeps the last view until the person closes it.
  if (state.view.isDone) {
    // A toast is one unstyled line for four seconds, easy to miss under a
    // streaming reply; the band holds the notice where the offer was.
    // The run's dir is visible before the run writes its job files, so they
    // are read now, when they are certain to be there.
    const jobId = (await readText(files($), `${runDir}/job-id`)).trim()
    const notice = hasDied ? abandonedNotice(state.view, jobId) : finishNotice(state.view, jobId)
    state.finished = { text: notice, untilMs: now + FINISH_NOTICE_MS, isFailure: hasDied }
    $.ui.invalidate('ui.render')
    // .done lands before the worker records where the result is, so the wake
    // waits for the job record to say the result can be fetched.
    const wake = settings.wakesOnAsyncDone && !hasDied ? wakePrompt(jobId) : undefined
    const jobFile = (await readText(files($), `${runDir}/job-file`)).trim()
    if (wake && jobFile) state.pendingWake = { prompt: wake, jobFile, untilMs: now + WAKE_WAIT_MS }
    await $.process.run(['rm', '-rf', runDir])
    state.runDir = undefined
    state.retry = undefined
    state.retryShown = undefined
  }
}

// Advances the spinner and the clock the elapsed times read, only while a
// provider is still querying; an idle pane costs no redraws.
async function animate($: EngineInterface, state: PaneState): Promise<void> {
  const view = state.view
  if (!view || view.isDone || !view.providers.some(provider => provider.state === 'querying')) return
  state.frame += 1
  state.nowMs = await $.clock.now()
  $.ui.invalidate('ui.render')
}

// Settles where this run's pane goes, asking once when the setting says ask
// and nothing is remembered. A dismissed dialog or a headless run stores
// nothing and the pane is drawn here, so the question comes back.
async function paneHost($: EngineInterface, setting: HostSetting): Promise<PaneHost> {
  const remembered = hostFrom(await $.store.get(HOST_STORE_KEY))
  const decided = decideHost({ setting, remembered, isInTmux: Boolean(await $.env.get('TMUX')) })
  if (decided !== 'ask') return decided
  let asked: PaneHost | undefined
  try {
    asked = hostFrom(await $.ui.ask(HOST_QUESTION, { header: 'Council pane', options: [HOST_LABELS.mod, HOST_LABELS.tmux] }))
  } catch {
    asked = undefined
  }
  if (asked) await $.store.set(HOST_STORE_KEY, asked)
  return asked ?? 'mod'
}

// Points the next run at this mod's pane or away from it; a Bash child reads
// the variable when it starts, so this runs just before one does.
// The watch root and the two timers start with the first council run, not the
// session: a session that never convenes the council pays no polling and
// leaves no directory behind.
async function watchRoot($: EngineInterface): Promise<string> {
  const tmp = ((await $.env.get('TMPDIR')) ?? '/tmp').replace(/\/+$/, '')
  return `${tmp}/council-mod.${await $.session.id()}`
}

async function startWatching($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  if (state.root) return
  state.root = await watchRoot($)
  await $.fs.write(`${state.root}/.keep`, '')
  $.clock.every(FRAME_MS, () => { void animate($, state) })
  $.clock.every(POLL_MS, () => { void pollOnce($, state, settings) })
}

async function aimRun($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  await startWatching($, state, settings)
  const host = await paneHost($, settings.host)
  await $.env.set('COUNCIL_MOD_PANE_DIR', host === 'mod' ? state.root : undefined)
}

// Logs a line once per distinct text: a condition that persists across polls or
// steps is told once, and told again when it changes or returns after clearing.
function logOnChange($: EngineInterface, state: PaneState, key: 'lastFailure' | 'lastError' | 'headsUpProblem' | 'headsUpSkipped', line: string): void {
  if (line !== '' && line !== state[key]) $.ui.log(line)
  state[key] = line
}

// A heads-up background failure is logged once per distinct message, never dropped.
async function logFailure($: EngineInterface, state: PaneState, work: () => Promise<void>): Promise<void> {
  try {
    await work()
    state.lastFailure = ''
  } catch (error) {
    logOnChange($, state, 'lastFailure', `heads-up: ${String(error)}`)
  }
}

async function pollOnce($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  if (state.isPolling) return
  state.isPolling = true
  try {
    await poll($, state, settings)
    state.lastError = ''
  } catch (error) {
    // The poll repeats twice a second: a failure that persists is logged once.
    logOnChange($, state, 'lastError', String(error))
  } finally {
    state.isPolling = false
  }
}

// Every session shares the heads-up memory: a write merges the lists with
// what another session wrote meanwhile and keeps this session's counters.
async function loadMemory($: EngineInterface): Promise<Memory> {
  return parseMemory(await $.store.get(STORE_KEY))
}

async function saveMemory($: EngineInterface, ours: Memory): Promise<void> {
  await $.store.set(STORE_KEY, mergeMemory(await loadMemory($), ours))
}

async function recordAnswer($: EngineInterface, topic: string, answer: Answer): Promise<void> {
  await saveMemory($, applyAnswer(await loadMemory($), topic, answer))
  await count($, answer === 'typed-past' ? 'typedPast' : answer === 'turn-off' ? 'turnOff' : answer)
}

// Read, add one, write: a count, never a lock (see Counts).
async function count($: EngineInterface, ...keys: (keyof Counts)[]): Promise<void> {
  await $.store.set(COUNTS_KEY, bumped(parseCounts(await $.store.get(COUNTS_KEY)), ...keys))
}

// The runner's own allowlist (a providers/<seat>.sh exists) decides what a
// seat is, so no second list lives here; the refusal names the real ones.
async function notASeat($: EngineInterface, seat: string): Promise<string | undefined> {
  const ok = await $.process.run(['bash', '-c', 'source "$1/scripts/lib/providers.sh" && provider_allowlisted "$2"', '_', $.plugin.root, seat])
  if (ok.exitCode === 0) return undefined
  const names = (await $.fs.list(`${$.plugin.root}/scripts/providers`)).map(entry => entry.name).filter(name => name.endsWith('.sh')).map(name => name.slice(0, -3)).sort()
  return `${JSON.stringify(seat)} is not a council seat; one of ${names.join(', ')}`
}

// The project file is the consent and the only switch; it is read at each
// step, so turning it on or off needs no reload. A broken file is logged once.
async function headsUpFile($: EngineInterface): Promise<{ path: string; text: string | undefined }> {
  const path = `${await $.session.cwd()}/${CONFIG_FILE}`
  return { path, text: (await $.fs.exists(path)) ? await $.fs.read(path) : undefined }
}

async function readHeadsUpConfig($: EngineInterface, state: PaneState, settings: PaneOptions) {
  const config = parseConfig((await headsUpFile($)).text, settings.headsUp)
  logOnChange($, state, 'headsUpProblem', config.enabled ? '' : config.problem ?? '')
  return config
}

// Writes the avoid list and forks the runner, which returns once its worker
// is detached; an exit that is not 0 leaves nothing behind and is reported.
async function launchHeadsUp($: EngineInterface, config: Extract<HeadsUpConfig, { enabled: true }>, runDir: string, avoidFile: string): Promise<void> {
  const args = ['--run-dir', runDir, '--session', await $.session.id(), '--seat', config.seat, '--avoid-file', avoidFile]
  const pick = modelFile(config)
  if (pick !== '') {
    await $.fs.write(`${runDir}/model.json`, pick)
    args.push('--model', `${runDir}/model.json`)
  }
  const run = await $.process.run(['bash', `${$.plugin.root}/scripts/heads-up.sh`, ...args], { timeoutMs: HEADS_UP_LAUNCH_MS })
  if (run.exitCode === 0) return
  await $.process.run(['rm', '-rf', runDir])
  throw new Error(`heads-up.sh exited ${run.exitCode}: ${run.stderr.trim()}`)
}

// One main-loop step: decide, write the session when it changed, and launch
// on a cadence point. The session says checking before the fork, so a step
// that lands while the runner starts cannot launch a second check.
async function stepHeadsUp($: EngineInterface, state: PaneState, settings: PaneOptions, step: { turnId: string; index: number }): Promise<void> {
  const config = await readHeadsUpConfig($, state, settings)
  // decide skips these two before reading anything else, so most steps cost
  // one file read and nothing more.
  if (!config.enabled || !onCadence(config.every, step.index)) return
  const memory = await loadMemory($)
  const now = await $.clock.now()
  const held = await $.state.get(HEADS_UP)
  const decision = decide(config, held.value ?? FRESH_SESSION, memory, step, now)
  if (decision.kind === 'skip' && decision.why === 'backoff') await saveMemory($, decision.memory)
  if (decision.kind !== 'launch') return
  const runDir = `${await watchRoot($)}/heads-up/${decision.checkId}`
  // The run dir exists before the session says `checking`: a poll that lands
  // in between would otherwise read a dir that is not there yet as a run
  // that vanished, and idle the session under the launch.
  const avoidFile = `${runDir}/avoid.txt`
  await $.fs.write(avoidFile, avoidList(memory))
  const session: Session = { ...(held.value ?? FRESH_SESSION), phase: { kind: 'checking', turnId: step.turnId, checkId: decision.checkId, runDir, startedMs: now } }
  // A press or a poll wrote in between: this step's reading is stale, and
  // the next step decides again on the new session.
  const written = await $.state.set(HEADS_UP, session, { ifVersion: held.version })
  if (!written.isSet) {
    await $.process.run(['rm', '-rf', runDir])
    return
  }
  watchHeadsUp($, state)
  try {
    await launchHeadsUp($, config, runDir, avoidFile)
  } catch (error) {
    await update($, headsUp, (s): Session => (s.phase.kind === 'checking' && s.phase.checkId === decision.checkId ? { ...s, phase: { kind: 'idle' } } : s))
    // A check that never started is a failed check to the person: red above the prompt, counted as one, and logged by the caller.
    state.headsUpFailure = { text: `heads-up: failed · ${String(error)}`, untilMs: now + FINISH_NOTICE_MS, isFailure: true }
    $.ui.invalidate('ui.render')
    await count($, 'failed')
    throw error
  }
}

// The heads-up check polls on its own timer, so a check starts none of the
// council's: started at a launch, and again at session.start when a reload
// finds a check in flight. It stops once nothing is checking and no failure
// notice is left to expire.
function watchHeadsUp($: EngineInterface, state: PaneState): void {
  if (state.headsUpTimer) return
  state.headsUpTimer = $.clock.every(POLL_MS, () => { void logFailure($, state, () => headsUpTick($, state)) })
}

async function headsUpTick($: EngineInterface, state: PaneState): Promise<void> {
  if (state.isPollingHeadsUp) return
  state.isPollingHeadsUp = true
  try {
    const now = await $.clock.now()
    if (state.headsUpFailure && !noticeIsLive(state.headsUpFailure, now)) {
      state.headsUpFailure = undefined
      $.ui.invalidate('ui.render')
    }
    const phase = (await read($, headsUp)).phase
    if (phase.kind === 'checking') await pollHeadsUp($, state, phase, now)
    else if (!state.headsUpFailure) {
      state.headsUpTimer?.cancel()
      state.headsUpTimer = undefined
    }
  } finally {
    state.isPollingHeadsUp = false
  }
}

// A result once .done lands, or a failure when the worker or its dir is gone
// without one. Every check's dir is removed.
async function pollHeadsUp($: EngineInterface, state: PaneState, phase: Extract<Session['phase'], { kind: 'checking' }>, now: number): Promise<void> {
  const { runDir, checkId } = phase
  const lost = (detail: string): RunResult => ({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: now - phase.startedMs, detail }] })
  let result: RunResult
  if (await $.fs.exists(`${runDir}/.done`)) result = parseRunResult(checkId, await readText(files($), `${runDir}/result.json`))
  else if (!(await $.fs.exists(runDir))) result = lost(`its run dir ${runDir} is gone`)
  else if (await runHasDied($, state, runDir, now, 'headsUpCheckedAtMs')) result = lost('heads-up.sh stopped without writing a result')
  else return
  // settle reads memory only to spot a repeated note.
  const memory = result.kind === 'note' ? await loadMemory($) : EMPTY_MEMORY
  const settled = await update($, headsUp, s => (s.phase.kind === 'checking' && s.phase.checkId === checkId ? settle(s, memory, result) : s))
  if (result.kind === 'failed') {
    $.ui.log(checkLine(result))
    state.headsUpFailure = { text: checkLine(result), untilMs: now + FINISH_NOTICE_MS, isFailure: true }
    $.ui.invalidate('ui.render')
  }
  if (result.kind === 'none') {
    state.headsUpReceipt = receiptLine(result)
    $.ui.invalidate('ui.render')
  }
  // Nobody to warn is not a fault: one log line per reason, no band, no outcome counted.
  logOnChange($, state, 'headsUpSkipped', result.kind === 'skipped' ? checkLine(result) : '')
  const drawn = settled.phase.kind === 'showing' && settled.phase.note.id === checkId
  if (result.kind !== 'skipped') await count($, result.kind !== 'note' ? result.kind : drawn ? 'notes' : 'repeats')
  await $.process.run(['rm', '-rf', runDir])
}

// A press on the band: the session moves, and the shown topic is recorded.
// Tell Claude puts a draft in the prompt box, as the builtin does, so the
// person sees what Claude will get and sends it themselves; nothing is hidden
// and nothing is sent. A box that cannot take it (a dialog up, headless) is
// reported once, since the note is gone by then.
async function pressHeadsUp($: EngineInterface, answer: Exclude<Answer, 'typed-past'>): Promise<void> {
  const shown: { note?: Note } = {}
  await update($, headsUp, s => {
    shown.note = s.phase.kind === 'showing' ? s.phase.note : undefined
    return pressed(s, answer)
  })
  if (shown.note === undefined) return
  await recordAnswer($, shown.note.topic, answer)
  if (answer === 'turn-off') {
    const file = await headsUpFile($)
    await $.fs.write(file.path, withEnabled(file.text, false))
    $.ui.log(`heads-up: off for this project (${CONFIG_FILE}); /${HEADS_UP_COMMAND} on turns it back on`)
    return
  }
  if (answer !== 'tell') return
  const filled = await $.prompt.fill({ text: tellClaudeDraft(shown.note), mode: 'replace' })
  if (!filled.isFilled) throw new Error(`the prompt box did not take the note: ${tellClaudeDraft(shown.note)}`)
}

// The person's own prompt while a note shows: it is typed past.
async function personSubmitted($: EngineInterface): Promise<void> {
  const seen: { topic?: string } = {}
  await update($, headsUp, s => {
    seen.topic = s.phase.kind === 'showing' ? s.phase.note.topic : undefined
    return typedPast(s)
  })
  if (seen.topic !== undefined) await recordAnswer($, seen.topic, 'typed-past')
}

// Turn off takes two presses, as the builtin's Disable does: the first arms it
// for this note, any other press disarms it.
function headsUpPresses($: EngineInterface, state: PaneState, noteId: string): Record<Exclude<Answer, 'typed-past'>, () => void> {
  const press = (answer: Exclude<Answer, 'typed-past'>) => () => {
    state.headsUpTurnOffArmed = ''
    void logFailure($, state, () => pressHeadsUp($, answer))
  }
  const turnOff = () => {
    if (state.headsUpTurnOffArmed === noteId) return press('turn-off')()
    state.headsUpTurnOffArmed = noteId
    $.ui.invalidate('ui.render')
  }
  return { learn: press('learn'), tell: press('tell'), knew: press('knew'), dismiss: press('dismiss'), 'turn-off': turnOff }
}

// The note, in the shape of Claude Code's own heads-up: the mark in the
// council colour, the tag bold, the sentence plain and wrapped under its
// first word, then the choices drawn plain (`1: Learn more`, as a survey's row) with
// the seat line dimmed after them. A narrow pane cuts the seat line, never a choice.
function headsUpRow(
  ui: Pick<Elements['terminal'], 'Box' | 'Button' | 'Text'>,
  band: BandView,
  press: Record<Exclude<Answer, 'typed-past'>, () => void>,
  turnOffArmed: boolean,
) {
  const { more } = band
  const turnOff = <ui.Button key="heads-up:turn-off" hotkey="4" label={turnOffArmed ? 'Press again to turn off' : 'Turn off'} plain dimColor onPress={press['turn-off']} />
  return (
    <ui.Box key="heads-up" flexDirection="column" marginTop={1}>
      <ui.Box flexDirection="row">
        <ui.Box flexShrink={0}><ui.Text color={COLOR.accent}>{'\u2726 '}</ui.Text></ui.Box>
        <ui.Box flexGrow={1} flexShrink={1} flexDirection="column">
          <ui.Text wrap="wrap"><ui.Text bold>{band.tag}</ui.Text>{` \u00b7 ${band.headline}`}</ui.Text>
          {more !== null && (
            <ui.Box flexDirection="column" marginTop={1} marginBottom={1}>
              {more.title !== '' && <ui.Text bold wrap="wrap">{more.title}</ui.Text>}
              {more.points.map((point, at) => (
                <ui.Text key={`heads-up:point:${at}`} wrap="wrap" bold={at === more.points.length - 1}>{`- ${point}`}</ui.Text>
              ))}
            </ui.Box>
          )}
          <ui.Box flexDirection="row">
            <ui.Box flexShrink={0} flexDirection="row">
              {more === null
                ? [
                    <ui.Button key="heads-up:learn" hotkey="1" label="Learn more" plain onPress={press.learn} />,
                    <ui.Text key="gap-1">{'   '}</ui.Text>,
                    <ui.Button key="heads-up:knew" hotkey="2" label="Knew this already" plain onPress={press.knew} />,
                    <ui.Text key="gap-2">{'   '}</ui.Text>,
                    turnOff,
                    <ui.Text key="gap-3">{'   '}</ui.Text>,
                    <ui.Button key="heads-up:dismiss" hotkey="0" label="Dismiss" plain role="dismiss" onPress={press.dismiss} />,
                  ]
                : [
                    <ui.Button key="heads-up:tell" hotkey="1" label="Tell Claude" plain onPress={press.tell} />,
                    <ui.Text key="gap-1">{'   '}</ui.Text>,
                    turnOff,
                    <ui.Text key="gap-2">{'   '}</ui.Text>,
                    <ui.Button key="heads-up:close" hotkey="0" label="Close" plain role="dismiss" onPress={press.dismiss} />,
                  ]}
            </ui.Box>
            <ui.Box flexShrink={1}>
              <ui.Text color={COLOR.hint} wrap="truncate-end">{`      ${band.meta}`}</ui.Text>
            </ui.Box>
          </ui.Box>
        </ui.Box>
      </ui.Box>
    </ui.Box>
  )
}

// The COUNCIL chip: a darker segment with a star, then the
// label, white on solid colour. Coloured cells draw alike in every terminal,
// where end-cap glyphs do not. Given a frame, a highlight moves across the
// label's letters.
function chip(ui: Pick<Elements['terminal'], 'Box' | 'Text'>, key: string, label: string, frame?: number) {
  return (
    <ui.Box key={key} flexDirection="row" flexShrink={0}>
      <ui.Text bold color={COLOR.onFill} backgroundColor={FILL.chipMark}>{' \u2726 '}</ui.Text>
      <ui.Text backgroundColor={FILL.chip}>{' '}</ui.Text>
      {shimmer(label, frame).map((letter, index) => (
        <ui.Text key={`${key}-${index}`} bold color={letter.color} backgroundColor={FILL.chip}>{letter.text}</ui.Text>
      ))}
      <ui.Text backgroundColor={FILL.chip}>{' '}</ui.Text>
    </ui.Box>
  )
}

// A row's press is a marker query-council.sh polls for while it waits on its
// seats: cancel/<seat> ends a seat that is out, and the row reads cancelling
// until the run logs it; retry/<seat> re-queries a seat the run offers in
// retriable/, and the row reads retrying until the run relaunches it.
function pressSeat($: EngineInterface, state: PaneState, press: 'cancel' | 'retry', name: string): void {
  const runDir = state.runDir
  if (!runDir) return
  void $.fs.write(`${runDir}/${press}/${name}`, '').catch((err: unknown) => $.ui.log(`${press} ${name}: ${String(err)}`))
}

// A section header's press: close it if open, open it if closed.
function toggleSection($: EngineInterface, state: PaneState, fold: string): void {
  if (!state.closed.delete(fold)) state.closed.add(fold)
  $.ui.invalidate('ui.render')
}

function retryPresses($: EngineInterface, runDir: string) {
  return {
    accept: () => { void $.process.run(['mv', '-f', `${runDir}/retry-offer`, `${runDir}/.retry`]) },
    skip: () => { void $.fs.write(`${runDir}/.retry-declined`, '') },
  }
}

// The offer's two buttons and its countdown. The keys work once the person has
// given the site the keyboard (a click, ctrl+x tab); a click works at any time.
function retryRow(
  ui: Pick<Elements['terminal'], 'Box' | 'Button' | 'Text'>,
  offer: RetrySection,
  press: { accept: () => void; skip: () => void },
) {
  return (
    <ui.Box key="retry" flexDirection="row" marginTop={1}>
      {/* The other bands' chip; only the notice and the how-to give way when narrow. */}
      {chip(ui, 'chip', offer.badge)}
      <ui.Box flexShrink={1}>
        <ui.Text bold color={COLOR.danger} wrap="truncate-end">{` \u2717 ${offer.notice}  `}</ui.Text>
      </ui.Box>
      <ui.Box flexShrink={0} flexDirection="row">
        <ui.Button key="retry:accept" hotkey="r" label={offer.label} onPress={press.accept} />
        <ui.Text>{' '}</ui.Text>
        <ui.Button key="retry:skip" hotkey="s" label={offer.skipLabel} onPress={press.skip} />
        <ui.Text color={COLOR.accent}>{`  ${offer.bar}`}</ui.Text>
        <ui.Text dimColor>{` ${offer.remaining}s`}</ui.Text>
      </ui.Box>
      <ui.Box flexShrink={1}>
        <ui.Text dimColor wrap="truncate-end">{'  click, or ctrl+x tab then r / s'}</ui.Text>
      </ui.Box>
    </ui.Box>
  )
}

export const register: Register = (on, options) => {
  const settings = paneOptions(options)
  const state: PaneState = { root: '', drawn: '', isPolling: false, shown: new Set(), lastError: '', pidCheckedAtMs: 0, headsUpCheckedAtMs: 0, isPollingHeadsUp: false, headsUpProblem: '', lastFailure: '', headsUpTip: '', headsUpReceipt: '', headsUpSkipped: '', headsUpTurnOffArmed: '', frame: 0, nowMs: 0, queryingSinceMs: {}, closed: new Set(), fitted: new Map(), tableFit: { columns: 0, byText: new Map() } }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: REOPEN_COMMAND, description: 'Reopen the council pane, or forget where it was told to open', argumentHint: '[ask]', immediate: true })
    await $.command.register({ name: HEADS_UP_COMMAND, description: 'Heads-up side-check: set it up in a few questions, switch it on for this project naming the seat, or off, or show its state and counts', argumentHint: '[setup | on [seat] | off | status]', immediate: true })
    if (settings.offersTool) await $.tool.register({ name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: TOOL_SCHEMA })
    void logFailure($, state, () => introduceHeadsUp($, state, settings))
    // A reload drops the heads-up timer; a check still in flight needs it back.
    if ((await read($, headsUp)).phase.kind === 'checking') watchHeadsUp($, state)
    // Nothing after depends on these, so the request is not held up for them.
    void Promise.all(SPECIALIST_STORE_KEYS.map(key => $.store.delete(key))).catch((err: unknown) => $.ui.log(`store cleanup: ${String(err)}`))
    return next(e)
  })

  // The synthesis is written into the reply after the run ends; nothing on disk
  // holds it, so it is lifted from the main loop's final message.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    const view = state.view
    const synthesis = e.agentId === undefined && view && !state.synthesis ? extractSynthesis(e.answer) : undefined
    if (view && synthesis) {
      state.synthesis = synthesis
      state.view = { ...view, synthesis }
      // The answers close so the synthesis reads near the top; each opens again on a press.
      state.closed = new Set(seatFolds(paneSections(state.view)))
      state.drawn = JSON.stringify([state.view, state.retryShown])
      $.ui.invalidate('ui.render')
    }
    return result
  })

  // The heads-up check rides the main loop's steps. The request goes first and
  // is never held up: the check's own work runs beside it.
  on('turn.step', async function* ($, e, next) {
    const response = next(e)
    if (e.agentId === undefined) {
      const step = { turnId: e.turnId, index: e.index }
      void logFailure($, state, () => stepHeadsUp($, state, settings, step))
    }
    return yield* response
  })

  // Only the person's own prompt types past a note; a plugin's submit or a
  // notification does not.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await logFailure($, state, () => personSubmitted($))
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isCouncilRun(e.command)) await aimRun($, state, settings)
    return next(e)
  })

  // The settings row says ask while an answer is remembered; its label says which.
  on('config.describe', async ($, e, next) => {
    const row = await next(e)
    if (!e.key.endsWith('.pane_host')) return row
    return { ...row, label: hostRowLabel(row.label, settings.host, hostFrom(await $.store.get(HOST_STORE_KEY))) }
  })

  // The generated types list the tools connected when they were written, so a
  // tool registered at run time is matched by pattern.
  on('tool.call', { tool: /^mcp__claude-council__ask$/ }, async ($, e) => {
    // `e` is flat: the tool's input fields sit beside `tool` and `tool_use_id`.
    // Its declared type is the union of the listed tools, none of them this one.
    const input = e as unknown as Record<string, unknown>
    const parsed = councilArgs(input)
    if ('deny' in parsed) return { deny: parsed.deny }
    const script = `${$.plugin.root}/scripts/run-council.sh`
    if (!(await $.fs.exists(script))) return { deny: `council script not found at ${script}` }
    // The question goes to third-party providers, so the user confirms every
    // call; this gate holds even where the tool itself needs no permission.
    let answer: string | undefined
    try {
      answer = await $.ui.ask(confirmQuestion(input), { header: 'Council', options: [SEND_LABEL, KEEP_LABEL] })
    } catch {
      answer = undefined
    }
    const outcome = confirmOutcome(answer)
    if ('deny' in outcome) return { deny: outcome.deny }
    if ('reply' in outcome) return { result: outcome.reply }
    await aimRun($, state, settings)
    const run = await $.process.run(['bash', script, ...parsed.args], { timeoutMs: RUN_TIMEOUT_MS })
    const saved = run.stdout.trim().split('\n').pop() ?? ''
    if (run.exitCode !== 0 || !saved) return { result: run.stderr || 'council run failed', isError: true }
    return { result: await $.fs.read(saved) }
  })

  on('command.run', { command: HEADS_UP_COMMAND }, async ($, e) => {
    const command = headsUpCommand(e.args)
    if (command.action === 'unknown') return { text: `${command.why}. Usage: /${HEADS_UP_COMMAND} [on [seat] | off | setup | status]; one seat, a provider name such as codex, gemini or grok-cli.` }
    if (command.action === 'setup') {
      const outcome = await setupHeadsUp($, state, settings)
      if (outcome !== undefined) return { text: outcome }
    } else if (command.action !== 'status') {
      const unknown = command.action === 'on' && command.seat !== undefined ? await notASeat($, command.seat) : undefined
      if (unknown !== undefined) return { text: `${unknown}; nothing changed.` }
      const file = await headsUpFile($)
      await $.fs.write(file.path, withEnabled(file.text, command.action === 'on', command.action === 'on' ? command.seat : undefined))
      state.headsUpTip = ''
    }
    return { text: await headsUpStatus($, settings.headsUp) }
  })

  on('command.run', { command: REOPEN_COMMAND }, async ($, e) => {
    const command = paneCommand(e.args)
    if (command.action === 'forget') {
      await $.store.delete(HOST_STORE_KEY)
      return { text: 'Forgotten. With the setting on ask, the next council run inside tmux asks where to open its pane.' }
    }
    if (command.action === 'unknown') return { text: 'Usage: /council-pane [ask]. Choose the pane in /config, row "Pane opens in".' }
    if (state.view) await $.ui.open({ id: PANE_ID, title: 'Council' })
    return { text: reopenReply(state.view !== undefined) }
  })

  // The intro rides the dim hint under the prompt while it is empty; the
  // first typed character retires it for good.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const tail = state.headsUpTip !== '' ? state.headsUpTip : state.headsUpReceipt
    if (tail === '') return next(e)
    if (e.props.isDraft) {
      state.headsUpTip = ''
      state.headsUpReceipt = ''
      return next(e)
    }
    return next({ ...e, props: { ...e.props, tail } })
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // The band sits on the prompt, so the offer stays in view however far the
    // pane has scrolled; a survey owns the band while it runs.
    const retry = state.retryShown
    const runDir = state.runDir
    if (e.props.hasSurvey) return next(e)
    const finished = state.finished
    if (finished && !retry) {
      const ui = $.ui.resolve(e)
      return (
        <ui.Box key="finished" flexDirection="row" marginTop={1}>
          {chip(ui, 'chip', 'COUNCIL')}
          <ui.Text bold {...(finished.isFailure ? { color: COLOR.danger } : {})}>{` ${finished.isFailure ? '\u2717' : '\u2713'} ${finished.text}  `}</ui.Text>
          <ui.Button key="finished:open" hotkey="o" label={'o \u00b7 open pane'} onPress={() => { void $.ui.open({ id: PANE_ID, title: 'Council' }) }} />
          <ui.Text>{' '}</ui.Text>
          <ui.Button
            key="finished:dismiss"
            hotkey="x"
            label={'x \u00b7 dismiss'}
            onPress={() => {
              state.finished = undefined
              $.ui.invalidate('ui.render')
            }}
          />
        </ui.Box>
      )
    }
    if (retry && runDir) return retryRow($.ui.resolve(e), retry, retryPresses($, runDir))
    const failure = state.headsUpFailure
    if (failure) {
      const ui = $.ui.resolve(e)
      return (
        <ui.Box key="heads-up-failure" flexDirection="row" marginTop={1}>
          <ui.Text bold color={COLOR.danger}>{` \u2717 ${failure.text}  `}</ui.Text>
          <ui.Button
            key="heads-up-failure:dismiss"
            hotkey="x"
            label={'x \u00b7 dismiss'}
            onPress={() => {
              state.headsUpFailure = undefined
              $.ui.invalidate('ui.render')
            }}
          />
        </ui.Box>
      )
    }
    // A note is one row and time-sensitive: the progress band waits for its
    // answer. Reading the session here subscribes the band to its changes.
    const band = bandView((await read($, headsUp)).phase)
    if (band) return headsUpRow($.ui.resolve(e), band, headsUpPresses($, state, band.id), state.headsUpTurnOffArmed === band.id)
    const view = state.view
    const progress = view ? progressBand(view, state.runStartedMs, state.nowMs) : undefined
    if (!view || !progress) return next(e)
    const ui = $.ui.resolve(e)
    // One marker per seat; the run cancels them one by one, as it would rows
    // pressed in turn. A press reads the seats again, since one may have
    // answered since the band was drawn.
    const cancelAll = () => { if (state.view) for (const name of seatsToCancel(state.view)) pressSeat($, state, 'cancel', name) }
    return (
      <ui.Box key="progress" flexDirection="row" marginTop={1}>
        {/* Only the event gives way when narrow. */}
        {chip(ui, 'chip', 'COUNCIL', state.frame)}
        <ui.Box flexShrink={0}>
          <ui.Text>
            <ui.Text bold>{`  ${progress.count}`}</ui.Text>
            <ui.Text color={COLOR.accent}>{`  ${progress.bar}`}</ui.Text>
            {progress.clock ? <ui.Text bold color={COLOR.warning}>{`  \u25cf ${progress.clock}`}</ui.Text> : null}
          </ui.Text>
        </ui.Box>
        <ui.Box flexGrow={1} flexShrink={1}>
          <ui.Text dimColor wrap="truncate-end">{`  ${progress.event ?? ''}  `}</ui.Text>
        </ui.Box>
        {seatsToCancel(view).length > 0 && (
          <ui.Box flexShrink={0}>
            <ui.Button key="progress:cancel" hotkey="c" label={'c \u00b7 cancel all'} onPress={cancelAll} />
            <ui.Text>{'  '}</ui.Text>
          </ui.Box>
        )}
        <ui.Box flexShrink={0}>
          <ui.Button key="progress:open" hotkey="o" label={'o \u00b7 open pane'} onPress={() => { void $.ui.open({ id: PANE_ID, title: 'Council' }) }} />
        </ui.Box>
      </ui.Box>
    )
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== PANE_ID || !state.view) return next(e)
    const { Box, Button, Markdown, Text } = $.ui.resolve(e)
    const columns = e.props.bodyColumns
    // Answers are rewritten for this width before the pane's text budget is
    // counted, which only a render can do: it alone knows the width. The
    // rewrites of the last frame are reused while the width holds, and only
    // the ones this frame asked for are kept.
    const lastFits = state.tableFit.columns === columns ? state.tableFit.byText : new Map<string, string>()
    const fits = new Map<string, string>()
    const fitText = (text: string) => {
      const fitted = lastFits.get(text) ?? fitTables(text, columns)
      fits.set(text, fitted)
      return fitted
    }
    const sections = paneSections(state.view, { ...settings, frame: state.frame, nowMs: state.nowMs, fitText, closed: state.closed })
    state.tableFit = { columns, byText: fits }
    const fit = (sectionKey: string, text: string) => {
      const kept = state.fitted.get(sectionKey)
      if (kept && kept.text === text) return kept.blocks
      const blocks = markdownBlocks(text)
      state.fitted.set(sectionKey, { text, blocks })
      return blocks
    }
    // A closable section's header: a press opens or closes it, and its text leads with the mark.
    const toggle = (section: { fold: string }, children: RenderChildren) => (
      <Button key={`toggle:${section.fold}`} plain onPress={() => toggleSection($, state, section.fold)}>{children}</Button>
    )
    const mark = (open: boolean) => (open ? OPEN_MARK : CLOSED_MARK)
    const draw = (section: Section, index: number) => {
      const key = `section-${index}`
      switch (section.kind) {
        case 'note':
          return <Text key={key} dimColor>{section.text}</Text>
        case 'status': {
          const action = section.action
          // The model takes the slack and gives way when narrow, so every
          // row's button sits at the pane's right edge.
          return (
            <Box key={key} flexDirection="row" width={columns}>
              <Box flexShrink={0}>
                <Text>
                  <Text color={section.glyphColor}>{`${section.glyph} `}</Text>
                  <Text bold>{`${section.name}  `}</Text>
                  <Text color={section.stateColor}>{`${section.state}  `}</Text>
                  <Text dimColor>{`${section.time}  `}</Text>
                </Text>
              </Box>
              <Box flexGrow={1} flexShrink={1}>
                <Text dimColor wrap="truncate-end">{section.model}</Text>
              </Box>
              {action && (
                <Box flexDirection="row" flexShrink={0}>
                  <Text>{'  '}</Text>
                  <Button key={`${action.press}:${action.seat}`} plain label={action.press} {...(action.hotkey ? { hotkey: action.hotkey } : {})} onPress={() => pressSeat($, state, action.press, action.seat)} />
                </Box>
              )}
            </Box>
          )
        }
        case 'summary':
          return <Text key={key} bold>{section.text}</Text>
        case 'strip':
          return (
            <Box key={key} flexDirection="row" flexWrap="wrap">
              {section.items.map(({ target, ...item }) => (
                <Box key={`${key}-${item.name}`} flexDirection="row">
                  <Text color={item.color}>{`${item.glyph} `}</Text>
                  {target ? (
                    <Button
                      key={`press:${item.name}`}
                      plain
                      label={item.name}
                      {...(item.hotkey ? { hotkey: item.hotkey } : {})}
                      onPress={() => {
                        // A jump opens the section it lands on.
                        if (item.fold && state.closed.delete(item.fold)) $.ui.invalidate('ui.render')
                        void $.ui.scroll({ in: PANE_ID, to: { key: target }, block: 'start' })
                      }}
                    />
                  ) : (
                    <Text dimColor>{item.name}</Text>
                  )}
                  <Text>{'  '}</Text>
                </Box>
              ))}
            </Box>
          )
        case 'toggleAll':
          return (
            <Box key={key} marginTop={1}>
              <Button
                key="toggle:all"
                plain
                hotkey="a"
                label={section.closes ? 'collapse all' : 'expand all'}
                onPress={() => {
                  state.closed = section.closes ? new Set(section.folds) : new Set()
                  $.ui.invalidate('ui.render')
                }}
              />
            </Box>
          )
        case 'banner':
          return (
            <Box key={section.key} flexDirection="row" marginTop={1} paddingX={1} width={columns} backgroundColor={section.background}>
              {toggle(section, [
                <Text key="title" bold color={COLOR.onFill} backgroundColor={section.background}>{`${mark(section.open)} ${section.title}`}</Text>,
                <Text key="subtitle" italic color={COLOR.onFill} backgroundColor={section.background}>{` ${section.subtitle}`}</Text>,
              ])}
            </Box>
          )
        case 'synthesis':
          return (
            <Box key={section.key} flexDirection="column" marginTop={1}>
              <Box flexDirection="row" paddingX={1} width={columns} backgroundColor={FILL.chip}>
                {toggle(section, <Text bold color={COLOR.onFill} backgroundColor={FILL.chip}>{`${mark(section.open)} SYNTHESIS`}</Text>)}
              </Box>
              {section.open && fit(key, section.text).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
            </Box>
          )
        case 'body':
          // The text arrives fitted to the pane's width and within its budget.
          return (
            <Box key={key} flexDirection="column">
              {fit(key, section.text).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
            </Box>
          )
        case 'reason':
          return <Text key={key} color={COLOR.warning} dimColor>{section.text}</Text>
        case 'error':
          return (
            <Box key={section.key} flexDirection="column" marginTop={1}>
              {toggle(section, <Text bold color={COLOR.danger}>{`${mark(section.open)} \u2717 ${section.title}`}</Text>)}
              {section.open && <Text color={COLOR.danger} dimColor>{section.text}</Text>}
            </Box>
          )
      }
    }
    const retry = state.retryShown
    const runDir = state.runDir
    return (
      <Box flexDirection="column">
        {e.surface !== 'terminal' && retry && runDir ? [retryRow($.ui.resolve(e), retry, retryPresses($, runDir))] : []}
        {sections.map(draw)}
      </Box>
    )
  })
}
