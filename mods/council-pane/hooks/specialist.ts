// ABOUTME: Pure decisions for the specialist tool: rows, call shapes, dialog text, prompts, results
// ABOUTME: No engine calls here, so every rule runs under bun test
import { spinner } from './view'
import type { Fields } from './setup'

// effort is Codex's reasoning effort; without it the user's own Codex default applies.
// instructions open every task the specialist starts; without them it just follows the task.
export type Specialist = { name: string; model: string; effort?: string; when: string; instructions?: string }

export const INSTRUCTIONS_MAX = 400
const EFFORT = /^[a-z]+$/
const NAME = /^[a-z][a-z0-9-]{0,23}$/
export const WHEN_MAX = 200
const FIELDS = ['name', 'model', 'effort', 'when', 'instructions']
const SHAPE = 'a specialist must be a JSON object with name, model and when'
// The one settings field that holds every specialist, as a JSON list of objects.
export const LIST_FIELD = 'specialists'

// One wording for a bad name, whether it came from the list or the setup screen's field.
export function nameProblem(name: string): string | undefined {
  return NAME.test(name) ? undefined : `name '${name}' must be lowercase letters, digits and dashes, starting with a letter`
}

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)

// A field a person or another version wrote by hand must say what is wrong
// with it; a misspelt key would otherwise be dropped without a word.
function textField(entry: Record<string, unknown>, field: string, isRequired: boolean): string | undefined | { error: string } {
  const value = entry[field]
  if (value === undefined) return isRequired ? { error: `${field} is missing` } : undefined
  return typeof value === 'string' ? value : { error: `${field} must be a string` }
}

export function parseSpecialist(entry: unknown): Specialist | { error: string } {
  if (!isRecord(entry)) return { error: SHAPE }
  const unknown = Object.keys(entry).find(key => !FIELDS.includes(key))
  if (unknown !== undefined) return { error: `unknown field '${unknown}'` }
  const read: Record<string, string | undefined> = {}
  for (const field of FIELDS) {
    const value = textField(entry, field, field === 'name' || field === 'model' || field === 'when')
    if (typeof value === 'object') return value
    read[field] = value
  }
  const { name = '', model = '', effort, when = '', instructions } = read
  const badName = nameProblem(name)
  if (badName) return { error: badName }
  if (model.trim() === '') return { error: 'model is empty' }
  if (when.trim() === '') return { error: 'use-when is empty' }
  if (when.length > WHEN_MAX) return { error: `use-when is longer than ${WHEN_MAX} characters` }
  if (effort !== undefined && !EFFORT.test(effort)) return { error: `effort '${effort}' must be lowercase letters` }
  if (instructions !== undefined && instructions.length > INSTRUCTIONS_MAX) return { error: `instructions are longer than ${INSTRUCTIONS_MAX} characters` }
  const hasInstructions = instructions !== undefined && instructions.trim() !== ''
  return { name, model, ...(effort === undefined ? {} : { effort }), when, ...(hasInstructions ? { instructions } : {}) }
}

// Reads the specialists list from the plugin's options; a value that is not a
// JSON list is a named problem, never an empty list in disguise. Each entry is
// checked by parseSpecialist, so a bad one is reported by its place.
export function specialistEntries(options: Record<string, unknown>): { entries: unknown[]; problem?: string } {
  const value = options[LIST_FIELD]
  if (value === undefined || (typeof value === 'string' && value.trim() === '')) return { entries: [] }
  if (typeof value !== 'string') return { entries: [], problem: 'the specialists setting must be a JSON list' }
  let data: unknown
  try { data = JSON.parse(value) } catch { return { entries: [], problem: `the specialists setting is not JSON: ${value}` } }
  if (!Array.isArray(data)) return { entries: [], problem: 'the specialists setting must be a JSON list' }
  return { entries: data }
}

export function specialistRoster(options: Record<string, unknown>): { specialists: Specialist[]; problems: string[] } {
  const { entries, problem } = specialistEntries(options)
  const specialists: Specialist[] = []
  const problems: string[] = problem ? [problem] : []
  const usedBy = new Map<string, number>()
  entries.forEach((entry, index) => {
    const parsed = parseSpecialist(entry)
    if ('error' in parsed) { problems.push(`specialist ${index + 1} ignored: ${parsed.error}`); return }
    const earlier = usedBy.get(parsed.name)
    if (earlier !== undefined) { problems.push(`specialist ${index + 1} ignored: the name '${parsed.name}' is already used by specialist ${earlier + 1}`); return }
    usedBy.set(parsed.name, index)
    specialists.push(parsed)
  })
  return { specialists, problems }
}

// Without this Claude fills instructions in on its own, and they open every task.
const INSTRUCTIONS_HINT = 'instructions is optional: what the specialist is told before each task, in the user\'s words; leave it out unless the user gave some.'

export function specialistDescription(list: Specialist[]): string {
  if (list.length === 0) {
    return (
      'Set up a specialist: a coding agent that works in its own git worktree with its own model. None are set up yet. ' +
      `When the user asks for one, call {setup: {${SETUP_FIELDS.join(', ')}}} with what they described; ` +
      'it opens a screen with those fields filled in and nothing is saved until the user presses Save. ' +
      INSTRUCTIONS_HINT
    )
  }
  const roster = list.map(s => `${s.name} (${s.model}), use when: ${s.when}`).join('; ')
  return (
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    `Specialists: ${roster}. ` +
    'When a task matches a use-when, offer that specialist to the user; start one only when the user asked for it or agreed. ' +
    `When no specialist fits and the user wants one, or the user describes one, call {setup: {${SETUP_FIELDS.join(', ')}}}; it opens a screen with those fields filled in and nothing is saved until the user presses Save. ` +
    `${INSTRUCTIONS_HINT} ` +
    'Start with {specialist, task}; send review feedback with {run, message}; ' +
    'rounds run in the background and a prompt arrives when one ends, then fetch it with {run, result: true}; ' +
    'the tool commits each round itself, so never tell a specialist to commit; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'A start or follow-up runs at once; the user confirms every finish. A refusal comes back as the result; do not retry unless the reply asks for a change.'
  )
}

export function specialistSchema(list: Specialist[]): Record<string, unknown> {
  const setup = {
    type: 'object',
    description: 'Open the setup screen prefilled with a proposed specialist; the user saves it.',
    properties: Object.fromEntries(SETUP_FIELDS.map(field => [field, { type: 'string' }])),
    additionalProperties: false,
  }
  // With no specialists there is nothing to start; setting one up is the only call.
  if (list.length === 0) return { type: 'object', properties: { setup }, additionalProperties: false }
  return {
    type: 'object',
    properties: {
      specialist: { type: 'string', enum: list.map(s => s.name) },
      task: { type: 'string', description: 'Start: the task, self-contained; the specialist sees only its worktree.' },
      run: { type: 'string', description: 'Follow-up or finish: the run id a start returned.' },
      message: { type: 'string', description: 'Follow-up: feedback for the specialist, e.g. a failing test.' },
      finish: { type: 'string', enum: ['merge', 'discard'] },
      result: { type: 'boolean', description: 'Fetch the last round\'s result: {run, result: true}, after the prompt saying the round ended.' },
      setup,
    },
    additionalProperties: false,
  }
}

export type RunRecord = {
  id: string; specialist: string; model: string; effort?: string
  // The instructions the run started with; '' when it had none.
  prompt: string
  repo: string; worktree: string; branch: string; base: string; thread: string
  rounds: number; state: 'running' | 'idle' | 'finished'
  // When the current or last round started; the band's clock.
  startedMs: number
  // What the current or last round started from, and the subject its commit gets.
  roundBase: string
  subject: string
  // The last finished round's result, fetched with {run, result: true}.
  last?: { result: string; isError: boolean }
}

export type SpecialistCall =
  | { kind: 'start'; specialist: Specialist; task: string }
  | { kind: 'followUp'; run: string; message: string }
  | { kind: 'finish'; run: string; finish: 'merge' | 'discard' }
  | { kind: 'result'; run: string }
  | { kind: 'setup'; fields: Partial<Fields> }

const SHAPES = 'give one of {specialist, task}, {run, message}, {run, finish}, {run, result: true} or {setup}'
const SETUP_FIELDS = ['name', 'model', 'effort', 'when', 'instructions']
const filled = (value: unknown) => typeof value === 'string' && value.trim() !== ''

export function specialistCall(input: Record<string, unknown>, list: Specialist[]): SpecialistCall | { deny: string } {
  const { specialist, task, run, message, finish, result } = input
  const has = (v: unknown) => v !== undefined
  if (has(input.setup)) {
    if (has(specialist) || has(task) || has(run) || has(message) || has(finish) || has(result)) return { deny: SHAPES }
    const fields = input.setup
    const isFields = typeof fields === 'object' && fields !== null && !Array.isArray(fields) &&
      Object.entries(fields).every(([key, value]) => SETUP_FIELDS.includes(key) && typeof value === 'string')
    if (!isFields) return { deny: `setup fields must be strings: ${SETUP_FIELDS.join(', ')}` }
    return { kind: 'setup', fields: fields as Partial<Fields> }
  }
  if (has(result)) {
    if (result !== true || !filled(run) || has(specialist) || has(task) || has(message) || has(finish)) return { deny: SHAPES }
    return { kind: 'result', run: run as string }
  }
  if (has(specialist) && !has(run) && !has(message) && !has(finish)) {
    const found = list.find(s => s.name === specialist)
    if (!found) return { deny: `no specialist named '${String(specialist)}'; configured: ${list.map(s => s.name).join(', ')}` }
    if (!filled(task)) return { deny: 'task must be a non-empty string' }
    return { kind: 'start', specialist: found, task: task as string }
  }
  if (has(run) && has(message) && !has(finish) && !has(specialist) && !has(task)) {
    if (!filled(run) || !filled(message)) return { deny: 'run and message must be non-empty strings' }
    return { kind: 'followUp', run: run as string, message: message as string }
  }
  if (has(run) && has(finish) && !has(message) && !has(specialist) && !has(task)) {
    if (finish !== 'merge' && finish !== 'discard') return { deny: 'finish must be merge or discard' }
    if (!filled(run)) return { deny: 'run must be a non-empty string' }
    return { kind: 'finish', run: run as string, finish }
  }
  return { deny: SHAPES }
}

const two = (n: number) => String(n).padStart(2, '0')
export function runStamp(date: Date): string {
  return `${date.getFullYear()}${two(date.getMonth() + 1)}${two(date.getDate())}-${two(date.getHours())}${two(date.getMinutes())}${two(date.getSeconds())}`
}

export function finishQuestion(record: RunRecord, finish: 'merge' | 'discard', commits: number, files: number, target: string): string {
  return finish === 'merge'
    ? `Merge ${record.branch} (${commits} commits, ${files} files) into ${target}?`
    : `Discard run ${record.id} and delete its branch?`
}

// Text typed under Other comes back as a reply, which the tool returns as a
// plain result: a refusal is drawn as an error, and a typed answer is not one.
export function dialogOutcome(answer: string | undefined, go: string, stop: string, refusal: string): { go: true } | { deny: string } | { reply: string } {
  if (answer === go) return { go: true }
  if (answer === undefined) return { deny: `The user was not asked (dialog dismissed or no one to ask), so the user ${refusal}.` }
  if (answer === stop) return { deny: `The user ${refusal}.` }
  return { reply: `The user ${refusal} and said: ${answer}` }
}

export function specialistPrompt(instructions: string, task: string): string {
  const opening = instructions.trim() === '' ? '' : `${instructions}\n\n`
  return `${opening}Task:\n${task}\n\nWork only inside this directory. Run the tests you touch. Do not commit: the tool commits your changes after each round.`
}

export function followUpRefusal(record: RunRecord | undefined, id: string, worktreeExists: boolean): string | undefined {
  if (!record) return `no run ${id}; start a new one`
  if (record.state === 'finished') return `run ${id} is finished; start a new one`
  if (record.state === 'running') return `${record.specialist} is still working on run ${id}`
  if (!worktreeExists) return `run ${id} has no worktree any more; start a new one`
  if (!record.thread) return `run ${id} has no Codex thread to resume; start a new one`
  return undefined
}

const OWN_REPORT = "The specialist's own report (written before the tool committed):"

export type TestResult = 'pass' | 'fail' | 'not_run'
export type RoundReport = { summary: string; tests: { command: string; result: TestResult; detail: string }[]; open_questions: string[] }

const TEST_RESULTS: readonly string[] = ['pass', 'fail', 'not_run']
const isString = (v: unknown): v is string => typeof v === 'string'
const hasKeys = (v: Record<string, unknown>, keys: string[]) => {
  const own = Object.keys(v)
  return own.length === keys.length && keys.every((k) => own.includes(k))
}

// The round's last message, in the shape scripts/specialist-report.schema.json
// asks Codex for. The two describe one shape: change them together. Anything
// else, including valid JSON of another shape, is undefined.
export function parseRoundReport(text: string): RoundReport | undefined {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return undefined
  }
  if (!isRecord(value) || !hasKeys(value, ['summary', 'tests', 'open_questions'])) return undefined
  const { summary, tests, open_questions } = value
  if (!isString(summary) || !Array.isArray(tests) || !Array.isArray(open_questions) || !open_questions.every(isString)) return undefined
  const testOk = (t: unknown) => isRecord(t) && hasKeys(t, ['command', 'result', 'detail']) &&
    isString(t.command) && isString(t.detail) && isString(t.result) && TEST_RESULTS.includes(t.result)
  if (!tests.every(testOk)) return undefined
  return value as RoundReport
}

export function parseSpecialistReport(output: string): { round: string; total: string; status: string } {
  const sections = { round: '', total: '', status: '' }
  const parts = output.split(/^--- (round|total|status)\n/gm)
  for (let i = 1; i < parts.length; i += 2) {
    sections[parts[i] as keyof typeof sections] = parts[i + 1]?.trimEnd() ?? ''
  }
  return sections
}

const TEST_LABEL: Record<TestResult, string> = { pass: 'pass', fail: 'fail', not_run: 'not run' }
const oneLine = (text: string) => text.replace(/[ \t\r\n]+/g, (space) => space.includes('\n') || space.includes('\r') ? ' ' : space).trim()

// What the specialist said about its round, for Claude to review. A message
// that is not a schema-shaped report is shown as written, and says so.
function reportText(lastMessage: string): string {
  if (!lastMessage) return 'The specialist wrote no report.'
  const report = parseRoundReport(lastMessage)
  if (!report) return `It did not match the report schema; its last message as written:\n${lastMessage}`
  const tests = report.tests.length
    ? `Tests:\n${report.tests.map((t) => `- ${TEST_LABEL[t.result]}: ${t.command}${t.detail ? ` (${oneLine(t.detail)})` : ''}`).join('\n')}`
    : 'Tests: none reported.'
  const questions = report.open_questions.length
    ? `Open questions:\n${report.open_questions.map((q) => `- ${oneLine(q)}`).join('\n')}`
    : 'Open questions: none.'
  return [report.summary, tests, questions].join('\n\n')
}

export function roundResult(r: {
  record: RunRecord; exitCode: number; lastMessage: string; roundStat: string; totalStat: string
  // The short sha of the commit the tool made for this round; '' when it made none.
  commit: string; status: string; stderrTail: string; commitError: string
}): { result: string; isError: boolean } {
  const { record } = r
  const head = `Run ${record.id} (${record.specialist}, round ${record.rounds}) ${r.exitCode === 0 ? 'finished' : 'failed'}.\nBranch: ${record.branch}\nWorktree: ${record.worktree}`
  if (r.exitCode !== 0) {
    const parts = [head, `Codex exited ${r.exitCode}; nothing was committed.`]
    if (r.status) parts.push(`Uncommitted in the worktree:\n${r.status}`)
    if (r.lastMessage) parts.push(`Specialist's last message:\n${r.lastMessage}`)
    if (r.stderrTail) parts.push(`Codex stderr (tail):\n${r.stderrTail}`)
    return { isError: true, result: parts.join('\n\n') }
  }
  if (r.commitError) {
    const refused = `The round's commit failed; the changes are uncommitted in the worktree:\n${r.status}\n\ngit said:\n${r.commitError}`
    return { isError: true, result: [head, refused, `${OWN_REPORT}\n${reportText(r.lastMessage)}`].join('\n\n') }
  }
  if (!r.commit && !r.roundStat) return { isError: false, result: [head, 'No changes this round.', `${OWN_REPORT}\n${reportText(r.lastMessage)}`].join('\n\n') }
  // The specialist wrote its report before the tool committed, so it cannot
  // know the commit exists; the tool's own line settles it.
  const who = r.commit ? `The tool committed this round on the branch as ${r.commit}.` : 'The specialist committed this round itself.'
  const changes = `This round:\n${r.roundStat}\nSince ${record.base}:\n${r.totalStat}`
  return { isError: false, result: [head, who, changes, `${OWN_REPORT}\n${reportText(r.lastMessage)}`].join('\n\n') }
}

const THREAD_STARTED = /"type":"thread\.started","thread_id":"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"/

// The Codex session a round opened, from its JSON event stream. A round cut off
// at the time limit reports nothing, but its first event is already on disk.
export function threadFrom(events: string): string {
  for (const line of events.split('\n')) {
    if (!line.includes('"thread.started"')) continue
    return THREAD_STARTED.exec(line)?.[1] ?? ''
  }
  return ''
}

const SUBJECT_MAX = 72
const cut = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text)

// A git subject line: the task's first real line, cut at a word so the whole
// subject stays near 72 characters.
export function commitSubject(name: string, task: string): string {
  const prefix = `specialist ${name}: `
  const line = task.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  const room = SUBJECT_MAX - prefix.length - 1
  if (line.length <= room + 1) return prefix + line
  const space = line.lastIndexOf(' ', room)
  return `${prefix}${space > room / 2 ? line.slice(0, space) : line.slice(0, room)}…`
}

// think is a short reasoning summary, Codex's own bold title for what it is working out.
export type Step = { kind: 'think' | 'say' | 'run' | 'edit'; text: string; state: 'running' | 'done' | 'failed' }

// Codex runs a quoted command or a single unquoted token through the login shell.
const SHELL_WRAP = /^\/bin\/\w+ -lc (?:(["'])([\s\S]*)\1|([^\s"']+))$/

// The round's closing message is the report as JSON; the pane shows what a
// reader wants from it. The commands already show above it, so tests do not.
function sayText(text: string): string {
  const report = parseRoundReport(text)
  if (!report) return text
  if (!report.open_questions.length) return report.summary
  return `${report.summary}\n\nOpen questions:\n${report.open_questions.map((q) => `- ${q}`).join('\n')}`
}

// One step per Codex item, in first-seen order, each updated as its later
// events arrive. The file is read while Codex writes it, so a half-written
// last line is skipped rather than parsed.
export function specialistSteps(events: string, worktree: string): Step[] {
  const order: string[] = []
  const byId = new Map<string, Step>()
  for (const line of events.split('\n')) {
    let event: { type?: string; item?: Record<string, unknown> }
    try { event = JSON.parse(line) } catch { continue }
    const item = event.item
    if (!item || typeof item.id !== 'string') continue
    const status = item.status === 'failed' ? 'failed' : event.type === 'item.completed' ? 'done' : 'running'
    let step: Step | undefined
    if (item.type === 'reasoning' && typeof item.text === 'string') step = { kind: 'think', text: item.text.replace(/\*\*/g, '').trim(), state: 'done' }
    if (item.type === 'agent_message' && typeof item.text === 'string') step = { kind: 'say', text: sayText(item.text), state: 'done' }
    if (item.type === 'command_execution' && typeof item.command === 'string') {
      const match = SHELL_WRAP.exec(item.command)
      step = { kind: 'run', text: match?.[2] ?? match?.[3] ?? item.command, state: status }
    }
    if (item.type === 'file_change' && Array.isArray(item.changes)) {
      const paths = item.changes.map(c => String((c as { path?: unknown }).path ?? '')).map(p => p.startsWith(`${worktree}/`) ? p.slice(worktree.length + 1) : p)
      step = { kind: 'edit', text: paths.join(', '), state: status }
    }
    if (!step) continue
    if (!byId.has(item.id)) order.push(item.id)
    byId.set(item.id, step)
  }
  return order.map(id => byId.get(id) as Step)
}

const BAND_STEP_MAX = 59

export function latestStep(steps: Step[]): string {
  const step = steps[steps.length - 1]
  if (!step) return ''
  if (step.kind === 'run') return `$ ${cut(step.text, BAND_STEP_MAX)}`
  if (step.kind === 'edit') return `✎ ${cut(step.text, BAND_STEP_MAX)}`
  return cut(step.text.split('\n')[0] ?? '', BAND_STEP_MAX + 2)
}

// A round is over once its exit file exists; a process gone without one was
// killed, and nothing will ever finish it.
export type RoundProcessIdentity = 'same' | 'gone' | 'unknown'

export function roundLiveness(exitText: string, identity: RoundProcessIdentity): 'running' | 'ended' | 'lost' {
  if (exitText.trim() !== '') return 'ended'
  return identity === 'gone' ? 'lost' : 'running'
}

export function roundProcessPresence(exitCode: number, stderr: string): 'present' | 'absent' | 'unknown' {
  if (exitCode === 0) return 'present'
  // The round subshell belongs to this user, so EPERM means its pid was reused.
  if (/no such process|operation not permitted/i.test(stderr)) return 'absent'
  return 'unknown'
}

export function roundProcessIdentity(
  recordedIdentity: string | undefined, observedIdentity: string | undefined, presence: 'present' | 'absent' | 'unknown',
): RoundProcessIdentity {
  if (presence === 'absent') return 'gone'
  if (presence === 'unknown') return 'unknown'
  if (recordedIdentity === undefined) return 'same'
  const recorded = recordedIdentity.trim().replace(/\s+/g, ' ')
  const observed = observedIdentity?.trim().replace(/\s+/g, ' ')
  const startTime = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$/
  if (!startTime.test(recorded) || observed === undefined || !startTime.test(observed)) return 'unknown'
  return recorded === observed ? 'same' : 'gone'
}

// A fixed-width m:ss clock, so the line it sits on does not shift each second.
export function roundClock(startedMs: number, nowMs: number): string {
  const secs = Math.max(0, Math.floor((nowMs - startedMs) / 1000))
  const hours = Math.floor(secs / 3600)
  const mins = Math.floor((secs % 3600) / 60)
  const ss = String(secs % 60).padStart(2, '0')
  return hours > 0 ? `${hours}:${String(mins).padStart(2, '0')}:${ss}` : `${mins}:${ss}`
}

// The pane's last line while a round runs, so it moves even while Codex
// thinks and no step is running.
export function workingLine(frame: number, startedMs: number, nowMs: number): string {
  return `${spinner(frame)} working  ${roundClock(startedMs, nowMs)}`
}

// The engine keeps a pane scrolled to its end only until something else moves
// it. A move of the person's that lands on the last rows asks to follow again;
// the window's last offset is contentRows - bodyRows, and a tree that fits has
// none.
export function landsAtEnd(e: { offset: number; bodyRows: number; contentRows: number; origin: { kind: string } }): boolean {
  return e.origin.kind === 'person' && e.offset >= e.contentRows - e.bodyRows
}

// The one coloured item in the pane's header: how the round stands.
export function roundStatus(isLive: boolean, last: RunRecord['last'], clock: string): { glyph: string; text: string; color: string } {
  // A dark amber: a terminal's own yellow is unreadable on a light background.
  if (isLive) return { glyph: '\u25cf', text: clock, color: 'rgb(191,112,0)' }
  if (last?.isError) return { glyph: '\u2717', text: `failed ${clock}`, color: 'red' }
  return { glyph: '\u2713', text: `ended ${clock}`, color: 'green' }
}

// Submitted as a prompt when a round ends. It names the run only: the
// specialist's own words reach the model as a tool result, never as a prompt.
export function specialistWake(record: RunRecord): string {
  return `Specialist ${record.specialist} finished round ${record.rounds} of run ${record.id}. ` +
    `Fetch its result with mcp__claude-council__specialist {"run": "${record.id}", "result": true}, review it, and ask the user before any follow-up or finish.`
}

export function startedReply(record: RunRecord, isDirty = false): string {
  const dirty = isDirty ? 'Your uncommitted changes are not in its worktree.\n' : ''
  return `Run ${record.id} (${record.specialist}, round ${record.rounds}) started in the background.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n${dirty}\n` +
    'A prompt arrives when the round ends; the band above the prompt shows its progress. Do not poll for it.'
}

export function lostResult(record: RunRecord, status: string): { result: string; isError: boolean } {
  const head = `Run ${record.id} (${record.specialist}, round ${record.rounds}) stopped before it finished: its process is gone and left no exit code.\nBranch: ${record.branch}\nWorktree: ${record.worktree}`
  return { isError: true, result: status ? `${head}\n\nUncommitted in the worktree:\n${status}` : head }
}
