// ABOUTME: Tests for reading specialist entries out of the options register receives
// ABOUTME: Expected values are literals; bad entries must produce a named problem, never vanish
import { test, expect } from 'bun:test'
import {
  parseSpecialist, specialistRoster, specialistEntries, freshList, specialistDescription, specialistSchema,
  specialistCall, runStamp, finishQuestion, dialogOutcome, specialistPrompt, followUpRefusal, parseSpecialistReport, roundResult, threadFrom, commitSubject, specialistSteps, latestStep, roundLiveness, roundProcessIdentity, roundProcessPresence, specialistWake, startedReply, lostResult, roundClock, roundStatus, parseRoundReport, workingLine, landsAtEnd,
  type RunRecord,
} from '../hooks/specialist'

test('an entry with the required fields parses', () => {
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', when: 'auth, crypto, untrusted input' })).toEqual({
    name: 'sec', model: 'gpt-6-sol', when: 'auth, crypto, untrusted input',
  })
})

test('an entry may set the reasoning effort and instructions', () => {
  expect(parseSpecialist({ name: 'mig', model: 'gpt-6-luna', effort: 'high', when: 'schema changes', instructions: 'Review migrations for locks, rollbacks: always.' })).toEqual({
    name: 'mig', model: 'gpt-6-luna', effort: 'high', when: 'schema changes', instructions: 'Review migrations for locks, rollbacks: always.',
  })
})

test('any lowercase effort parses; which ones a model offers is checked at Save', () => {
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', effort: 'ultra', when: 'auth' })).toEqual({ name: 'sec', model: 'gpt-6-sol', effort: 'ultra', when: 'auth' })
})

test('blank instructions are the same as none', () => {
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', when: 'auth', instructions: '  ' })).toEqual({ name: 'sec', model: 'gpt-6-sol', when: 'auth' })
})

test('a specialist is on unless its entry says enabled: false', () => {
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', when: 'auth', enabled: false })).toEqual({ name: 'sec', model: 'gpt-6-sol', when: 'auth', enabled: false })
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', when: 'auth', enabled: true })).toEqual({ name: 'sec', model: 'gpt-6-sol', when: 'auth' })
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol', when: 'auth', enabled: 'no' })).toEqual({ error: 'enabled must be true or false' })
})

test('a bad entry names what is wrong', () => {
  const sec = { name: 'sec', model: 'gpt-6-sol', when: 'auth' }
  expect(parseSpecialist('sec = gpt-6-sol as security, when: auth')).toEqual({ error: 'a specialist must be a JSON object with name, model and when' })
  expect(parseSpecialist(42)).toEqual({ error: 'a specialist must be a JSON object with name, model and when' })
  expect(parseSpecialist(['sec'])).toEqual({ error: 'a specialist must be a JSON object with name, model and when' })
  expect(parseSpecialist({ ...sec, perspective: 'security' })).toEqual({ error: "unknown field 'perspective'" })
  expect(parseSpecialist({ ...sec, focus: 'locks' })).toEqual({ error: "unknown field 'focus'" })
  expect(parseSpecialist({ model: 'gpt-6-sol', when: 'auth' })).toEqual({ error: 'name is missing' })
  expect(parseSpecialist({ ...sec, model: 7 })).toEqual({ error: 'model must be a string' })
  expect(parseSpecialist({ name: 'sec', model: 'gpt-6-sol' })).toEqual({ error: 'when is missing' })
  expect(parseSpecialist({ ...sec, name: 'Sec' })).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(parseSpecialist({ ...sec, model: ' ' })).toEqual({ error: 'model is empty' })
  expect(parseSpecialist({ ...sec, when: '' })).toEqual({ error: 'use-when is empty' })
  expect(parseSpecialist({ ...sec, when: 'x'.repeat(201) })).toEqual({ error: 'use-when is longer than 200 characters' })
  expect(parseSpecialist({ ...sec, effort: 'High' })).toEqual({ error: "effort 'High' must be lowercase letters" })
  expect(parseSpecialist({ ...sec, effort: 3 })).toEqual({ error: 'effort must be a string' })
  expect(parseSpecialist({ ...sec, instructions: 'x'.repeat(401) })).toEqual({ error: 'instructions are longer than 400 characters' })
  expect(parseSpecialist({ ...sec, instructions: ['a'] })).toEqual({ error: 'instructions must be a string' })
})

test('the roster reads the specialists list, keeps valid entries in order and reports the rest', () => {
  const specialists = JSON.stringify([
    { name: 'sec', model: 'gpt-6-sol', when: 'auth' },
    { name: 'sec', model: 'gpt-6-astra', when: 'loops' },
    { name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'loops' },
    { name: 'perf', model: 'gpt-6-astra', when: 'loops', instructions: 'Measure first.' },
    { name: 'five', model: 'gpt-6-sol', when: 'a fifth one' },
  ])
  expect(specialistRoster({ specialists })).toEqual({
    specialists: [
      { name: 'sec', model: 'gpt-6-sol', when: 'auth' },
      { name: 'perf', model: 'gpt-6-astra', when: 'loops', instructions: 'Measure first.' },
      { name: 'five', model: 'gpt-6-sol', when: 'a fifth one' },
    ],
    problems: [
      "specialist 2 ignored: the name 'sec' is already used by specialist 1",
      "specialist 3 ignored: unknown field 'perspective'",
    ],
  })
  expect(specialistRoster({})).toEqual({ specialists: [], problems: [] })
  expect(specialistRoster({ specialists: '' })).toEqual({ specialists: [], problems: [] })
})

test('a specialists setting that is not a JSON list is reported, never read as empty silently', () => {
  expect(specialistEntries({ specialists: 'nope' })).toEqual({ entries: [], problem: 'the specialists setting is not JSON: nope' })
  expect(specialistEntries({ specialists: '{"a":1}' })).toEqual({ entries: [], problem: 'the specialists setting must be a JSON list' })
  expect(specialistEntries({ specialists: 3 })).toEqual({ entries: [], problem: 'the specialists setting must be a JSON list' })
  expect(specialistEntries({ specialists: '[{"name":"a"}, 2]' })).toEqual({ entries: [{ name: 'a' }, 2] })
  expect(specialistRoster({ specialists: 'nope' })).toEqual({ specialists: [], problems: ['the specialists setting is not JSON: nope'] })
  expect(specialistRoster({ specialists: '[2]' })).toEqual({ specialists: [], problems: ['specialist 1 ignored: a specialist must be a JSON object with name, model and when'] })
})

const SETUP_HINT = 'instructions is optional: what the specialist is told before each task, in the user\'s words; leave it out unless the user gave some.'

test('the description lists every specialist and what the user confirms', () => {
  const list = [
    { name: 'sec', model: 'gpt-6-sol', when: 'auth, crypto' },
    { name: 'perf', model: 'gpt-6-astra', when: 'hot loops', instructions: 'Measure first.' },
  ]
  expect(specialistDescription(list)).toBe(
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    'Specialists: sec (gpt-6-sol), use when: auth, crypto; perf (gpt-6-astra), use when: hot loops. ' +
    'When a task matches a use-when, offer that specialist to the user; start one only when the user asked for it or agreed. ' +
    'When no specialist fits and the user wants one, or the user describes one, call {setup: {name, model, effort, when, instructions}}; it opens a screen with those fields filled in and nothing is saved until the user presses Save. ' +
    SETUP_HINT + ' ' +
    'Start with {specialist, task}; send review feedback with {run, message}; ' +
    'rounds run in the background and a prompt arrives when one ends, then fetch it with {run, result: true}; ' +
    'the tool commits each round itself, so never tell a specialist to commit; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'A start or follow-up runs at once; the user confirms every finish. A refusal comes back as the result; do not retry unless the reply asks for a change.',
  )
})

test('with no specialists the tool only offers to set one up', () => {
  expect(specialistDescription([])).toBe(
    'Set up a specialist: a coding agent that works in its own git worktree with its own model. None are set up yet. ' +
    'When the user asks for one, call {setup: {name, model, effort, when, instructions}} with what they described; ' +
    'it opens a screen with those fields filled in and nothing is saved until the user presses Save. ' +
    SETUP_HINT,
  )
  const schema = specialistSchema([]) as any
  expect(Object.keys(schema.properties)).toEqual(['setup'])
  expect(Object.keys(schema.properties.setup.properties)).toEqual(['name', 'model', 'effort', 'when', 'instructions'])
})

test('the schema limits specialist to the configured names', () => {
  const schema = specialistSchema([{ name: 'sec', model: 'm', when: 'w' }]) as any
  expect(schema.properties.specialist).toEqual({ type: 'string', enum: ['sec'] })
  expect(schema.properties.finish).toEqual({ type: 'string', enum: ['merge', 'discard'] })
  expect(schema.additionalProperties).toBe(false)
  expect(schema.properties.setup.additionalProperties).toBe(false)
  expect(Object.keys(schema.properties.setup.properties)).toEqual(['name', 'model', 'effort', 'when', 'instructions'])
})

const sec = { name: 'sec', model: 'gpt-6-sol', when: 'auth' }

test('a switched-off specialist is never offered or started; the refusal says where to turn it on', () => {
  const off = { name: 'sec', model: 'gpt-6-sol', when: 'auth', enabled: false as const }
  const mig = { name: 'mig', model: 'gpt-6-luna', when: 'schema' }
  expect(specialistDescription([off, mig])).toContain('Specialists: mig (gpt-6-luna), use when: schema. Switched off by the user, so never offer or start: sec. ')
  expect((specialistSchema([off, mig]) as any).properties.specialist).toEqual({ type: 'string', enum: ['mig'] })
  expect(specialistCall({ specialist: 'sec', task: 't' }, [off, mig])).toEqual({ deny: 'sec is switched off; the user can turn it on in /specialists' })
  expect(specialistDescription([off])).toBe(
    'Set up a specialist: a coding agent that works in its own git worktree with its own model. ' +
    'Every specialist is switched off by the user (sec); never offer or start one, and if one fits, say it can be turned on in /specialists. ' +
    'When the user asks for one, call {setup: {name, model, effort, when, instructions}} with what they described; ' +
    'it opens a screen with those fields filled in and nothing is saved until the user presses Save. ' +
    SETUP_HINT,
  )
  expect(Object.keys((specialistSchema([off]) as any).properties)).toEqual(['setup'])
})
const SHAPES_TEXT = 'give one of {specialist, task}, {run, message}, {run, finish}, {run, result: true} or {setup}'
const SETUP_DENY = 'setup fields must be strings: name, model, effort, when, instructions'
const record: RunRecord = {
  id: 'sec-20260923-151204', specialist: 'sec', model: 'gpt-6-sol', prompt: '',
  repo: '/r/app', worktree: '/r/app.specialists/sec-20260923-151204', branch: 'specialist/sec/20260923-151204',
  base: 'a1b2c3d', thread: '01a0ce2a-1d08-76c0-a6ef-8340b581212d', rounds: 1, state: 'idle', startedMs: 0, roundBase: 'a1b2c3d', subject: 'specialist sec: harden login',
}

test('each call shape is recognised, and nothing else is', () => {
  expect(specialistCall({ specialist: 'sec', task: 'harden login' }, [sec])).toEqual({ kind: 'start', specialist: sec, task: 'harden login' })
  expect(specialistCall({ run: 'sec-1', message: 'fix x.ts:40' }, [sec])).toEqual({ kind: 'followUp', run: 'sec-1', message: 'fix x.ts:40' })
  expect(specialistCall({ run: 'sec-1', finish: 'discard' }, [sec])).toEqual({ kind: 'finish', run: 'sec-1', finish: 'discard' })
  expect(specialistCall({ specialist: 'nope', task: 't' }, [sec])).toEqual({ deny: "no specialist named 'nope'; configured: sec" })
  expect(specialistCall({ specialist: 'sec', task: '  ' }, [sec])).toEqual({ deny: 'task must be a non-empty string' })
  expect(specialistCall({ run: 'sec-1', message: 'm', finish: 'merge' }, [sec])).toEqual({ deny: SHAPES_TEXT })
  expect(specialistCall({ run: 'sec-1', finish: 'keep' }, [sec])).toEqual({ deny: 'finish must be merge or discard' })
  expect(specialistCall({}, [sec])).toEqual({ deny: SHAPES_TEXT })
  expect(specialistCall({ run: 'sec-1', result: true }, [sec])).toEqual({ kind: 'result', run: 'sec-1' })
  expect(specialistCall({ run: 'sec-1', result: true, message: 'm' }, [sec])).toEqual({ deny: SHAPES_TEXT })
  expect(specialistCall({ setup: { name: 'perf', when: 'hot loops', instructions: 'Measure first.' } }, [sec])).toEqual({ kind: 'setup', fields: { name: 'perf', when: 'hot loops', instructions: 'Measure first.' } })
  expect(specialistCall({ setup: {} }, [sec])).toEqual({ kind: 'setup', fields: {} })
  expect(specialistCall({ setup: { name: 3 } }, [sec])).toEqual({ deny: SETUP_DENY })
  expect(specialistCall({ setup: { perspective: 'security' } }, [sec])).toEqual({ deny: SETUP_DENY })
  expect(specialistCall({ setup: 'perf' }, [sec])).toEqual({ deny: SETUP_DENY })
  expect(specialistCall({ setup: {}, run: 'x' }, [sec])).toEqual({ deny: SHAPES_TEXT })
})

test('runStamp is local time, zero padded', () => {
  expect(runStamp(new Date(2026, 8, 3, 7, 5, 9))).toBe('20260903-070509')
})

test('finish questions', () => {
  expect(finishQuestion(record, 'merge', 3, 4, 'main')).toBe('Merge specialist/sec/20260923-151204 (3 commits, 4 files) into main?')
  expect(finishQuestion(record, 'discard', 3, 4, 'main')).toBe('Discard run sec-20260923-151204 and delete its branch?')
})

test('only the go label proceeds; Other text goes back to the model', () => {
  expect(dialogOutcome('Start sec', 'Start sec', "Don't start", 'did not start sec')).toEqual({ go: true })
  expect(dialogOutcome("Don't start", 'Start sec', "Don't start", 'did not start sec')).toEqual({ deny: 'The user did not start sec.' })
  expect(dialogOutcome(undefined, 'Start sec', "Don't start", 'did not start sec')).toEqual({ deny: 'The user was not asked (dialog dismissed or no one to ask), so the user did not start sec.' })
  expect(dialogOutcome('use perf instead', 'Start sec', "Don't start", 'did not start sec')).toEqual({ reply: 'The user did not start sec and said: use perf instead' })
})

test('the prompt puts the instructions first and the ground rules last; without instructions it opens on the task', () => {
  expect(specialistPrompt('Review migrations for locks.', 'add the index')).toBe(
    'Review migrations for locks.\n\nTask:\nadd the index\n\nWork only inside this directory. Run the tests you touch. Do not commit: the tool commits your changes after each round.',
  )
  expect(specialistPrompt('', 'harden login')).toBe(
    'Task:\nharden login\n\nWork only inside this directory. Run the tests you touch. Do not commit: the tool commits your changes after each round.',
  )
  expect(specialistPrompt(' \n', 'harden login')).toBe(
    'Task:\nharden login\n\nWork only inside this directory. Run the tests you touch. Do not commit: the tool commits your changes after each round.',
  )
})

test('a follow-up needs a live run with its worktree', () => {
  expect(followUpRefusal(undefined, 'sec-9', true)).toBe('no run sec-9; start a new one')
  expect(followUpRefusal({ ...record, state: 'finished' }, record.id, true)).toBe(`run ${record.id} is finished; start a new one`)
  expect(followUpRefusal({ ...record, state: 'running' }, record.id, true)).toBe(`sec is still working on run ${record.id}`)
  expect(followUpRefusal(record, record.id, false)).toBe(`run ${record.id} has no worktree any more; start a new one`)
  expect(followUpRefusal({ ...record, thread: '' }, record.id, true)).toBe(`run ${record.id} has no Codex thread to resume; start a new one`)
  expect(followUpRefusal(record, record.id, true)).toBeUndefined()
})

test('report sections stay separate when a section is empty', () => {
  expect(parseSpecialistReport('--- round\n--- total\n src/login.ts | 12 +++\n--- status\n')).toEqual({
    round: '', total: ' src/login.ts | 12 +++', status: '',
  })
  expect(parseSpecialistReport('--- round\n src/login.ts | 12 +++\n--- total\n src/login.ts | 12 +++\n--- status\n M src/login.ts\n')).toEqual({
    round: ' src/login.ts | 12 +++', total: ' src/login.ts | 12 +++', status: ' M src/login.ts',
  })
  expect(parseSpecialistReport('--- round\n src/login.ts | 12 +++\n--- total\n--- status\n M src/login.ts\n')).toEqual({
    round: ' src/login.ts | 12 +++', total: '', status: ' M src/login.ts',
  })
})

test('a round report is read only when it has exactly the schema\'s shape', () => {
  const full = {
    summary: 'Added a rate limit to login.',
    tests: [{ command: 'bun test', result: 'pass', detail: '12 pass' }, { command: 'bats tests/login.bats', result: 'not_run', detail: 'bats is not installed' }],
    open_questions: ['Should the limit be per IP or per account?'],
  }
  expect(parseRoundReport(JSON.stringify(full))).toEqual(full as never)
  expect(parseRoundReport('{"summary":"Nothing to do.","tests":[],"open_questions":[]}')).toEqual({ summary: 'Nothing to do.', tests: [], open_questions: [] })
  expect(parseRoundReport('')).toBeUndefined()
  expect(parseRoundReport('Added a rate limit.')).toBeUndefined()
  expect(parseRoundReport('["summary"]')).toBeUndefined()
  expect(parseRoundReport('null')).toBeUndefined()
  expect(parseRoundReport('{"summary":"x","tests":[]}')).toBeUndefined()
  expect(parseRoundReport('{"summary":1,"tests":[],"open_questions":[]}')).toBeUndefined()
  expect(parseRoundReport('{"summary":"x","tests":[],"open_questions":[3]}')).toBeUndefined()
  expect(parseRoundReport('{"summary":"x","tests":[{"command":"bun test","result":"skipped","detail":""}],"open_questions":[]}')).toBeUndefined()
  expect(parseRoundReport('{"summary":"x","tests":[{"command":"bun test","result":"pass"}],"open_questions":[]}')).toBeUndefined()
  expect(parseRoundReport('{"summary":"x","tests":[],"open_questions":[],"files_changed":[]}')).toBeUndefined()
})

test('a round result carries what Claude needs to review', () => {
  const base = { record, lastMessage: 'Added a rate limit.', roundStat: ' src/login.ts | 12 +++', totalStat: ' src/login.ts | 12 +++', status: '', stderrTail: '', commitError: '' }
  expect(roundResult({ ...base, exitCode: 0, commit: '31db1a2' })).toEqual({
    isError: false,
    result: `Run ${record.id} (sec, round 1) finished.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\n` +
      'The tool committed this round on the branch as 31db1a2.\n\n' +
      `This round:\n src/login.ts | 12 +++\nSince ${record.base}:\n src/login.ts | 12 +++\n\n` +
      "The specialist's own report (written before the tool committed):\n" +
      "It did not match the report schema; its last message as written:\nAdded a rate limit.",
  })
  expect(roundResult({ ...base, exitCode: 0, commit: '' }).result).toContain('The specialist committed this round itself.')
  expect(roundResult({ ...base, exitCode: 0, commit: '', roundStat: '', totalStat: '' }).result).toContain('No changes this round.')
  const failed = roundResult({ ...base, exitCode: 1, commit: '', status: ' M src/login.ts', stderrTail: 'boom' })
  expect(failed.isError).toBe(true)
  expect(failed.result).toContain('Codex exited 1; nothing was committed.')
  expect(failed.result).toContain('Uncommitted in the worktree:\n M src/login.ts')
  expect(failed.result).toContain('Codex stderr (tail):\nboom')
})

test('a schema-shaped report is rendered as summary, tests and open questions', () => {
  const lastMessage = JSON.stringify({
    summary: 'Added a rate limit to login.',
    tests: [{ command: 'bun test', result: 'pass', detail: 'line one\n  line two\r\nline three' }, { command: 'bats tests/login.bats', result: 'not_run', detail: 'bats is not installed' }],
    open_questions: ['first\n\nsecond'],
  })
  const base = { record, lastMessage, roundStat: ' src/login.ts | 12 +++', totalStat: ' src/login.ts | 12 +++', status: '', stderrTail: '', commitError: '', exitCode: 0, commit: '31db1a2' }
  expect(roundResult(base).result).toEndWith(
    "The specialist's own report (written before the tool committed):\n" +
    'Added a rate limit to login.\n\n' +
    'Tests:\n- pass: bun test (line one line two line three)\n- not run: bats tests/login.bats (bats is not installed)\n\n' +
    'Open questions:\n- first second',
  )
  const quiet = JSON.stringify({ summary: 'Renamed a helper.', tests: [{ command: 'bun test', result: 'fail', detail: '' }], open_questions: [] })
  expect(roundResult({ ...base, lastMessage: quiet }).result).toEndWith(
    "The specialist's own report (written before the tool committed):\n" +
    'Renamed a helper.\n\nTests:\n- fail: bun test\n\nOpen questions: none.',
  )
  const untested = JSON.stringify({ summary: 'Renamed a helper.', tests: [], open_questions: [] })
  expect(roundResult({ ...base, lastMessage: untested }).result).toContain('Renamed a helper.\n\nTests: none reported.\n\nOpen questions: none.')
  expect(roundResult({ ...base, lastMessage: '' }).result).toEndWith(
    "The specialist's own report (written before the tool committed):\nThe specialist wrote no report.",
  )
  // A failed round's message may be cut short, so it stays as written.
  expect(roundResult({ ...base, exitCode: 1, commit: '' }).result).toContain(`Specialist's last message:\n${lastMessage}`)
})

test('a round whose commit was refused is an error that names the refusal, not "no changes"', () => {
  const refused = roundResult({
    record, exitCode: 0, commit: '', lastMessage: 'Added a rate limit.', roundStat: '', totalStat: '',
    status: ' M src/login.ts', stderrTail: '', commitError: 'pre-commit: lint failed',
  })
  expect(refused).toEqual({
    isError: true,
    result: `Run ${record.id} (sec, round 1) finished.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\n` +
      `The round's commit failed; the changes are uncommitted in the worktree:\n M src/login.ts\n\ngit said:\npre-commit: lint failed\n\n` +
      "The specialist's own report (written before the tool committed):\n" +
      "It did not match the report schema; its last message as written:\nAdded a rate limit.",
  })
})

test('the thread id is read from the first thread.started event, and only a UUID counts', () => {
  const events = '{"type":"thread.started","thread_id":"01a0ce2a-1d08-76c0-a6ef-8340b581212d"}\n{"type":"turn.started"}\n{"type":"thread.started","thread_id":"99999999-0000-0000-0000-000000000000"}\n'
  expect(threadFrom(events)).toBe('01a0ce2a-1d08-76c0-a6ef-8340b581212d')
  expect(threadFrom('{"type":"turn.started"}\n')).toBe('')
  expect(threadFrom('')).toBe('')
  expect(threadFrom('{"type":"thread.started","thread_id":"--last"}\n')).toBe('')
})

test('the commit subject is the first non-empty line of the task, cut at a word near 72 characters', () => {
  expect(commitSubject('sec', 'harden login\nmore detail')).toBe('specialist sec: harden login')
  expect(commitSubject('sec', '\n\n  harden login  ')).toBe('specialist sec: harden login')
  expect(commitSubject('sec', 'In scripts/specialist.sh, make the start subcommand refuse a name that does not match the pattern')).toBe(
    'specialist sec: In scripts/specialist.sh, make the start subcommand…',
  )
  expect(commitSubject('sec', 'x'.repeat(100))).toBe(`specialist sec: ${'x'.repeat(55)}…`)
})

const WT = '/r/app.specialists/sec-1'
const events = [
  '{"type":"thread.started","thread_id":"01a0ce2a-1d08-76c0-a6ef-8340b581212d"}',
  '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Skill descriptions were shortened"}}',
  '{"type":"item.completed","item":{"id":"item_r","type":"reasoning","text":"**Checking the repo**"}}',
  '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"I\u2019m checking the repo state.\\nThen the tests."}}',
  '{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \\"git status --short\\"","status":"in_progress"}}',
  '{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \\"git status --short\\"","status":"completed","exit_code":0}}',
  '{"type":"item.started","item":{"id":"item_3","type":"file_change","changes":[{"path":"/r/app.specialists/sec-1/tests/a.bats","kind":"update"}],"status":"in_progress"}}',
  '{"type":"item.completed","item":{"id":"item_3","type":"file_change","changes":[{"path":"/r/app.specialists/sec-1/tests/a.bats","kind":"update"}],"status":"completed"}}',
  '{"type":"item.completed","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc \'bats tests/a.bats\'","status":"failed","exit_code":1}}',
  '{"type":"item.completed","item":{"id":"item_7","type":"command_execution","command":"/bin/zsh -lc pwd","status":"completed","exit_code":0}}',
  '{"type":"item.completed","item":{"id":"item_8","type":"command_execution","command":"/bin/zsh -lc ls -la","status":"completed","exit_code":0}}',
  '{"type":"item.started","item":{"id":"item_5","type":"command_execution","command":"/bin/zsh -lc \'bats tests/a.bats\'","status":"in_progress"}}',
  '{"type":"item.started","item":{"id":"item_6","type":"comm',
].join('\n')

test('the event stream becomes one step per item, updated in place, with half-written lines skipped', () => {
  expect(specialistSteps(events, WT)).toEqual([
    { kind: 'think', text: 'Checking the repo', state: 'done' },
    { kind: 'say', text: 'I\u2019m checking the repo state.\nThen the tests.', state: 'done' },
    { kind: 'run', text: 'git status --short', state: 'done' },
    { kind: 'edit', text: 'tests/a.bats', state: 'done' },
    { kind: 'run', text: 'bats tests/a.bats', state: 'failed' },
    { kind: 'run', text: 'pwd', state: 'done' },
    { kind: 'run', text: '/bin/zsh -lc ls -la', state: 'done' },
    { kind: 'run', text: 'bats tests/a.bats', state: 'running' },
  ])
  expect(specialistSteps('', WT)).toEqual([])
})

test('the closing report shows in the steps as its summary and open questions, not as JSON', () => {
  const said = (report: object) => specialistSteps(JSON.stringify({ type: 'item.completed', item: { id: 'item_9', type: 'agent_message', text: JSON.stringify(report) } }), WT)
  expect(said({ summary: 'Added a rate limit.', tests: [{ command: 'bun test', result: 'pass', detail: '' }], open_questions: [] })).toEqual([
    { kind: 'say', text: 'Added a rate limit.', state: 'done' },
  ])
  expect(said({ summary: 'Added a rate limit.', tests: [], open_questions: ['Per IP or per account?', 'Which window?'] })).toEqual([
    { kind: 'say', text: 'Added a rate limit.\n\nOpen questions:\n- Per IP or per account?\n- Which window?', state: 'done' },
  ])
})

test('the band shows the latest step in one short line', () => {
  const steps = specialistSteps(events, WT)
  expect(latestStep(steps)).toBe('$ bats tests/a.bats')
  expect(latestStep(steps.slice(0, 1))).toBe('Checking the repo')
  expect(latestStep(steps.slice(0, 2))).toBe('I\u2019m checking the repo state.')
  expect(latestStep(steps.slice(0, 4))).toBe('\u270e tests/a.bats')
  expect(latestStep([{ kind: 'run', text: 'x'.repeat(80), state: 'running' }])).toBe(`$ ${'x'.repeat(59)}…`)
  expect(latestStep([])).toBe('')
})

test('a round is running while its process lives and has written no exit code', () => {
  expect(roundLiveness('', 'same')).toBe('running')
  expect(roundLiveness('', 'unknown')).toBe('running')
  expect(roundLiveness('', 'gone')).toBe('lost')
  expect(roundLiveness('0\n', 'gone')).toBe('ended')
  expect(roundLiveness('1', 'unknown')).toBe('ended')
})

test('a round belongs only to the process whose start time was recorded', () => {
  const started = 'Wed Sep 24 12:34:56 2026'
  expect(roundProcessIdentity(`${started}\n`, `  ${started}\n`, 'present')).toBe('same')
  expect(roundProcessIdentity(started, 'Wed Sep 24 12:35:01 2026', 'present')).toBe('gone')
  expect(roundProcessIdentity(started, undefined, 'absent')).toBe('gone')
  expect(roundProcessIdentity(started, undefined, 'present')).toBe('unknown')
  expect(roundProcessIdentity(started, ' ', 'present')).toBe('unknown')
  expect(roundProcessIdentity('', started, 'present')).toBe('unknown')
  expect(roundProcessIdentity(started, 'unreadable output', 'present')).toBe('unknown')
  expect(roundProcessIdentity(started, started, 'unknown')).toBe('unknown')
  expect(roundProcessIdentity('Wed Sep 24  12:34:56 2026', started, 'present')).toBe('same')
  expect(roundProcessIdentity(undefined, undefined, 'present')).toBe('same')
  expect(roundProcessIdentity(undefined, undefined, 'absent')).toBe('gone')
  expect(roundProcessIdentity(undefined, undefined, 'unknown')).toBe('unknown')
})

test('kill result distinguishes a missing or reused pid from a failed check', () => {
  expect(roundProcessPresence(0, '')).toBe('present')
  expect(roundProcessPresence(1, 'kill: 99999: No such process')).toBe('absent')
  expect(roundProcessPresence(1, 'kill: 1: Operation not permitted')).toBe('absent')
  expect(roundProcessPresence(1, 'kill: unexpected failure')).toBe('unknown')
})

test('the wake prompt names the run and how to fetch it, and carries none of the specialist\'s text', () => {
  expect(specialistWake(record)).toBe(
    'Specialist sec finished round 1 of run sec-20260923-151204. Fetch its result with mcp__claude-council__specialist {"run": "sec-20260923-151204", "result": true}, review it, and ask the user before any follow-up or finish.',
  )
})

test('a start or follow-up returns at once with where to look', () => {
  expect(startedReply(record)).toBe(
    'Run sec-20260923-151204 (sec, round 1) started in the background.\nBranch: specialist/sec/20260923-151204\nWorktree: /r/app.specialists/sec-20260923-151204\n\n' +
    'A prompt arrives when the round ends; the band above the prompt shows its progress. Do not poll for it.',
  )
  // A start from a dirty tree says what the worktree lacks, so Claude can tell the user.
  expect(startedReply(record, true)).toBe(
    'Run sec-20260923-151204 (sec, round 1) started in the background.\nBranch: specialist/sec/20260923-151204\nWorktree: /r/app.specialists/sec-20260923-151204\n' +
    'Your uncommitted changes are not in its worktree.\n\n' +
    'A prompt arrives when the round ends; the band above the prompt shows its progress. Do not poll for it.',
  )
})

test('a round whose process vanished without an exit code is reported as stopped', () => {
  expect(lostResult(record, ' M src/login.ts')).toEqual({
    isError: true,
    result: `Run ${record.id} (sec, round 1) stopped before it finished: its process is gone and left no exit code.\nBranch: ${record.branch}\nWorktree: ${record.worktree}\n\nUncommitted in the worktree:\n M src/login.ts`,
  })
})

test('the working line turns with each frame and counts the round\'s time', () => {
  expect(workingLine(0, 0, 102_000)).toBe('\u280b working  1:42')
  expect(workingLine(2, 0, 102_000)).toBe('\u2839 working  1:42')
  // Ten frames make one turn.
  expect(workingLine(12, 1_000, 4_000)).toBe('\u2839 working  0:03')
})

test('a move of the person\'s that lands on the last rows resumes following', () => {
  const person = { kind: 'person' } as const
  expect(landsAtEnd({ offset: 30, bodyRows: 20, contentRows: 50, origin: person })).toBe(true)
  expect(landsAtEnd({ offset: 29, bodyRows: 20, contentRows: 50, origin: person })).toBe(false)
  // A tree that fits has nowhere to scroll: its end always shows.
  expect(landsAtEnd({ offset: 0, bodyRows: 20, contentRows: 12, origin: person })).toBe(true)
  // The mod's own scroll to the end must not ask for another.
  expect(landsAtEnd({ offset: 30, bodyRows: 20, contentRows: 50, origin: { kind: 'plugin', name: 'claude-council' } })).toBe(false)
})

test('roundClock counts m:ss, and h:mm:ss past an hour', () => {
  expect(roundClock(0, 49_900)).toBe('0:49')
  expect(roundClock(1_000, 193_000)).toBe('3:12')
  expect(roundClock(0, 3_725_000)).toBe('1:02:05')
  expect(roundClock(5_000, 1_000)).toBe('0:00')
})

test('roundStatus: running, ended and failed each have their own mark and colour', () => {
  expect(roundStatus(true, undefined, '0:49')).toEqual({ glyph: '●', text: '0:49', color: 'warning' })
  expect(roundStatus(false, { result: 'ok', isError: false }, '3:12')).toEqual({ glyph: '✓', text: 'ended 3:12', color: 'success' })
  expect(roundStatus(false, { result: 'boom', isError: true }, '3:12')).toEqual({ glyph: '✗', text: 'failed 3:12', color: 'error' })
  expect(roundStatus(false, undefined, '3:12')).toEqual({ glyph: '✓', text: 'ended 3:12', color: 'success' })
})

test('use-when and instructions keep to one line, since the form cannot show more', () => {
  const sec = { name: 'sec', model: 'gpt-6-sol', when: 'auth' }
  expect(parseSpecialist({ ...sec, when: 'auth\ncrypto' })).toEqual({ error: 'use-when must be one line' })
  expect(parseSpecialist({ ...sec, instructions: 'one\r\ntwo' })).toEqual({ error: 'instructions must be one line' })
})

test('with no specialists but a run still open, the tool keeps follow-up, result and finish', () => {
  const schema = specialistSchema([], true) as any
  expect(Object.keys(schema.properties)).toEqual(['run', 'message', 'finish', 'result', 'setup'])
  expect(specialistDescription([], true)).toBe(
    'Set up a specialist: a coding agent that works in its own git worktree with its own model. None are set up yet. ' +
    'When the user asks for one, call {setup: {name, model, effort, when, instructions}} with what they described; ' +
    'it opens a screen with those fields filled in and nothing is saved until the user presses Save. ' +
    SETUP_HINT + ' ' +
    'A run started before its specialist was removed still takes {run, message}, {run, result: true} and {run, finish: "merge"|"discard"}; close it only after the user chose.',
  )
  expect(Object.keys((specialistSchema([], false) as any).properties)).toEqual(['setup'])
  expect(specialistCall({ run: 'sec-1', result: true }, [])).toEqual({ kind: 'result', run: 'sec-1' })
})

test('the newest list is the copy in the shared store when there is one, else the one this session loaded', () => {
  const loaded = { specialists: JSON.stringify([{ name: 'sec', model: 'm', when: 'w' }]) }
  const newer = JSON.stringify([{ name: 'sec', model: 'm', when: 'w' }, { name: 'mig', model: 'm', when: 'w' }])
  expect(freshList(loaded, newer)).toEqual({ entries: [{ name: 'sec', model: 'm', when: 'w' }, { name: 'mig', model: 'm', when: 'w' }] })
  expect(freshList(loaded, undefined)).toEqual({ entries: [{ name: 'sec', model: 'm', when: 'w' }] })
  expect(freshList(loaded, 7)).toEqual({ entries: [{ name: 'sec', model: 'm', when: 'w' }] })
  expect(freshList(loaded, 'nope')).toEqual({ entries: [], problem: 'the specialists setting is not JSON: nope' })
})
