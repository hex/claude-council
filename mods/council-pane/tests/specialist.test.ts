// ABOUTME: Tests for reading specialist rows out of the options register receives
// ABOUTME: Expected values are literals; bad rows must produce a named problem, never vanish
import { test, expect } from 'bun:test'
import {
  parseSpecialist, specialistRoster, specialistDescription, specialistSchema,
  specialistCall, runStamp, startQuestion, followUpQuestion, finishQuestion, dialogOutcome, specialistPrompt, followUpRefusal, roundResult, settledRuns, threadFrom,
  type RunRecord,
} from '../hooks/specialist'

const roles = {
  security: { name: 'Security Auditor', prompt: 'You are a security-focused code reviewer.' },
  performance: { name: 'Performance Optimizer', prompt: 'You are a performance-focused engineer.' },
}

test('a well-formed row parses into its four parts', () => {
  expect(parseSpecialist('sec = gpt-6-sol as security, when: auth, crypto, untrusted input', roles)).toEqual({
    name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth, crypto, untrusted input',
  })
})

test('spacing around the separators is tolerated', () => {
  expect(parseSpecialist('  perf=gpt-6-astra  as performance ,when:hot loops ', roles)).toEqual({
    name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'hot loops',
  })
})

test('an empty or absent row is unused, not a problem', () => {
  expect(parseSpecialist('', roles)).toBeUndefined()
  expect(parseSpecialist('   ', roles)).toBeUndefined()
  expect(parseSpecialist(undefined, roles)).toBeUndefined()
})

test('a bad row names what is wrong', () => {
  expect(parseSpecialist('sec = gpt-6-sol as secrity, when: auth', roles)).toEqual({ error: "unknown perspective 'secrity'" })
  expect(parseSpecialist('Sec = gpt-6-sol as security, when: auth', roles)).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(parseSpecialist('sec = as security, when: auth', roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
  expect(parseSpecialist('sec = gpt-6-sol as security', roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
  expect(parseSpecialist(`sec = gpt-6-sol as security, when: ${'x'.repeat(201)}`, roles)).toEqual({ error: 'use-when is longer than 200 characters' })
  expect(parseSpecialist(42, roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
})

test('the roster keeps valid rows in slot order and reports the rest', () => {
  expect(specialistRoster({
    specialist_1: 'sec = gpt-6-sol as security, when: auth',
    specialist_2: 'sec = gpt-6-astra as performance, when: loops',
    specialist_3: 'perf = gpt-6-astra as secrity, when: loops',
    specialist_4: 'perf = gpt-6-astra as performance, when: loops',
  }, roles)).toEqual({
    specialists: [
      { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth' },
      { name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'loops' },
    ],
    problems: [
      "specialist_2 ignored: the name 'sec' is already used by specialist_1",
      "specialist_3 ignored: unknown perspective 'secrity'",
    ],
  })
  expect(specialistRoster({}, roles)).toEqual({ specialists: [], problems: [] })
})

test('the description lists every specialist and the confirmation rule', () => {
  const list = [
    { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth, crypto' },
    { name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'hot loops' },
  ]
  expect(specialistDescription(list)).toBe(
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    'Specialists: sec (security, gpt-6-sol), use when: auth, crypto; perf (performance, gpt-6-astra), use when: hot loops. ' +
    'Suggest one when a task matches its use-when. Start with {specialist, task}; send review feedback with {run, message}; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'The user confirms before anything starts or is sent. A refusal comes back as the result; do not retry unless the reply asks for a change.',
  )
})

test('the schema limits specialist to the configured names', () => {
  const schema = specialistSchema([{ name: 'sec', model: 'm', perspective: 'security', when: 'w' }]) as any
  expect(schema.properties.specialist).toEqual({ type: 'string', enum: ['sec'] })
  expect(schema.properties.finish).toEqual({ type: 'string', enum: ['merge', 'discard'] })
  expect(schema.additionalProperties).toBe(false)
})

const sec = { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth' }
const record: RunRecord = {
  id: 'sec-20260923-151204', specialist: 'sec', model: 'gpt-6-sol', perspective: 'security', prompt: 'You are a security-focused code reviewer.',
  repo: '/r/app', worktree: '/r/app.specialists/sec-20260923-151204', branch: 'specialist/sec/20260923-151204',
  base: 'a1b2c3d', thread: '01a0ce2a-1d08-76c0-a6ef-8340b581212d', rounds: 1, state: 'idle',
}

test('each call shape is recognised, and nothing else is', () => {
  expect(specialistCall({ specialist: 'sec', task: 'harden login' }, [sec])).toEqual({ kind: 'start', specialist: sec, task: 'harden login' })
  expect(specialistCall({ run: 'sec-1', message: 'fix x.ts:40' }, [sec])).toEqual({ kind: 'followUp', run: 'sec-1', message: 'fix x.ts:40' })
  expect(specialistCall({ run: 'sec-1', finish: 'discard' }, [sec])).toEqual({ kind: 'finish', run: 'sec-1', finish: 'discard' })
  expect(specialistCall({ specialist: 'nope', task: 't' }, [sec])).toEqual({ deny: "no specialist named 'nope'; configured: sec" })
  expect(specialistCall({ specialist: 'sec', task: '  ' }, [sec])).toEqual({ deny: 'task must be a non-empty string' })
  expect(specialistCall({ run: 'sec-1', message: 'm', finish: 'merge' }, [sec])).toEqual({ deny: 'give one of {specialist, task}, {run, message} or {run, finish}' })
  expect(specialistCall({ run: 'sec-1', finish: 'keep' }, [sec])).toEqual({ deny: 'finish must be merge or discard' })
  expect(specialistCall({}, [sec])).toEqual({ deny: 'give one of {specialist, task}, {run, message} or {run, finish}' })
})

test('runStamp is local time, zero padded', () => {
  expect(runStamp(new Date(2026, 8, 3, 7, 5, 9))).toBe('20260903-070509')
})

test('the start question names the specialist, the base and a dirty tree', () => {
  expect(startQuestion(sec, 'harden login', 'a1b2c3d', false)).toBe('Hand "harden login" to sec (security, gpt-6-sol)? It works in a new worktree from HEAD a1b2c3d.')
  expect(startQuestion(sec, 'x'.repeat(301), 'a1b2c3d', true)).toBe(
    `Hand "${'x'.repeat(300)}…" to sec (security, gpt-6-sol)? It works in a new worktree from HEAD a1b2c3d. Your uncommitted changes are not included.`,
  )
})

test('follow-up and finish questions', () => {
  expect(followUpQuestion(record, 'fix x.ts:40')).toBe('Send to sec (run sec-20260923-151204): "fix x.ts:40"?')
  expect(finishQuestion(record, 'merge', 3, 4, 'main')).toBe('Merge specialist/sec/20260923-151204 (3 commits, 4 files) into main?')
  expect(finishQuestion(record, 'discard', 3, 4, 'main')).toBe('Discard run sec-20260923-151204 and delete its branch?')
})

test('only the go label proceeds; Other text goes back to the model', () => {
  expect(dialogOutcome('Start sec', 'Start sec', "Don't start", 'did not start sec')).toEqual({ go: true })
  expect(dialogOutcome("Don't start", 'Start sec', "Don't start", 'did not start sec')).toEqual({ deny: 'The user did not start sec.' })
  expect(dialogOutcome(undefined, 'Start sec', "Don't start", 'did not start sec')).toEqual({ deny: 'The user was not asked (dialog dismissed or no one to ask), so the user did not start sec.' })
  expect(dialogOutcome('use perf instead', 'Start sec', "Don't start", 'did not start sec')).toEqual({ deny: 'The user did not start sec and said: use perf instead' })
})

test('the prompt puts the perspective first and the ground rules last', () => {
  expect(specialistPrompt('You are a security-focused code reviewer.', 'harden login')).toBe(
    'You are a security-focused code reviewer.\n\nTask:\nharden login\n\nWork only inside this directory. Run the tests you touch.',
  )
})

test('a follow-up needs a live run with its worktree', () => {
  expect(followUpRefusal(undefined, 'sec-9', true)).toBe('no run sec-9; start a new one')
  expect(followUpRefusal({ ...record, state: 'finished' }, record.id, true)).toBe(`run ${record.id} is finished; start a new one`)
  expect(followUpRefusal({ ...record, state: 'running' }, record.id, true)).toBe(`sec is still working on run ${record.id}`)
  expect(followUpRefusal(record, record.id, false)).toBe(`run ${record.id} has no worktree any more; start a new one`)
  expect(followUpRefusal(record, record.id, true)).toBeUndefined()
})

test('a round result carries what Claude needs to review', () => {
  const base = { record, lastMessage: 'Added a rate limit.', roundStat: ' src/login.ts | 12 +++', totalStat: ' src/login.ts | 12 +++', status: '', stderrTail: '', commitError: '' }
  expect(roundResult({ ...base, exitCode: 0, committed: true })).toEqual({
    isError: false,
    result: `Run ${record.id} (sec, round 1) finished.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\nThis round:\n src/login.ts | 12 +++\nSince ${record.base}:\n src/login.ts | 12 +++\n\nSpecialist's summary:\nAdded a rate limit.`,
  })
  expect(roundResult({ ...base, exitCode: 0, committed: false, roundStat: '', totalStat: '' }).result).toContain('No changes this round.')
  const failed = roundResult({ ...base, exitCode: 1, committed: false, status: ' M src/login.ts', stderrTail: 'boom' })
  expect(failed.isError).toBe(true)
  expect(failed.result).toContain('Codex exited 1; nothing was committed.')
  expect(failed.result).toContain('Uncommitted in the worktree:\n M src/login.ts')
  expect(failed.result).toContain('Codex stderr (tail):\nboom')
})

test('a record left running by a reload or crash reads as idle; the live round stays running', () => {
  const stale = { ...record, id: 'sec-1', state: 'running' as const }
  const live = { ...record, id: 'sec-2', state: 'running' as const }
  const done = { ...record, id: 'sec-3', state: 'finished' as const }
  expect(settledRuns({ 'sec-1': stale, 'sec-2': live, 'sec-3': done }, 'sec-2')).toEqual({
    'sec-1': { ...stale, state: 'idle' }, 'sec-2': live, 'sec-3': done,
  })
  expect(settledRuns({ 'sec-1': stale }, undefined)).toEqual({ 'sec-1': { ...stale, state: 'idle' } })
})

test('a round whose commit was refused is an error that names the refusal, not "no changes"', () => {
  const refused = roundResult({
    record, exitCode: 0, committed: false, lastMessage: 'Added a rate limit.', roundStat: '', totalStat: '',
    status: ' M src/login.ts', stderrTail: '', commitError: 'pre-commit: lint failed',
  })
  expect(refused).toEqual({
    isError: true,
    result: `Run ${record.id} (sec, round 1) finished.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\n` +
      `The round's commit failed; the changes are uncommitted in the worktree:\n M src/login.ts\n\ngit said:\npre-commit: lint failed\n\n` +
      "Specialist's summary:\nAdded a rate limit.",
  })
})

test('the thread id is read from the first thread.started event, and only a UUID counts', () => {
  const events = '{"type":"thread.started","thread_id":"01a0ce2a-1d08-76c0-a6ef-8340b581212d"}\n{"type":"turn.started"}\n{"type":"thread.started","thread_id":"99999999-0000-0000-0000-000000000000"}\n'
  expect(threadFrom(events)).toBe('01a0ce2a-1d08-76c0-a6ef-8340b581212d')
  expect(threadFrom('{"type":"turn.started"}\n')).toBe('')
  expect(threadFrom('')).toBe('')
  expect(threadFrom('{"type":"thread.started","thread_id":"--last"}\n')).toBe('')
})
