// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import type { Elements, EngineInterface, Register } from 'claude-code'
import { decideHost, HOST_LABELS, HOST_QUESTION, HOST_STORE_KEY, hostFrom, hostRowLabel, isCouncilRun, paneCommand, type HostSetting, type PaneHost } from './host'
import { abandonedNotice, FINISH_NOTICE_MS, finishNotice, jobOutcome, noticeIsLive, reopenReply, runPid, wakePrompt, type FinishNotice, progressBand } from './notices'
import { paneOptions, type PaneOptions } from './options'
import { parseRetryOffer, retrySection, type RetryOffer, type RetrySection } from './retry'
import { readText, readView, type Files } from './snapshot'
import {
  dialogOutcome, finishQuestion, followUpQuestion, followUpRefusal, roundResult, runStamp, settledRuns, specialistCall,
  specialistDescription, specialistPrompt, specialistRoster, specialistSchema, startQuestion,
  type Roles, type RunRecord, type Specialist,
} from './specialist'
import { confirmOutcome, confirmQuestion, councilArgs, KEEP_LABEL, SEND_LABEL, TOOL_DESCRIPTION, TOOL_NAME, TOOL_SCHEMA } from './tool'
import { extractSynthesis } from './synthesis'
import { fitTables } from './tables'
import { markdownBlocks, paneSections, queryingSince, unseenRun, type RunView, type Section } from './view'

const PANE_ID = 'council'
const REOPEN_COMMAND = 'council-pane'
const RUN_TIMEOUT_MS = 600_000
// Claude's orange (#D97757): the council speaks inside Claude Code, and the
// synthesis is Claude's own text. No provider's banner uses it.
const COUNCIL_RGB = 'rgb(217,119,87)'
const POLL_MS = 500
// Ten frames a second: the spinner's pace in the tmux pane.
const FRAME_MS = 100
// The worker records its result seconds after .done; a worker killed outright
// leaves its record at running, so the wait for it ends.
const WAKE_WAIT_MS = 120_000
// How often a run still going is asked whether its process is alive.
const PID_CHECK_MS = 5_000
const SPECIALIST_TOOL = 'specialist'
const RUNS_KEY = 'specialist-runs'
// A round waits on Codex for as long as the engine lets a process run.
const ROUND_MS = 600_000

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
  roles: Roles
  // The specialist round this session is waiting on; the band's subject.
  specialist?: { record: RunRecord; startedMs: number }
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
  const state: PaneState = { root: '', drawn: '', isPolling: false, shown: new Set(), lastError: '', pidCheckedAtMs: 0, frame: 0, nowMs: 0, queryingSinceMs: {}, fitted: new Map(), specialists: [], roles: {} }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: REOPEN_COMMAND, description: 'Reopen the council pane, or forget where it was told to open', argumentHint: '[ask]', immediate: true })
    if (settings.offersTool) await $.tool.register({ name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: TOOL_SCHEMA })
    // Perspectives come from the council's own roles file, so one definition
    // serves both; a row naming a missing one is reported, never dropped quietly.
    const rolesText = await readText(files($), `${$.plugin.root}/config/roles.json`)
    const roles: Roles = rolesText ? (JSON.parse(rolesText).roles ?? {}) : {}
    const roster = specialistRoster(options, roles)
    for (const problem of roster.problems) $.ui.log(problem)
    state.specialists = roster.specialists
    state.roles = roles
    if (roster.specialists.length > 0) {
      await $.tool.register({ name: SPECIALIST_TOOL, description: specialistDescription(roster.specialists), inputSchema: specialistSchema(roster.specialists) })
      // The band's clock moves only while a round runs.
      $.clock.every(1000, () => {
        if (state.specialist) void $.clock.now().then(now => { state.nowMs = now; $.ui.invalidate('ui.render') })
      })
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
    const script = `${$.plugin.root}/scripts/specialist.sh`
    const sh = (args: string[], init?: { stdin?: string; timeoutMs?: number }) => $.process.run(['bash', script, ...args], init)
    const kv = (text: string): Record<string, string> =>
      Object.fromEntries(text.split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    const stored = ((await $.store.get(RUNS_KEY)) ?? {}) as Record<string, RunRecord>
    const runs = settledRuns(stored, state.specialist?.record.id)
    const save = async (r: RunRecord) => { runs[r.id] = r; await $.store.set(RUNS_KEY, runs) }
    const ask = async (question: string, go: string, stop: string) => {
      try { return await $.ui.ask(question, { header: 'Specialist', options: [go, stop] }) } catch { return undefined }
    }

    const round = async (record: RunRecord, prompt: string, thread: string, commitMessage: string) => {
      const roundBase = (await sh(['head', record.worktree])).stdout.trim()
      const stateDir = `${record.worktree.replace(/\/[^/]+$/, '')}/.state/${record.id}`
      await save({ ...record, state: 'running' })
      state.specialist = { record, startedMs: await $.clock.now() }
      $.ui.invalidate('ui.render')
      let exitCode = 1
      let found = thread
      try {
        const ran = await sh(['codex', record.worktree, stateDir, record.model, ...(thread ? [thread] : [])], { stdin: prompt, timeoutMs: ROUND_MS })
        const out = kv(ran.stdout)
        exitCode = ran.exitCode !== 0 ? ran.exitCode : Number(out.exit ?? 1)
        found = out.thread || thread
      } catch {
        // The engine rejects a process still running at its timeout.
        exitCode = 124
      } finally {
        state.specialist = undefined
        $.ui.invalidate('ui.render')
      }
      const done: RunRecord = { ...record, thread: found, state: 'idle' }
      const commit = exitCode === 0 ? await sh(['commit', record.worktree, commitMessage]) : undefined
      const committed = commit !== undefined && kv(commit.stdout).committed === 'yes'
      const commitError = commit && commit.exitCode !== 0 ? commit.stderr.trim() || `commit exited ${commit.exitCode}` : ''
      const report = (await sh(['report', record.worktree, roundBase, record.base])).stdout
      const section = (name: string) => report.split(`--- ${name}\n`)[1]?.split('\n--- ')[0]?.trimEnd() ?? ''
      await save(done)
      const outcome = roundResult({
        record: done, exitCode, committed, commitError,
        lastMessage: (await readText(files($), `${stateDir}/last-message.md`)).trim(),
        roundStat: section('round'), totalStat: section('total'), status: section('status'),
        stderrTail: (await readText(files($), `${stateDir}/stderr.txt`)).split('\n').slice(-15).join('\n').trim(),
      })
      return outcome.isError ? { result: outcome.result, isError: true as const } : { result: outcome.result }
    }

    if (call.kind === 'start') {
      const live = state.specialist?.record
      if (live) return { deny: `${live.specialist} is still working on run ${live.id}` }
      const login = await $.process.run(['codex', 'login', 'status']).catch(() => undefined)
      if (!login || login.exitCode !== 0) return { deny: 'codex is not installed or not logged in; run `codex login`' }
      const cwd = await $.session.cwd()
      const top = await $.process.run(['git', '-C', cwd, 'rev-parse', '--short=7', 'HEAD'])
      if (top.exitCode !== 0) return { deny: `${cwd} is not inside a git repository with a commit` }
      const dirty = (await $.process.run(['git', '-C', cwd, 'status', '--porcelain'])).stdout.trim() !== ''
      const s = call.specialist
      const go = `Start ${s.name}`
      const outcome = dialogOutcome(await ask(startQuestion(s, call.task, top.stdout.trim(), dirty), go, "Don't start"), go, "Don't start", `did not start ${s.name}`)
      if ('deny' in outcome) return { deny: outcome.deny }
      const ts = runStamp(new Date(await $.clock.now()))
      const started = await sh(['start', cwd, s.name, ts])
      if (started.exitCode !== 0) return { result: started.stderr.trim() || 'could not create the worktree', isError: true }
      const at = kv(started.stdout)
      const perspectivePrompt = state.roles[s.perspective]?.prompt ?? ''
      const record: RunRecord = {
        id: `${s.name}-${ts}`, specialist: s.name, model: s.model, perspective: s.perspective, prompt: perspectivePrompt,
        repo: at.repo ?? '', worktree: at.worktree ?? '', branch: at.branch ?? '', base: at.base ?? '', thread: '', rounds: 1, state: 'idle',
      }
      return await round(record, specialistPrompt(perspectivePrompt, call.task), '', `specialist ${s.name}: ${call.task.split('\n')[0]}`)
    }

    const record = runs[call.run]
    if (call.kind === 'followUp') {
      const exists = record ? await $.fs.exists(record.worktree) : false
      const refusal = followUpRefusal(record, call.run, exists)
      if (refusal || !record) return { deny: refusal ?? `no run ${call.run}` }
      const outcome = dialogOutcome(await ask(followUpQuestion(record, call.message), 'Send', "Don't send"), 'Send', "Don't send", `did not send this to ${record.specialist}`)
      if ('deny' in outcome) return { deny: outcome.deny }
      const next = { ...record, rounds: record.rounds + 1 }
      return await round(next, call.message, record.thread, `specialist ${record.specialist}: round ${next.rounds}`)
    }

    if (!record || record.state === 'finished') return { deny: `no open run ${call.run}` }
    if (record.state === 'running') return { deny: `${record.specialist} is still working on run ${record.id}` }
    const counts = kv((await sh(['counts', record.repo, record.branch, record.base])).stdout)
    const target = counts.target || 'a detached HEAD'
    const go = call.finish === 'merge' ? 'Merge' : 'Discard'
    const question = finishQuestion(record, call.finish, Number(counts.commits ?? 0), Number(counts.files ?? 0), target)
    const outcome = dialogOutcome(await ask(question, go, 'Keep it'), go, 'Keep it', `kept run ${record.id}`)
    if ('deny' in outcome) return { deny: outcome.deny }
    const finished = await sh(['finish', record.repo, record.worktree, record.branch, call.finish])
    if (finished.exitCode === 0) {
      await save({ ...record, state: 'finished' })
      return { result: `Run ${record.id}: ${call.finish === 'merge' ? `merged into ${target}` : 'discarded'}; worktree and branch removed.` }
    }
    const lines = finished.stdout.trim()
    const why = finished.exitCode === 3 ? `merge conflicts, merge aborted; worktree and branch kept:\n${lines}`
      : finished.exitCode === 4 ? `your uncommitted changes touch the branch's files; commit or stash them first:\n${lines}`
      : finished.exitCode === 5 ? 'the repository is on a detached HEAD; check out a branch to merge into'
      : finished.stderr.trim() || 'finish failed'
    return { result: `Run ${record.id} not finished: ${why}`, isError: true }
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
          <ui.Box flexDirection="row" paddingX={1} backgroundColor={COUNCIL_RGB}>
            <ui.Text bold color="white" backgroundColor={COUNCIL_RGB}>COUNCIL</ui.Text>
          </ui.Box>
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
      const secs = Math.max(0, Math.floor((state.nowMs - working.startedMs) / 1000))
      const clock = secs >= 60 ? `${Math.floor(secs / 60)}m ${secs % 60}s` : `${secs}s`
      return (
        <ui.Box key="specialist" flexDirection="row" marginTop={1}>
          <ui.Box flexDirection="row" paddingX={1} backgroundColor={COUNCIL_RGB}>
            <ui.Text bold color="white" backgroundColor={COUNCIL_RGB}>SPECIALIST</ui.Text>
          </ui.Box>
          <ui.Text>{`  ${working.record.specialist} \u00b7 ${working.record.perspective} \u00b7 ${clock}`}</ui.Text>
        </ui.Box>
      )
    }
    const progress = state.view ? progressBand(state.view, state.runStartedMs, state.nowMs) : undefined
    if (!progress) return next(e)
    const ui = $.ui.resolve(e)
    return (
      <ui.Box key="progress" flexDirection="row" marginTop={1}>
        <ui.Box flexDirection="row" paddingX={1} backgroundColor={COUNCIL_RGB}>
          <ui.Text bold color="white" backgroundColor={COUNCIL_RGB}>COUNCIL</ui.Text>
        </ui.Box>
        <ui.Text color={COUNCIL_RGB}>{`  ${progress.bar}`}</ui.Text>
        <ui.Text>{`  ${progress.text}  `}</ui.Text>
        <ui.Button key="progress:open" hotkey="o" label={'o \u00b7 open pane'} onPress={() => { void $.ui.open({ id: PANE_ID, title: 'Council' }) }} />
      </ui.Box>
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
