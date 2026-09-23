// ABOUTME: Pure decisions for the specialist tool: rows, call shapes, dialog text, prompts, results
// ABOUTME: No engine calls here, so every rule runs under bun test

export type Roles = Record<string, { name: string; prompt: string }>
export type Specialist = { name: string; model: string; perspective: string; when: string }

const ROW = /^\s*([^=\s]+)\s*=\s*(\S+)\s+as\s+([^,\s]+)\s*,\s*when:\s*(.+?)\s*$/
const NAME = /^[a-z][a-z0-9-]{0,23}$/
const WHEN_MAX = 200
const SHAPE = 'expected: name = model as perspective, when: use-when'
export const SLOTS = ['specialist_1', 'specialist_2', 'specialist_3', 'specialist_4']

export function parseSpecialist(row: unknown, roles: Roles): Specialist | { error: string } | undefined {
  if (row === undefined || (typeof row === 'string' && row.trim() === '')) return undefined
  if (typeof row !== 'string') return { error: SHAPE }
  const match = ROW.exec(row)
  if (!match) return { error: SHAPE }
  const [, name = '', model = '', perspective = '', when = ''] = match
  if (!NAME.test(name)) return { error: `name '${name}' must be lowercase letters, digits and dashes, starting with a letter` }
  if (!Object.hasOwn(roles, perspective)) return { error: `unknown perspective '${perspective}'` }
  if (when.length > WHEN_MAX) return { error: `use-when is longer than ${WHEN_MAX} characters` }
  return { name, model, perspective, when }
}

export function specialistRoster(options: Record<string, unknown>, roles: Roles): { specialists: Specialist[]; problems: string[] } {
  const specialists: Specialist[] = []
  const problems: string[] = []
  const usedBy = new Map<string, string>()
  for (const slot of SLOTS) {
    const parsed = parseSpecialist(options[slot], roles)
    if (parsed === undefined) continue
    if ('error' in parsed) { problems.push(`${slot} ignored: ${parsed.error}`); continue }
    const earlier = usedBy.get(parsed.name)
    if (earlier) { problems.push(`${slot} ignored: the name '${parsed.name}' is already used by ${earlier}`); continue }
    usedBy.set(parsed.name, slot)
    specialists.push(parsed)
  }
  return { specialists, problems }
}

export function specialistDescription(list: Specialist[]): string {
  const roster = list.map(s => `${s.name} (${s.perspective}, ${s.model}), use when: ${s.when}`).join('; ')
  return (
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    `Specialists: ${roster}. ` +
    'Suggest one when a task matches its use-when. Start with {specialist, task}; send review feedback with {run, message}; ' +
    'rounds run in the background and a prompt arrives when one ends, then fetch it with {run, result: true}; ' +
    'the tool commits each round itself, so never tell a specialist to commit; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'The user confirms before anything starts or is sent. A refusal comes back as the result; do not retry unless the reply asks for a change.'
  )
}

export function specialistSchema(list: Specialist[]): Record<string, unknown> {
  return {
    type: 'object',
    properties: {
      specialist: { type: 'string', enum: list.map(s => s.name) },
      task: { type: 'string', description: 'Start: the task, self-contained; the specialist sees only its worktree.' },
      run: { type: 'string', description: 'Follow-up or finish: the run id a start returned.' },
      message: { type: 'string', description: 'Follow-up: feedback for the specialist, e.g. a failing test.' },
      finish: { type: 'string', enum: ['merge', 'discard'] },
      result: { type: 'boolean', description: 'Fetch the last round\'s result: {run, result: true}, after the prompt saying the round ended.' },
    },
    additionalProperties: false,
  }
}

export type RunRecord = {
  id: string; specialist: string; model: string; perspective: string; prompt: string
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

const SHAPES = 'give one of {specialist, task}, {run, message}, {run, finish} or {run, result: true}'
const QUOTED_MAX = 300
const quote = (text: string) => (text.length > QUOTED_MAX ? `${text.slice(0, QUOTED_MAX)}…` : text)
const filled = (value: unknown) => typeof value === 'string' && value.trim() !== ''

export function specialistCall(input: Record<string, unknown>, list: Specialist[]): SpecialistCall | { deny: string } {
  const { specialist, task, run, message, finish, result } = input
  const has = (v: unknown) => v !== undefined
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

export function startQuestion(s: Specialist, task: string, head: string, isDirty: boolean): string {
  const dirty = isDirty ? ' Your uncommitted changes are not included.' : ''
  return `Hand "${quote(task)}" to ${s.name} (${s.perspective}, ${s.model})? It works in a new worktree from HEAD ${head}.${dirty}`
}

export function followUpQuestion(record: RunRecord, message: string): string {
  return `Send to ${record.specialist} (run ${record.id}): "${quote(message)}"?`
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

export function specialistPrompt(perspectivePrompt: string, task: string): string {
  return `${perspectivePrompt}\n\nTask:\n${task}\n\nWork only inside this directory. Run the tests you touch. Do not commit: the tool commits your changes after each round.`
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
    return { isError: true, result: [head, refused, `${OWN_REPORT}\n${r.lastMessage}`].join('\n\n') }
  }
  if (!r.commit && !r.roundStat) return { isError: false, result: [head, 'No changes this round.', `${OWN_REPORT}\n${r.lastMessage}`].join('\n\n') }
  // The specialist wrote its report before the tool committed, so it cannot
  // know the commit exists; the tool's own line settles it.
  const who = r.commit ? `The tool committed this round on the branch as ${r.commit}.` : 'The specialist committed this round itself.'
  const changes = `This round:\n${r.roundStat}\nSince ${record.base}:\n${r.totalStat}`
  return { isError: false, result: [head, who, changes, `${OWN_REPORT}\n${r.lastMessage}`].join('\n\n') }
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

export type Step = { kind: 'say' | 'run' | 'edit'; text: string; state: 'running' | 'done' | 'failed' }

// Codex wraps each command in the login shell: `/bin/zsh -lc "git status"`.
const SHELL_WRAP = /^\/bin\/\w+ -lc (["'])([\s\S]*)\1$/

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
    if (item.type === 'agent_message' && typeof item.text === 'string') step = { kind: 'say', text: item.text, state: 'done' }
    if (item.type === 'command_execution' && typeof item.command === 'string') {
      step = { kind: 'run', text: SHELL_WRAP.exec(item.command)?.[2] ?? item.command, state: status }
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
export function roundLiveness(exitText: string, isProcessAlive: boolean): 'running' | 'ended' | 'lost' {
  if (exitText.trim() !== '') return 'ended'
  return isProcessAlive ? 'running' : 'lost'
}

// A fixed-width m:ss clock, so the line it sits on does not shift each second.
export function roundClock(startedMs: number, nowMs: number): string {
  const secs = Math.max(0, Math.floor((nowMs - startedMs) / 1000))
  const hours = Math.floor(secs / 3600)
  const mins = Math.floor((secs % 3600) / 60)
  const ss = String(secs % 60).padStart(2, '0')
  return hours > 0 ? `${hours}:${String(mins).padStart(2, '0')}:${ss}` : `${mins}:${ss}`
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

export function startedReply(record: RunRecord): string {
  return `Run ${record.id} (${record.specialist}, round ${record.rounds}) started in the background.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\n` +
    'A prompt arrives when the round ends; the band above the prompt shows its progress. Do not poll for it.'
}

export function lostResult(record: RunRecord, status: string): { result: string; isError: boolean } {
  const head = `Run ${record.id} (${record.specialist}, round ${record.rounds}) stopped before it finished: its process is gone and left no exit code.\nBranch: ${record.branch}\nWorktree: ${record.worktree}`
  return { isError: true, result: status ? `${head}\n\nUncommitted in the worktree:\n${status}` : head }
}
