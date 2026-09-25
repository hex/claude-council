// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import type { Elements, EngineInterface, Register } from 'claude-code'
import { decideHost, HOST_LABELS, HOST_QUESTION, HOST_STORE_KEY, hostFrom, hostRowLabel, isCouncilRun, paneCommand, type HostSetting, type PaneHost } from './host'
import { abandonedNotice, FINISH_NOTICE_MS, finishNotice, jobOutcome, noticeIsLive, reopenReply, runPid, wakePrompt, type FinishNotice, progressBand } from './notices'
import { paneOptions, type PaneOptions } from './options'
import { parseRetryOffer, retrySection, type RetryOffer, type RetrySection } from './retry'
import { readText, readView, type Files } from './snapshot'
import {
  dialogOutcome, finishQuestion, followUpRefusal, LIST_FIELD, parseSpecialist, parseSpecialistReport, specialistEntries, roundResult, runStamp, specialistCall,
  specialistDescription, specialistPrompt, specialistRoster, specialistSchema, threadFrom,
  commitSubject, latestStep, lostResult, roundLiveness, roundProcessIdentity, roundProcessPresence, specialistSteps, specialistWake, startedReply, roundClock, roundStatus, workingLine, landsAtEnd,
  type RunRecord, type Specialist, type Step,
} from './specialist'
import { confirmOutcome, confirmQuestion, councilArgs, KEEP_LABEL, SEND_LABEL, TOOL_DESCRIPTION, TOOL_NAME, TOOL_SCHEMA } from './tool'
import { extractSynthesis } from './synthesis'
import { fitTables } from './tables'
import { shimmer } from './chip'
import { markdownBlocks, paneSections, queryingSince, unseenRun, type RunView, type Section } from './view'
import { blankDraft, draftFor, dropEntry, putEntry, checkSpecialist, isDirty, parseCatalog, restoreSetup, setupView, withModel, type Fields, type SetupState, type Status } from './setup'

const PANE_ID = 'council'
const REOPEN_COMMAND = 'council-pane'
const RUN_TIMEOUT_MS = 600_000
// Claude's orange (#D97757): the council speaks inside Claude Code, and the
// synthesis is Claude's own text. No provider's banner uses it.
const COUNCIL_RGB = 'rgb(217,119,87)'
const MODEL_RGB = 'rgb(38,128,150)'
// Mid tones, readable on a light and a dark background alike.
const BRANCH_RGB = 'rgb(96,140,72)'
const WORKTREE_RGB = 'rgb(112,120,160)'
const CHIP_DARK_RGB = 'rgb(191,96,60)'
const POLL_MS = 500
// Ten frames a second: the spinner's pace in the tmux pane.
const FRAME_MS = 100
// A second of frames for a just-opened pane to become scrollable.
const PANE_FOLLOW_FRAMES = 10
// The worker records its result seconds after .done; a worker killed outright
// leaves its record at running, so the wait for it ends.
const WAKE_WAIT_MS = 120_000
// How often a run still going is asked whether its process is alive.
const PID_CHECK_MS = 5_000
const SPECIALIST_TOOL = 'specialist'
const SPECIALIST_PANE = 'specialist'
const RUNS_KEY = 'specialist-runs'
const SETUP_PANE = 'specialist-setup'
const SETUP_KEY = 'specialist-setup'
const SETUP_COMMAND = 'specialists'
// Filled status labels carry white letters, so each background is dark enough
// for white on a light or a dark terminal.
const STATUS_RGB: Record<Status['kind'], string> = { saved: 'rgb(46,120,72)', error: 'rgb(178,58,52)', note: 'rgb(150,100,20)' }
const STATUS_LABEL: Record<Status['kind'], string> = { saved: ' SAVED ', error: ' ERROR ', note: ' NOTE ' }
// Help lines start under the field values: the labels are 13 wide plus ': '.
const HELP_INDENT = ' '.repeat(15)
// The settings field holding every specialist, as $.config names it; hidden
// from the /config menu, since /specialists edits it.
const LIST_KEY = `claude-council.${LIST_FIELD}`

type PaneState = {
  root: string
  runDir?: string
  view?: RunView
  drawn: string
  isPolling: boolean
  shown: Set<string>
  lastError: string
  pidCheckedAtMs: number
  pendingWake?: { prompt: string; jobFile: string; untilMs: number }
  retry?: { offer: RetryOffer; seenAtMs: number }
  retryShown?: RetrySection
  synthesis?: string
  finished?: FinishNotice
  frame: number
  nowMs: number
  queryingSinceMs: Record<string, number>
  // When the pane picked the live run up; the progress band's clock.
  runStartedMs?: number
  // Each section's fitted body, for the width and text it was fitted to: a
  // frame redraws the tree, not the markdown, and a resize replaces the entry.
  fitted: Map<string, { columns: number; text: string; blocks: string[] }>
  specialists: Specialist[]
  // The specialist round this session is waiting on; the band's subject.
  specialist?: { record: RunRecord; startedMs: number; stateDir: string }
  // What the last specialist round did, step by step; the pane's subject. It
  // outlives the round so the pane can still be read after it ends.
  specialistLog?: { record: RunRecord; steps: Step[]; isLive: boolean }
  // Runs whose end is being written up now, so one tick does not repeat another's.
  finishing: Set<string>
  identityFailures: Set<string>
  specialistError: string
  specialistFrame: number
  // Frames left to retry following a just-opened pane: it becomes scrollable
  // only once drawn, milliseconds after $.ui.open settles.
  paneFollowFrames: number
  // The setup screen's draft and catalog, mirrored from $.store so a reload redraws it.
  setup?: SetupState
  // Bumped after each Enter in a setup field: the engine empties a submitted
  // Input, and a field under a new key draws its value again.
  inputEpoch: number
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

async function keepSetup($: EngineInterface, state: PaneState, setup: SetupState | undefined): Promise<void> {
  state.setup = setup
  if (setup) await $.store.set(SETUP_KEY, setup)
  else await $.store.delete(SETUP_KEY)
  $.ui.invalidate('ui.render')
}

const currentSetup = (state: PaneState): SetupState => state.setup ?? { catalog: { loading: true } }
const modelsOf = (setup: SetupState) => ('models' in setup.catalog ? setup.catalog.models : [])

// Asks Codex for its models and fills them in; a new draft that opened before
// they arrived takes the first listed model.
async function loadCatalog($: EngineInterface, state: PaneState): Promise<void> {
  await keepSetup($, state, { ...currentSetup(state), catalog: { loading: true } })
  const catalog = await readCatalog($)
  const setup = currentSetup(state)
  const first = 'models' in catalog ? catalog.models.find(m => m.listed)?.slug : undefined
  const draft = setup.draft && !setup.draft.model && first ? { ...setup.draft, model: first } : setup.draft
  await keepSetup($, state, { ...setup, catalog, draft })
}

// Returns why the screen did not open, or undefined once it is open. It opens
// at once and the catalog fills in after. A prefill comes from Claude's {setup}
// call and starts a new row at the end of the list.
async function openSetup($: EngineInterface, state: PaneState, options: Record<string, unknown>, prefill?: Partial<Fields>): Promise<string | undefined> {
  // Only a draft with changes survives to the next open; an untouched one would
  // reopen the form for nothing.
  const kept = state.setup?.draft && isDirty(state.setup.draft) ? state.setup.draft : undefined
  let draft = kept
  let status: Status | undefined
  if (prefill) {
    draft = blankDraft(specialistEntries(options).entries.length, [], prefill)
  } else if (kept) {
    status = { kind: 'note', text: 'Your unsaved draft is back.' }
  }
  await keepSetup($, state, { catalog: { loading: true }, draft, status })
  try { await $.ui.open({ id: SETUP_PANE, title: 'Specialists', focus: true, closeOnEscape: true }) } catch (err) { return String(err) }
  await loadCatalog($, state)
  return undefined
}

// Runs one press of the setup screen; a failure shows under the form instead
// of vanishing with the press, and the log keeps it if even that fails.
async function setupAction($: EngineInterface, state: PaneState, work: () => Promise<void>): Promise<void> {
  try {
    await work()
  } catch (error) {
    await keepSetup($, state, { ...currentSetup(state), status: { kind: 'error', text: String(error) } })
      .catch(() => $.ui.log(`specialists: ${String(error)}`))
  }
}

// Field edits read the draft at press time, so two quick edits both land.
async function editSetup($: EngineInterface, state: PaneState, patch: Partial<Fields>): Promise<void> {
  const setup = state.setup
  if (setup?.draft) await keepSetup($, state, { ...setup, draft: { ...setup.draft, ...patch }, status: undefined, confirm: undefined })
}

// Enter in a setup field keeps what was typed and moves on to the next control.
// An Input's key carries the epoch, so a next Input is named by its field and
// gets the epoch this submit moves to.
async function submitField($: EngineInterface, state: PaneState, patch: Partial<Fields>, next: { control: string } | { input: keyof Fields }): Promise<void> {
  await editSetup($, state, patch)
  state.inputEpoch += 1
  $.ui.invalidate('ui.render')
  const key = 'control' in next ? next.control : `${next.input}.${state.inputEpoch}`
  await $.ui.focus({ requestId: SETUP_PANE, key })
}

async function pickModel($: EngineInterface, state: PaneState, slug: string): Promise<void> {
  const setup = state.setup
  if (!setup?.draft) return
  const picked = withModel(setup.draft, slug, modelsOf(setup))
  await keepSetup($, state, { ...setup, draft: picked.draft, status: picked.message ? { kind: 'note', text: picked.message } : undefined })
}

// Opening another row, or a new one, over unsaved edits asks first.
async function openRow($: EngineInterface, state: PaneState, options: Record<string, unknown>, target: number | 'new', force = false): Promise<void> {
  const setup = currentSetup(state)
  if (!force && setup.draft && setup.draft.index !== target && isDirty(setup.draft)) {
    await keepSetup($, state, { ...setup, confirm: { kind: 'switch', target } })
    return
  }
  const entries = specialistEntries(options).entries
  const draft = target === 'new' ? blankDraft(entries.length, modelsOf(setup)) : draftFor(target, entries, modelsOf(setup))
  await keepSetup($, state, { ...setup, draft, confirm: undefined, status: undefined })
}

// The write reloads this module and the reload redraws from the store, so the
// store is cleared first; a write that fails puts the draft back with the reason.
async function writeEntries($: EngineInterface, state: PaneState, setup: SetupState, entries: unknown[], done: string): Promise<void> {
  await keepSetup($, state, { catalog: setup.catalog, status: { kind: 'saved', text: done } })
  let written: { deny?: string }
  try {
    written = await $.config.set({ key: LIST_KEY, value: JSON.stringify(entries) })
  } catch (error) {
    await keepSetup($, state, { ...setup, confirm: undefined, status: { kind: 'error', text: String(error) } })
    return
  }
  if (written.deny) await keepSetup($, state, { ...setup, confirm: undefined, status: { kind: 'error', text: written.deny } })
}

async function saveSetup($: EngineInterface, state: PaneState, options: Record<string, unknown>): Promise<void> {
  const setup = state.setup
  if (!setup?.draft) return
  if ('loading' in setup.catalog) { await keepSetup($, state, { ...setup, status: { kind: 'note', text: 'Models are still loading; Save again in a moment.' } }); return }
  if ('error' in setup.catalog) { await keepSetup($, state, { ...setup, status: { kind: 'error', text: `Cannot check the model: ${setup.catalog.error}` } }); return }
  const entries = specialistEntries(options).entries
  const checked = checkSpecialist(setup.draft, setup.draft.index, { models: setup.catalog.models, entries })
  if ('error' in checked) { await keepSetup($, state, { ...setup, status: { kind: 'error', text: checked.error } }); return }
  await writeEntries($, state, setup, putEntry(entries, setup.draft.index, checked.entry), `Saved ${setup.draft.name}.`)
}

// The confirm row's yes: remove, or drop the unsaved draft and open the target.
async function confirmSetup($: EngineInterface, state: PaneState, options: Record<string, unknown>): Promise<void> {
  const setup = state.setup
  const confirm = setup?.confirm
  if (!setup?.draft || !confirm) return
  if (confirm.kind === 'switch') { await openRow($, state, options, confirm.target, true); return }
  const entries = specialistEntries(options).entries
  const name = draftFor(setup.draft.index, entries, []).name || `specialist ${setup.draft.index + 1}`
  await writeEntries($, state, setup, dropEntry(entries, setup.draft.index), `Removed ${name}.`)
}

async function askSetup($: EngineInterface, state: PaneState, confirm: SetupState['confirm']): Promise<void> {
  await keepSetup($, state, { ...currentSetup(state), confirm })
}

// Drops the draft; the screen stays open on the roster.
async function discardSetup($: EngineInterface, state: PaneState): Promise<void> {
  await keepSetup($, state, { catalog: currentSetup(state).catalog })
}

// A list set by hand (`/config specialists=...`) gets the same checks as a
// Save, entry by entry; the first problem is the refusal.
async function handEditDenial($: EngineInterface, value: string): Promise<string | undefined> {
  const { entries, problem } = specialistEntries({ [LIST_FIELD]: value })
  if (problem) return problem
  if (entries.length === 0) return undefined
  const catalog = await readCatalog($)
  if ('error' in catalog) return `cannot check the models: ${catalog.error}`
  for (const [index, entry] of entries.entries()) {
    const parsed = parseSpecialist(entry)
    if ('error' in parsed) return `specialist ${index + 1}: ${parsed.error}`
    const checked = checkSpecialist({ ...parsed, effort: parsed.effort ?? '', instructions: parsed.instructions ?? '' }, index, { models: catalog.models, entries })
    if ('error' in checked) return `specialist ${index + 1}: ${checked.error}`
  }
  return undefined
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
async function runHasDied($: EngineInterface, state: PaneState, runDir: string, now: number): Promise<boolean> {
  if (now - state.pidCheckedAtMs < PID_CHECK_MS) return false
  state.pidCheckedAtMs = now
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
async function startWatching($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  if (state.root) return
  const tmp = ((await $.env.get('TMPDIR')) ?? '/tmp').replace(/\/+$/, '')
  state.root = `${tmp}/council-mod.${await $.session.id()}`
  await $.fs.write(`${state.root}/.keep`, '')
  $.clock.every(FRAME_MS, () => { void animate($, state) })
  $.clock.every(POLL_MS, () => { void pollOnce($, state, settings) })
}

async function aimRun($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  await startWatching($, state, settings)
  const host = await paneHost($, settings.host)
  await $.env.set('COUNCIL_MOD_PANE_DIR', host === 'mod' ? state.root : undefined)
}

// A background failure is logged once per distinct message, never dropped.
async function logFailure($: EngineInterface, state: PaneState, work: () => Promise<void>): Promise<void> {
  try {
    await work()
    state.specialistError = ''
  } catch (error) {
    const message = `specialist: ${String(error)}`
    if (message !== state.specialistError) $.ui.log(message)
    state.specialistError = message
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
    const message = String(error)
    if (message !== state.lastError) $.ui.log(message)
    state.lastError = message
  } finally {
    state.isPolling = false
  }
}

function specialistRun($: EngineInterface, args: string[], init?: { stdin?: string }) {
  return $.process.run(['bash', `${$.plugin.root}/scripts/specialist.sh`, ...args], init)
}

function keyValues(text: string): Record<string, string> {
  return Object.fromEntries(text.split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
}

const stateDirOf = (record: RunRecord) => `${record.worktree.replace(/\/[^/]+$/, '')}/.state/${record.id}`

async function loadRuns($: EngineInterface): Promise<Record<string, RunRecord>> {
  return ((await $.store.get(RUNS_KEY)) ?? {}) as Record<string, RunRecord>
}

// Every session shares the store, so a write re-reads it first rather than
// overwriting the others' records with a stale copy.
async function saveRun($: EngineInterface, record: RunRecord): Promise<void> {
  const runs = await loadRuns($)
  runs[record.id] = record
  await $.store.set(RUNS_KEY, runs)
}

async function roundState($: EngineInterface, state: PaneState, record: RunRecord): Promise<'running' | 'ended' | 'lost'> {
  const stateDir = stateDirOf(record)
  const exitPath = `${stateDir}/exit`
  const exitText = await readText(files($), exitPath)
  if (exitText.trim() !== '') return 'ended'
  const pid = (await readText(files($), `${stateDir}/pid`)).trim()
  let presence: 'present' | 'absent' | 'unknown' = 'unknown'
  let recordedIdentity: string | undefined
  let observedIdentity: string | undefined
  let failure = ''
  if (!/^\d+$/.test(pid)) failure = `invalid round pid ${JSON.stringify(pid)}`
  else {
    try {
      const startPath = `${stateDir}/start`
      if (await $.fs.exists(startPath)) recordedIdentity = await $.fs.read(startPath)
      const alive = await $.process.run(['kill', '-0', pid], { env: { LC_ALL: 'C' } })
      presence = roundProcessPresence(alive.exitCode, alive.stderr)
      if (presence === 'unknown') failure = `kill -0 exited ${alive.exitCode}: ${alive.stderr.trim()}`
      if (presence === 'present' && recordedIdentity !== undefined) {
        const observed = await $.process.run(['ps', '-o', 'lstart=', '-p', pid], { env: { LC_ALL: 'C' } })
        if (observed.exitCode === 0) observedIdentity = observed.stdout
        else failure = `ps exited ${observed.exitCode}: ${observed.stderr.trim()}`
      }
    } catch (error) {
      presence = 'unknown'
      failure = `identity check failed: ${String(error)}`
    }
  }
  const identity = roundProcessIdentity(recordedIdentity, observedIdentity, presence)
  if (identity === 'unknown') {
    const reason = failure || (recordedIdentity?.trim() === '' ? 'recorded start time is empty' : 'ps start time is empty or unparseable')
    const message = `specialist round ${record.id} pid ${pid}: ${reason}`
    const key = `${record.id}:${pid}`
    if (!state.identityFailures.has(key)) {
      $.ui.log(message)
      state.identityFailures.add(key)
    }
  }
  return roundLiveness(await readText(files($), exitPath), identity)
}

// Closes a round that ended: commits it, keeps its result on the record for
// {run, result: true}, and wakes the model to fetch it.
async function finishRound($: EngineInterface, state: PaneState, record: RunRecord, how: 'ended' | 'lost'): Promise<void> {
  if (state.finishing.has(record.id)) return
  state.finishing.add(record.id)
  try {
    // Another session may have closed it already: stop following it here too.
    const stored = (await loadRuns($))[record.id]
    if (stored?.state !== 'running') {
      if (state.specialist?.record.id === record.id) state.specialist = undefined
      if (state.specialistLog?.record.id === record.id) state.specialistLog = { ...state.specialistLog, record: stored ?? record, isLive: false }
      $.ui.invalidate('ui.render')
      return
    }
    const stateDir = stateDirOf(record)
    const events = await readText(files($), `${stateDir}/events.jsonl`)
    const report = async () => {
      const text = (await specialistRun($, ['report', record.worktree, record.roundBase, record.base])).stdout
      return parseSpecialistReport(text)
    }
    let thread = record.thread
    let outcome: { result: string; isError: boolean }
    if (how === 'lost') {
      outcome = lostResult(record, (await report()).status)
    } else {
      const exitCode = Number((await readText(files($), `${stateDir}/exit`)).trim())
      thread = (await readText(files($), `${stateDir}/thread`)).trim() || threadFrom(events) || record.thread
      const commit = exitCode === 0 ? await specialistRun($, ['commit', record.worktree, record.subject]) : undefined
      const didCommit = commit !== undefined && keyValues(commit.stdout).committed === 'yes'
      const committed = didCommit ? (await specialistRun($, ['head', record.worktree])).stdout.trim().slice(0, 7) : ''
      const commitError = commit && commit.exitCode !== 0 ? commit.stderr.trim() || `commit exited ${commit.exitCode}` : ''
      const section = await report()
      outcome = roundResult({
        record, exitCode, commit: committed, commitError,
        lastMessage: (await readText(files($), `${stateDir}/last-message.md`)).trim(),
        roundStat: section.round, totalStat: section.total, status: section.status,
        stderrTail: (await readText(files($), `${stateDir}/stderr.txt`)).split('\n').slice(-15).join('\n').trim(),
      })
    }
    const done: RunRecord = { ...record, thread, state: 'idle', last: outcome }
    await saveRun($, done)
    if (state.specialist?.record.id === record.id) state.specialist = undefined
    state.specialistLog = { record: done, steps: specialistSteps(events, record.worktree), isLive: false }
    $.ui.invalidate('ui.render')
    await $.prompt.submit({ text: specialistWake(done) })
  } finally {
    state.finishing.delete(record.id)
  }
}

// Once a second while a round runs: its steps for the band and the pane, and
// its end.
async function followSpecialist($: EngineInterface, state: PaneState): Promise<void> {
  const working = state.specialist
  if (!working) return
  state.nowMs = await $.clock.now()
  const steps = specialistSteps(await readText(files($), `${working.stateDir}/events.jsonl`), working.record.worktree)
  if (state.specialist !== working) return
  state.specialistLog = { record: working.record, steps, isLive: true }
  $.ui.invalidate('ui.render')
  const now = await roundState($, state, working.record)
  if (now !== 'running') await finishRound($, state, working.record, now)
}

// A round survives the session that started it: at start, follow one still
// running and close one that ended meanwhile.
// Scrolls the specialist pane to its end, which the engine keeps up with as
// steps arrive. A refusal is reported: to the transcript where the pane
// should have followed, to the debug log where a closed pane is expected.
async function followPaneEnd($: EngineInterface, when: string, to: 'transcript' | 'debug'): Promise<boolean> {
  const moved = await $.ui.scroll({ in: SPECIALIST_PANE, to: 'end' })
  if (moved.deny) $.ui.log(`specialist pane did not follow (${when}): ${moved.deny}`, { to })
  return !moved.deny
}

// One try per frame after the pane opens; the last refusal is the one reported.
async function followOpenedPane($: EngineInterface, state: PaneState): Promise<void> {
  state.paneFollowFrames -= 1
  const isLast = state.paneFollowFrames === 0
  const moved = await followPaneEnd($, 'pane opened', isLast ? 'transcript' : 'debug')
  if (moved) state.paneFollowFrames = 0
}

async function recoverRounds($: EngineInterface, state: PaneState): Promise<void> {
  for (const record of Object.values(await loadRuns($))) {
    if (record.state !== 'running') continue
    const now = await roundState($, state, record)
    if (now === 'running') state.specialist = { record, startedMs: record.startedMs, stateDir: stateDirOf(record) }
    else await finishRound($, state, record, now)
  }
}

// The COUNCIL and SPECIALIST chip: a darker segment with a star, then the
// label, white on solid colour. Coloured cells draw alike in every terminal,
// where end-cap glyphs do not. Given a frame, a highlight moves across the
// label's letters.
function chip(ui: Pick<Elements['terminal'], 'Box' | 'Text'>, key: string, label: string, frame?: number) {
  return (
    <ui.Box key={key} flexDirection="row" flexShrink={0}>
      <ui.Text bold color="white" backgroundColor={CHIP_DARK_RGB}>{' \u2726 '}</ui.Text>
      <ui.Text backgroundColor={COUNCIL_RGB}>{' '}</ui.Text>
      {shimmer(label, frame).map((letter, index) => (
        <ui.Text key={`${key}-${index}`} bold color={letter.color} backgroundColor={COUNCIL_RGB}>{letter.text}</ui.Text>
      ))}
      <ui.Text backgroundColor={COUNCIL_RGB}>{' '}</ui.Text>
    </ui.Box>
  )
}

// What the offer's buttons do: the run waits on these two file names.
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
      <ui.Box flexDirection="row" paddingX={1} backgroundColor={COUNCIL_RGB}>
        <ui.Text bold color="white" backgroundColor={COUNCIL_RGB}>{offer.badge}</ui.Text>
      </ui.Box>
      <ui.Text bold color="red">{` \u2717 ${offer.notice}  `}</ui.Text>
      <ui.Button key="retry:accept" hotkey="r" label={offer.label} onPress={press.accept} />
      <ui.Text>{' '}</ui.Text>
      <ui.Button key="retry:skip" hotkey="s" label={offer.skipLabel} onPress={press.skip} />
      <ui.Text color={COUNCIL_RGB}>{`  ${offer.bar}`}</ui.Text>
      <ui.Text dimColor>{` ${offer.remaining}s  click, or ctrl+x tab then r / s`}</ui.Text>
    </ui.Box>
  )
}

export const register: Register = (on, options) => {
  const settings = paneOptions(options)
  const state: PaneState = { root: '', drawn: '', isPolling: false, shown: new Set(), lastError: '', pidCheckedAtMs: 0, frame: 0, nowMs: 0, queryingSinceMs: {}, fitted: new Map(), specialists: [], finishing: new Set(), identityFailures: new Set(), specialistError: '', specialistFrame: 0, paneFollowFrames: 0, inputEpoch: 0 }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: REOPEN_COMMAND, description: 'Reopen the council pane, or forget where it was told to open', argumentHint: '[ask]', immediate: true })
    await $.command.register({ name: SETUP_COMMAND, description: 'Add, edit or remove specialists', immediate: true })
    if (settings.offersTool) await $.tool.register({ name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: TOOL_SCHEMA })
    // An entry that does not parse is reported, never dropped quietly.
    const roster = specialistRoster(options)
    for (const problem of roster.problems) $.ui.log(problem)
    state.specialists = roster.specialists
    // A Save reloads this module; the screen's draft comes back from the store.
    state.setup = restoreSetup(await $.store.get(SETUP_KEY), specialistEntries(options).entries)
    // An open setup screen was drawn by the reloaded module before the store
    // was read; draw it again with it.
    $.ui.invalidate('ui.render')
    // Registered with no specialists too, so a user can ask Claude to set the first one up.
    await $.tool.register({ name: SPECIALIST_TOOL, description: specialistDescription(roster.specialists), inputSchema: specialistSchema(roster.specialists) })
    if (roster.specialists.length > 0) {
      // The band's clock moves only while a round runs.
      $.clock.every(1000, () => { void logFailure($, state, () => followSpecialist($, state)) })
      // The chip's shimmer moves only while a round runs.
      $.clock.every(FRAME_MS, () => {
        if (!state.specialist) return
        state.specialistFrame += 1
        if (state.paneFollowFrames > 0) void followOpenedPane($, state)
        $.ui.invalidate('ui.render')
      })
      await logFailure($, state, () => recoverRounds($, state))
    }
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
      state.drawn = JSON.stringify([state.view, state.retryShown])
      $.ui.invalidate('ui.render')
    }
    return result
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isCouncilRun(e.command)) await aimRun($, state, settings)
    return next(e)
  })

  // The settings row says ask while an answer is remembered; its label says which.
  on('config.describe', async ($, e, next) => {
    const row = await next(e)
    // /specialists edits the list; the menu would only show its JSON.
    if (e.key === LIST_KEY) return { ...row, isHidden: true }
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

  // Every start, follow-up and finish is confirmed in a dialog: a specialist
  // writes code with its own model, and a finish merges or deletes its branch.
  on('tool.call', { tool: /^mcp__claude-council__specialist$/ }, async ($, e) => {
    const call = specialistCall(e as unknown as Record<string, unknown>, state.specialists)
    if ('deny' in call) return { deny: call.deny }
    // Claude proposes, the user saves: the screen opens prefilled and nothing is written here.
    if (call.kind === 'setup') {
      const refused = await openSetup($, state, options, call.fields)
      return refused ? { deny: `the setup screen did not open: ${refused}` } : { result: 'Opened the setup screen; nothing is saved until the user presses Save.' }
    }
    const sh = (args: string[], init?: { stdin?: string }) => specialistRun($, args, init)
    const kv = keyValues
    // One round at a time across every session: they all share the store. A
    // round that ended with nobody following it is closed first.
    for (const r of Object.values(await loadRuns($))) {
      if (r.state !== 'running') continue
      const now = await roundState($, state, r)
      if (now !== 'running') await finishRound($, state, r, now)
    }
    const runs = await loadRuns($)
    const live = Object.values(runs).find(r => r.state === 'running')
    const ask = async (question: string, go: string, stop: string) => {
      try { return await $.ui.ask(question, { header: 'Specialist', options: [go, stop] }) } catch { return undefined }
    }

    // Starts a round and returns at once; followSpecialist closes it.
    // The store says running only once the round's pid is on disk, so no
    // session reads a round that has not launched yet as lost or ended. A
    // round that fails to launch leaves the record as it was.
    const round = async (record: RunRecord, prompt: string, thread: string, subject: string, isDirty = false) => {
      const roundBase = (await sh(['head', record.worktree])).stdout.trim()
      const running: RunRecord = { ...record, rounds: record.rounds + 1, state: 'running', startedMs: await $.clock.now(), roundBase, subject }
      const stateDir = stateDirOf(running)
      const launched = await sh(['codex', record.worktree, stateDir, record.model, record.effort ?? '', ...(thread ? [thread] : [])], { stdin: prompt })
      if (launched.exitCode !== 0) {
        await saveRun($, record)
        return { result: `Run ${record.id}: the round did not start: ${launched.stderr.trim()}`, isError: true as const }
      }
      await saveRun($, running)
      state.specialist = { record: running, startedMs: running.startedMs, stateDir }
      state.specialistLog = { record: running, steps: [], isLive: true }
      $.ui.invalidate('ui.render')
      // An open pane follows the new round; a closed one refuses, and follows
      // once opened from the band.
      await followPaneEnd($, 'round start', 'debug')
      return { result: startedReply(running, isDirty) }
    }

    if (call.kind === 'start') {
      if (live) return { deny: `${live.specialist} is still working on run ${live.id}` }
      const login = await $.process.run(['codex', 'login', 'status']).catch(() => undefined)
      if (!login || login.exitCode !== 0) return { deny: 'codex is not installed or not logged in; run `codex login`' }
      const cwd = await $.session.cwd()
      const top = await $.process.run(['git', '-C', cwd, 'rev-parse', '--short=7', 'HEAD'])
      if (top.exitCode !== 0) return { deny: `${cwd} is not inside a git repository with a commit` }
      const dirty = (await $.process.run(['git', '-C', cwd, 'status', '--porcelain'])).stdout.trim() !== ''
      const s = call.specialist
      const ts = runStamp(new Date(await $.clock.now()))
      const started = await sh(['start', cwd, s.name, ts])
      if (started.exitCode !== 0) return { result: started.stderr.trim() || 'could not create the worktree', isError: true }
      const at = kv(started.stdout)
      const instructions = s.instructions ?? ''
      const record: RunRecord = {
        id: `${s.name}-${ts}`, specialist: s.name, model: s.model, ...(s.effort ? { effort: s.effort } : {}), prompt: instructions,
        repo: at.repo ?? '', worktree: at.worktree ?? '', branch: at.branch ?? '', base: at.base ?? '', thread: '', rounds: 0, state: 'idle', startedMs: 0, roundBase: '', subject: '',
      }
      return await round(record, specialistPrompt(instructions, call.task), '', commitSubject(s.name, call.task), dirty)
    }

    const record = Object.hasOwn(runs, call.run) ? runs[call.run] : undefined
    if (call.kind === 'result') {
      if (!record) return { deny: `no run ${call.run}` }
      if (record.state === 'running') return { deny: `${record.specialist} is still working on run ${record.id}; a prompt arrives when the round ends` }
      if (!record.last) return { deny: `run ${record.id} has no finished round yet` }
      return record.last.isError ? { result: record.last.result, isError: true as const } : { result: record.last.result }
    }
    if (call.kind === 'followUp') {
      const exists = record ? await $.fs.exists(record.worktree) : false
      const refusal = followUpRefusal(record, call.run, exists)
      if (refusal || !record) return { deny: refusal ?? `no run ${call.run}` }
      if (live) return { deny: `${live.specialist} is still working on run ${live.id}` }
      return await round(record, call.message, record.thread, `specialist ${record.specialist}: round ${record.rounds + 1}`)
    }

    if (!record || record.state === 'finished') return { deny: `no open run ${call.run}` }
    if (record.state === 'running') return { deny: `${record.specialist} is still working on run ${record.id}` }
    const counted = await sh(['counts', record.repo, record.branch, record.base])
    // A branch deleted by hand has nothing to merge; discard still closes the run.
    if (counted.exitCode !== 0 && call.finish === 'merge') return { result: `Run ${record.id} not finished: ${counted.stderr.trim()}`, isError: true }
    const counts = kv(counted.stdout)
    const target = counts.target || 'a detached HEAD'
    const go = call.finish === 'merge' ? 'Merge' : 'Discard'
    const question = finishQuestion(record, call.finish, Number(counts.commits ?? 0), Number(counts.files ?? 0), target)
    const outcome = dialogOutcome(await ask(question, go, 'Keep it'), go, 'Keep it', `kept run ${record.id}`)
    if ('deny' in outcome) return { deny: outcome.deny }
    if ('reply' in outcome) return { result: outcome.reply }
    const current = (await loadRuns($))[record.id]
    if (current?.state !== 'idle') return { deny: `run ${record.id} changed while the dialog was open` }
    const finished = await sh(['finish', current.repo, current.worktree, current.branch, call.finish])
    if (finished.exitCode === 0) {
      await saveRun($, { ...current, state: 'finished' })
      return { result: `Run ${current.id}: ${call.finish === 'merge' ? `merged into ${target}` : 'discarded'}; worktree and branch removed.` }
    }
    const lines = finished.stdout.trim()
    const why = finished.exitCode === 3 ? `merge conflicts, merge aborted; worktree and branch kept:\n${lines}`
      : finished.exitCode === 4 ? `your uncommitted changes touch the branch's files; commit or stash them first:\n${lines}`
      : finished.exitCode === 5 ? 'the repository is on a detached HEAD; check out a branch to merge into'
      : finished.exitCode === 6 ? `git refused the merge:\n${finished.stderr.trim()}`
      : finished.stderr.trim() || 'finish failed'
    return { result: `Run ${current.id} not finished: ${why}`, isError: true }
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

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
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
          <ui.Text bold {...(finished.isFailure ? { color: 'red' } : {})}>{` ${finished.isFailure ? '\u2717' : '\u2713'} ${finished.text}  `}</ui.Text>
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
    const working = state.specialist
    if (working) {
      const ui = $.ui.resolve(e)
      const clock = roundClock(working.startedMs, state.nowMs)
      return (
        <ui.Box key="specialist" flexDirection="row" marginTop={1}>
          {/* Only the step gives way when the band is narrow, as beside an open pane. */}
          {chip(ui, 'chip', 'SPECIALIST', state.specialistFrame)}
          <ui.Box flexShrink={0}>
            <ui.Text>
              <ui.Text bold>{`  ${working.record.specialist}`}</ui.Text>
              <ui.Text color={MODEL_RGB}>{`  ${working.record.model}`}</ui.Text>
              <ui.Text bold color={roundStatus(true, undefined, clock).color}>{`  \u25cf ${clock}`}</ui.Text>
            </ui.Text>
          </ui.Box>
          <ui.Box flexGrow={1} flexShrink={1}>
            <ui.Text dimColor wrap="truncate-end">{`  ${latestStep(state.specialistLog?.steps ?? [])}  `}</ui.Text>
          </ui.Box>
          <ui.Box flexShrink={0}>
            <ui.Button key="specialist:open" hotkey="o" label={'o \u00b7 open pane'} onPress={() => { void $.ui.open({ id: SPECIALIST_PANE, title: `Specialist ${working.record.specialist}` }).then(() => { state.paneFollowFrames = PANE_FOLLOW_FRAMES }) }} />
          </ui.Box>
        </ui.Box>
      )
    }
    const progress = state.view ? progressBand(state.view, state.runStartedMs, state.nowMs) : undefined
    if (!progress) return next(e)
    const ui = $.ui.resolve(e)
    return (
      <ui.Box key="progress" flexDirection="row" marginTop={1}>
        {chip(ui, 'chip', 'COUNCIL', state.frame)}
        <ui.Text color={COUNCIL_RGB}>{`  ${progress.bar}`}</ui.Text>
        <ui.Text>{`  ${progress.text}  `}</ui.Text>
        <ui.Button key="progress:open" hotkey="o" label={'o \u00b7 open pane'} onPress={() => { void $.ui.open({ id: PANE_ID, title: 'Council' }) }} />
      </ui.Box>
    )
  })

  // Scrolling back down to the last rows follows new steps again; scrolling up
  // stops it, as the engine's own `end` does.
  // The setup screen's own writes skip this hook (the engine does not run a
  // plugin's hooks for its own $.config.set); a list set by hand lands here.
  on('config.set', { key: LIST_KEY }, async ($, e, next) => {
    const denial = await handEditDenial($, typeof e.value === 'string' ? e.value : '')
    return denial ? { deny: denial } : next(e)
  })

  on('command.run', { command: SETUP_COMMAND }, async ($) => {
    const refused = await openSetup($, state, options)
    return { text: refused ? `The setup screen did not open: ${refused}` : 'Specialists: esc closes the screen.' }
  })

  // Closing the screen keeps a draft only when it holds changes; an untouched
  // one would reopen the form for nothing.
  on('ui.close', { id: SETUP_PANE }, async ($, e, next) => {
    const draft = state.setup?.draft
    if (e.origin.kind === 'person' && !(draft && isDirty(draft))) await keepSetup($, state, undefined)
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== SETUP_PANE) return next(e)
    const ui = $.ui.resolve(e)
    if (!('Input' in ui)) return <ui.Text key="setup-mobile">Specialists are set up in the terminal or desktop app.</ui.Text>
    const { Box, Text, Input, Select, Button } = ui
    const setup = currentSetup(state)
    const view = setupView(setup, specialistEntries(options).entries)
    const draft = setup.draft
    const editor = view.editor
    const width = Math.max(30, e.props.bodyColumns - 2)
    const press = (work: () => Promise<void>) => () => { void setupAction($, state, work) }
    const edit = (patch: Partial<Fields>) => { void setupAction($, state, () => editSetup($, state, patch)) }
    // A help line sits under the values and keeps to one row: a pane taller than
    // the terminal hands the keyboard back to the prompt.
    const help = (key: string, text: string) => (
      <Box key={key} flexDirection="row">
        <Box key="indent" width={HELP_INDENT.length} flexShrink={0}><Text key="pad">{HELP_INDENT}</Text></Box>
        <Box key="body" flexShrink={1}><Text key="text" dimColor wrap="truncate-end">{text}</Text></Box>
      </Box>
    )
    return (
      <Box key="setup" flexDirection="column" width={width}>
        {/* The roster: one frame, two lines per specialist, the one being edited marked. */}
        <Text key="roster-chip" bold color="white" backgroundColor={COUNCIL_RGB}>{` ${view.header} `}</Text>
        <Box key="roster" flexDirection="column" borderStyle="round" borderColor={COUNCIL_RGB} paddingX={1}>
          {view.empty ? <Text key="empty" dimColor wrap="wrap">{view.empty}</Text> : null}
          {view.roster.map(entry => (
            <Box key={`entry:${entry.index}`} flexDirection="column">
              <Box key="line" flexDirection="row">
                <Button key={`row:${entry.index}`} plain label={entry.name} onPress={press(() => openRow($, state, options, entry.index))} />
                {/* Only the detail gives way on a narrow pane; a long one is cut, never the model. */}
                <Box key="model" flexShrink={0}><Text key="text" color={MODEL_RGB}>{entry.model ? `  ${entry.model}` : ''}</Text></Box>
                <Box key="detail" flexShrink={1}><Text key="text" dimColor wrap="truncate-end">{`  ${entry.detail}`}</Text></Box>
                {entry.editing ? <Box key="editing" flexShrink={0}><Text key="gap">{'  '}</Text><Text key="text" bold color="white" backgroundColor={COUNCIL_RGB}>{' EDITING '}</Text></Box> : null}
              </Box>
              {entry.problem
                ? <Text key="problem" color={STATUS_RGB.error} wrap="wrap">{`  ${entry.problem}`}</Text>
                : <Text key="when" dimColor wrap="wrap">{`  when: ${entry.when}`}</Text>}
            </Box>
          ))}
          <Button key="add" label="+ Add specialist" onPress={press(() => openRow($, state, options, 'new'))} />
        </Box>
        {editor && draft ? (
          <Box key="editor-wrap" flexDirection="column" marginTop={1}>
            <Box key="editor-head" flexDirection="row">
              <Text key="editor-chip" bold color="white" backgroundColor={COUNCIL_RGB}>{` ${editor.title} `}</Text>
              {editor.unsaved ? <Text key="unsaved" color={COUNCIL_RGB}>{'  unsaved changes'}</Text> : null}
            </Box>
            <Box key="editor" flexDirection="column" borderStyle="round" borderColor={COUNCIL_RGB} paddingX={1}>
              <Input key={`name.${state.inputEpoch}`} label="Name         " placeholder="lowercase, e.g. sec" value={draft.name} autoFocus onInput={(v: string) => edit({ name: v })} onSubmit={(v: string) => { void setupAction($, state, () => submitField($, state, { name: v }, { control: 'model' })) }} />
              <Select key="model" label="Model        " value={draft.model || editor.modelOptions[0]?.value} options={editor.modelOptions}
                onSelect={(v: string) => { void setupAction($, state, () => pickModel($, state, v)) }} />
              {editor.models === 'loading' ? help('models-loading', 'loading models from Codex') : null}
              {editor.models === 'failed' ? (
                <Box key="models-failed" flexDirection="row">
                  <Text key="failed" color={STATUS_RGB.error}>{`${HELP_INDENT}could not load models  `}</Text>
                  <Button key="retry" label="Retry" onPress={press(() => loadCatalog($, state))} />
                </Box>
              ) : null}
              <Select key="effort" label="Effort       " value={draft.effort || 'default'} options={editor.effortOptions} onSelect={(v: string) => edit({ effort: v === 'default' ? '' : v })} />
              {editor.effortHelp ? help('effort-help', editor.effortHelp) : null}
              <Input key={`when.${state.inputEpoch}`} label="Use when     " placeholder="tasks Claude should offer it for" value={draft.when} onInput={(v: string) => edit({ when: v })} onSubmit={(v: string) => { void setupAction($, state, () => submitField($, state, { when: v }, { input: 'instructions' })) }} />
              {help('when-help', editor.whenHelp)}
              <Input key={`instructions.${state.inputEpoch}`} label="Instructions " placeholder="optional, e.g. review migrations for locks" value={draft.instructions} onInput={(v: string) => edit({ instructions: v })} onSubmit={(v: string) => { void setupAction($, state, () => submitField($, state, { instructions: v }, { control: 'save' })) }} />
              {help('instructions-help', editor.instructionsHelp)}
              <Box key="actions" flexDirection="row">
                <Button key="save" label="Save" onPress={press(() => saveSetup($, state, options))} />
                <Text key="gap-1">{'  '}</Text>
                {editor.removable ? <Button key="remove" label="Remove" onPress={press(() => askSetup($, state, { kind: 'remove' }))} /> : null}
                {editor.removable ? <Text key="gap-2">{'  '}</Text> : null}
                <Button key="discard" label={editor.discardLabel} onPress={press(() => discardSetup($, state))} />
              </Box>
            </Box>
          </Box>
        ) : null}
        {view.confirm ? (
          <Box key="confirm" flexDirection="column" marginTop={1}>
            <Text key="question" bold wrap="wrap">{view.confirm.text}</Text>
            <Box key="answers" flexDirection="row">
              <Button key="confirm-yes" label={view.confirm.yes} onPress={press(() => confirmSetup($, state, options))} />
              <Text key="gap">{'  '}</Text>
              <Button key="confirm-no" label={view.confirm.no} onPress={press(() => askSetup($, state, undefined))} />
            </Box>
          </Box>
        ) : null}
        {view.status ? (
          <Box key="status" flexDirection="row" marginTop={1}>
            <Text key="label" bold color="white" backgroundColor={STATUS_RGB[view.status.kind]}>{STATUS_LABEL[view.status.kind]}</Text>
            <Text key="text" wrap="wrap">{` ${view.status.text}`}</Text>
          </Box>
        ) : null}
        <Text key="keys" dimColor wrap="truncate-end">{'Tab next · Shift+Tab back · ↓ opens a list, Enter picks · Esc closes, draft kept'}</Text>
      </Box>
    )
  })

  on('ui.scroll', { requestId: SPECIALIST_PANE }, async ($, e, next) => {
    const moved = await next(e)
    if (!moved.deny && landsAtEnd(e)) await followPaneEnd($, 'scrolled to the bottom', 'transcript')
    return moved
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    const log = state.specialistLog
    if (e.requestId !== SPECIALIST_PANE || !log) return next(e)
    const ui = $.ui.resolve(e)
    const { Box, Markdown, Text } = ui
    const columns = e.props.bodyColumns
    const { record } = log
    const mark = (step: Step) => (step.state === 'running' ? ['\u22ef', 'yellow'] : step.state === 'failed' ? ['\u2717', 'red'] : ['\u2713', 'green'])
    const status = roundStatus(log.isLive, record.last, roundClock(record.startedMs, state.nowMs))
    const cardWidth = Math.max(20, columns - 2)
    return (
      <Box key="specialist" flexDirection="column">
        {/* A card, like a sidebar entry: who, how it stands, then where it works. */}
        <Box flexDirection="column" borderStyle="round" borderColor={COUNCIL_RGB} paddingX={1} width={cardWidth}>
          {/* Each group is its own element, so a narrow pane wraps between
              groups, never inside one. */}
          <Box flexDirection="row" flexWrap="wrap" columnGap={2}>
            {chip(ui, 'chip', 'SPECIALIST', log.isLive ? state.specialistFrame : undefined)}
            <Text bold>{record.specialist}</Text>
            <Text bold color={status.color}>{`${status.glyph} ${status.text}`}</Text>
            <Text dimColor>{`round ${record.rounds}`}</Text>
            <Text color={MODEL_RGB}>{record.model}</Text>
          </Box>
          {/* A line exactly as wide as the card wraps to an empty second line
              without truncate. */}
          <Text color={COUNCIL_RGB} dimColor wrap="truncate">{'\u2500'.repeat(cardWidth - 4)}</Text>
          {/* The worktree is cut from the left: its last part names the run. */}
          <Box flexDirection="row">
            <Text dimColor>{'branch    '}</Text>
            <Box flexShrink={1}><Text color={BRANCH_RGB} wrap="truncate-start">{record.branch}</Text></Box>
          </Box>
          <Box flexDirection="row">
            <Text dimColor>{'worktree  '}</Text>
            <Box flexShrink={1}><Text color={WORKTREE_RGB} wrap="truncate-start">{record.worktree.replace(/^\/(Users|home)\/[^/]+/, '~')}</Text></Box>
          </Box>
        </Box>
        <Text>
          <Text bold color={COUNCIL_RGB}>{' STEPS'}</Text>
          <Text dimColor>{`  ${log.steps.filter(step => step.kind === 'run' || step.kind === 'edit').length}`}</Text>
        </Text>
        {log.steps.map((step, index) => {
          const key = `step-${index}`
          // Codex writes markdown; a paragraph break sets its words off from the commands.
          if (step.kind === 'say') {
            return (
              <Box key={key} flexDirection="row" marginTop={1} marginBottom={1}>
                <Text dimColor>{'\u25cf '}</Text>
                <Box flexDirection="column" flexShrink={1}>
                  {markdownBlocks(step.text).map((block, part) => <Markdown key={`${key}-${part}`} text={block} />)}
                </Box>
              </Box>
            )
          }
          if (step.kind === 'think') return <Text key={key} dimColor italic>{`  ${step.text}`}</Text>
          const [glyph, color] = mark(step)
          const isDone = step.state === 'done'
          if (step.kind === 'edit') {
            return (
              <Text key={key}>
                <Text color={color}>{`${glyph} `}</Text>
                <Text color={COUNCIL_RGB}>{'\u270e '}</Text>
                <Text bold={!isDone}>{step.text}</Text>
              </Text>
            )
          }
          const line = step.text.replace(/\s*\n\s*/g, ' ')
          const program = line.split(' ')[0] ?? ''
          return (
            <Text key={key} wrap="truncate-end">
              <Text color={color}>{`${glyph} `}</Text>
              <Text color={COUNCIL_RGB}>{'$ '}</Text>
              <Text bold color={step.state === 'failed' ? 'red' : undefined}>{program}</Text>
              <Text dimColor={isDone} color={step.state === 'failed' ? 'red' : undefined}>{line.slice(program.length)}</Text>
            </Text>
          )
        })}
        {/* A message already ends in a blank line; margins do not collapse. */}
        {log.isLive && (
          <Box marginTop={log.steps.at(-1)?.kind === 'say' ? 0 : 1}>
            <Text dimColor>{workingLine(state.specialistFrame, record.startedMs, state.nowMs)}</Text>
          </Box>
        )}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== PANE_ID || !state.view) return next(e)
    const { Box, Button, Markdown, Text } = $.ui.resolve(e)
    const columns = e.props.bodyColumns
    const fit = (sectionKey: string, text: string) => {
      const kept = state.fitted.get(sectionKey)
      if (kept && kept.columns === columns && kept.text === text) return kept.blocks
      const blocks = markdownBlocks(fitTables(text, columns))
      state.fitted.set(sectionKey, { columns, text, blocks })
      return blocks
    }
    const draw = (section: Section, index: number) => {
      const key = `section-${index}`
      switch (section.kind) {
        case 'note':
          return <Text key={key} dimColor>{section.text}</Text>
        case 'status':
          return (
            <Box key={key} flexDirection="row">
              <Text color={section.glyphColor}>{`${section.glyph} `}</Text>
              <Text bold>{`${section.name}  `}</Text>
              <Text color={section.stateColor}>{`${section.state}  `}</Text>
              <Text dimColor>{`${section.time}  `}</Text>
              <Text dimColor>{section.model}</Text>
            </Box>
          )
        case 'summary':
          return <Text key={key} bold>{section.text}</Text>
        case 'strip':
          return (
            <Box key={key} flexDirection="row" flexWrap="wrap">
              {section.items.map(item => (
                <Box key={`${key}-${item.name}`} flexDirection="row">
                  <Text color={item.color}>{`${item.glyph} `}</Text>
                  {item.target ? (
                    <Button
                      key={`press:${item.name}`}
                      plain
                      label={item.name}
                      {...(item.hotkey ? { hotkey: item.hotkey } : {})}
                      onPress={() => { void $.ui.scroll({ in: PANE_ID, to: { key: item.target ?? '' }, block: 'start' }) }}
                    />
                  ) : (
                    <Text dimColor>{item.name}</Text>
                  )}
                  <Text>{'  '}</Text>
                </Box>
              ))}
            </Box>
          )
        case 'banner':
          return (
            <Box key={section.key} flexDirection="row" marginTop={1} paddingX={1} width={columns} backgroundColor={section.background}>
              <Text bold color="white" backgroundColor={section.background}>{section.title}</Text>
              <Text italic color="white" backgroundColor={section.background}>{` ${section.subtitle}`}</Text>
            </Box>
          )
        case 'synthesis':
          return (
            <Box key={section.key} flexDirection="column" marginTop={1}>
              <Box flexDirection="row" paddingX={1} width={columns} backgroundColor={COUNCIL_RGB}>
                <Text bold color="white" backgroundColor={COUNCIL_RGB}>SYNTHESIS</Text>
              </Box>
              {fit(key, section.text).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
            </Box>
          )
        case 'body':
          // Tables are fitted to the pane's width, which only a render knows.
          return (
            <Box key={key} flexDirection="column">
              {fit(key, section.text).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
            </Box>
          )
        case 'error':
          return (
            <Box key={section.key} flexDirection="column" marginTop={1}>
              <Text bold color="red">{`\u2717 ${section.title}`}</Text>
              <Text color="red" dimColor>{(markdownBlocks(section.text, 2000)[0] ?? '')}</Text>
            </Box>
          )
      }
    }
    const retry = state.retryShown
    const runDir = state.runDir
    return (
      <Box flexDirection="column">
        {e.surface !== 'terminal' && retry && runDir ? [retryRow($.ui.resolve(e), retry, retryPresses($, runDir))] : []}
        {paneSections(state.view, { ...settings, frame: state.frame, nowMs: state.nowMs }).map(draw)}
      </Box>
    )
  })
}
