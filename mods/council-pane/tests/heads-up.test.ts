// ABOUTME: Tests for the heads-up side-check's pure rules: config, memory, cadence, the runner's result and the band's words
// ABOUTME: Expected values are literals; none is rebuilt from the functions under test
import { test, expect } from 'bun:test'
import { applyAnswer, avoidList, bandView, checkLine, kilobytes, tellClaudeDraft, decide, isRepeat, parseRunResult, pressed, settle, typedPast, EMPTY_MEMORY, FRESH_SESSION, type HeadsUpConfig, mergeMemory, parseConfig, parseMemory, type Memory } from '../hooks/heads-up'
import type { Note, Session } from '../types'

test('a missing file is off with nothing to report', () => {
  expect(parseConfig(undefined)).toEqual({ enabled: false })
})

test('an enabled file takes the defaults: codex, every 6', () => {
  expect(parseConfig('{"enabled": true}')).toEqual({ enabled: true, seats: ['codex'], every: 6 })
  expect(parseConfig('{"enabled": true, "seats": ["gemini", "grok-cli"], "every": 4}')).toEqual({ enabled: true, seats: ['gemini', 'grok-cli'], every: 4 })
})

test('a file that does not hold a usable config is off and says why', () => {
  expect(parseConfig('{"enabled": tru')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json is not valid JSON; heads-up is off' })
  expect(parseConfig('[true]')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json must hold a JSON object; heads-up is off' })
  expect(parseConfig('null')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json must hold a JSON object; heads-up is off' })
  expect(parseConfig('{"enabled": false}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: enabled is not true; heads-up is off' })
  expect(parseConfig('{"enabled": "yes"}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: enabled is not true; heads-up is off' })
  expect(parseConfig('{"enabled": true, "seats": ["../x"]}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seat "../x" is not a plain lowercase word; heads-up is off' })
  expect(parseConfig('{"enabled": true, "seats": [3]}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seat 3 is not a plain lowercase word; heads-up is off' })
  expect(parseConfig('{"enabled": true, "seats": "codex"}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seats must be a non-empty list of seat names; heads-up is off' })
  expect(parseConfig('{"enabled": true, "seats": []}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seats must be a non-empty list of seat names; heads-up is off' })
  expect(parseConfig('{"enabled": true, "every": 1}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: every must be a whole number of at least 2, got 1; heads-up is off' })
  expect(parseConfig('{"enabled": true, "every": 2.5}')).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: every must be a whole number of at least 2, got 2.5; heads-up is off' })
})

test('a stored memory off its shape reads field by field as empty', () => {
  expect(parseMemory(undefined)).toEqual({ seen: [], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(parseMemory('text')).toEqual({ seen: [], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(parseMemory({ seen: ['a', 2], known: ['b'], typedPastInARow: -1, looksToSkip: 1.5 })).toEqual({ seen: [], known: ['b'], typedPastInARow: 0, looksToSkip: 0 })
  expect(parseMemory({ seen: ['a'], known: [], typedPastInARow: 2, looksToSkip: 1, sessions: [] })).toEqual({ seen: ['a'], known: [], typedPastInARow: 2, looksToSkip: 1 })
})

test('merging keeps both sessions topics once, newest last, capped at 50, and our counters', () => {
  const stored: Memory = { seen: ['A', 'b'], known: ['k1'], typedPastInARow: 5, looksToSkip: 5 }
  const ours: Memory = { seen: ['a', 'c'], known: [], typedPastInARow: 1, looksToSkip: 0 }
  expect(mergeMemory(stored, ours)).toEqual({ seen: ['b', 'a', 'c'], known: ['k1'], typedPastInARow: 1, looksToSkip: 0 })
  const many = Array.from({ length: 50 }, (_, i) => `t${i}`)
  const merged = mergeMemory({ ...EMPTY_MEMORY, seen: many }, { ...EMPTY_MEMORY, seen: ['new'] })
  expect(merged.seen.length).toBe(50)
  expect(merged.seen[0]).toBe('t1')
  expect(merged.seen[49]).toBe('new')
})

test('a press resets the backoff and records the topic; knew also marks it known', () => {
  const backedOff: Memory = { seen: [], known: [], typedPastInARow: 2, looksToSkip: 1 }
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'dismiss')).toEqual({ seen: ['Fixture DB empty'], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'learn')).toEqual({ seen: ['Fixture DB empty'], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'knew')).toEqual({ seen: ['Fixture DB empty'], known: ['Fixture DB empty'], typedPastInARow: 0, looksToSkip: 0 })
})

test('typing past a note counts up and skips that many checks', () => {
  const once = applyAnswer(EMPTY_MEMORY, 'x', 'typed-past')
  expect(once).toEqual({ seen: ['x'], known: [], typedPastInARow: 1, looksToSkip: 1 })
  expect(applyAnswer(once, 'y', 'typed-past')).toEqual({ seen: ['x', 'y'], known: [], typedPastInARow: 2, looksToSkip: 2 })
})

test('learn then tell on one note records its topic once, whatever the case', () => {
  const learned = applyAnswer(EMPTY_MEMORY, 'Backfill skipped', 'learn')
  expect(applyAnswer(learned, 'backfill skipped ', 'tell')).toEqual({ seen: ['Backfill skipped'], known: [], typedPastInARow: 0, looksToSkip: 0 })
})

test('the avoid list is every seen and known topic once, one per line', () => {
  expect(avoidList(EMPTY_MEMORY)).toBe('')
  expect(avoidList({ seen: ['a', 'b'], known: ['B', 'c'], typedPastInARow: 0, looksToSkip: 0 })).toBe('a\nb\nc\n')
})

const on: HeadsUpConfig = { enabled: true, seats: ['codex'], every: 6 }
const inTurn = (messageCount: number): Session => ({ ...FRESH_SESSION, turnBase: { turnId: 't1', messageCount } })
const note: Note = { id: 'c1', tag: 'Heads up', topic: 'Backfill never ran', headline: 'The test ran on an empty DB.', detail: 'So the backfill path was skipped.', seat: 'codex', model: 'gpt-6.1-sol', payloadBytes: 12698, elapsedMs: 27400 }

test('a step of a new turn records where the turn starts and does not fire there', () => {
  expect(decide(on, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 0, messageCount: 10 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence', session: inTurn(10) })
  expect(decide(on, inTurn(4), EMPTY_MEMORY, { turnId: 't2', index: 0, messageCount: 22 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence', session: { ...FRESH_SESSION, turnBase: { turnId: 't2', messageCount: 22 } } })
})

test('a check fires at each positive multiple of every messages into the turn', () => {
  expect(decide(on, inTurn(10), EMPTY_MEMORY, { turnId: 't1', index: 2, messageCount: 14 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence', session: inTurn(10) })
  expect(decide(on, inTurn(10), EMPTY_MEMORY, { turnId: 't1', index: 3, messageCount: 16 }, 1000)).toEqual({ kind: 'launch', checkId: 'check-1000', session: inTurn(10) })
  expect(decide(on, inTurn(10), EMPTY_MEMORY, { turnId: 't1', index: 6, messageCount: 22 }, 2000)).toEqual({ kind: 'launch', checkId: 'check-2000', session: inTurn(10) })
  expect(decide({ ...on, every: 4 }, inTurn(10), EMPTY_MEMORY, { turnId: 't1', index: 2, messageCount: 14 }, 3000)).toEqual({ kind: 'launch', checkId: 'check-3000', session: inTurn(10) })
})

test('a cadence point is skipped while off, a note shows, a check runs, or the turn had its note', () => {
  const step = { turnId: 't1', index: 3, messageCount: 16 }
  expect(decide({ enabled: false }, inTurn(10), EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'disabled', session: inTurn(10) })
  const showing: Session = { ...inTurn(10), phase: { kind: 'showing', note, expanded: false } }
  expect(decide(on, showing, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'showing', session: showing })
  const checking: Session = { ...inTurn(10), phase: { kind: 'checking', turnId: 't1', checkId: 'c0', runDir: '/r/c0', startedMs: 1 } }
  expect(decide(on, checking, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'checking', session: checking })
  const offered: Session = { ...inTurn(10), offeredTurn: 't1' }
  expect(decide(on, offered, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'offered-this-turn', session: offered })
})

test('backoff spends one skipped check per cadence point and hands back the memory to write', () => {
  const backedOff = { ...EMPTY_MEMORY, typedPastInARow: 2, looksToSkip: 2 }
  expect(decide(on, inTurn(10), backedOff, { turnId: 't1', index: 3, messageCount: 16 }, 1000)).toEqual({ kind: 'skip', why: 'backoff', session: inTurn(10), memory: { ...EMPTY_MEMORY, typedPastInARow: 2, looksToSkip: 1 } })
  expect(decide(on, inTurn(10), backedOff, { turnId: 't1', index: 2, messageCount: 14 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence', session: inTurn(10) })
})

const codexNone = { seat: 'codex', outcome: 'none', ms: 27400 }

test('a note result reads into the note the band draws, its seat outcomes kept', () => {
  const text = JSON.stringify({ kind: 'note', bytes: 12698, seat: 'codex', model: 'gpt-6.1-sol', ms: 27400, tag: 'Heads up', topic: 'Backfill never ran', headline: 'The test ran on an empty DB.', detail: 'So the backfill path was skipped.', seats: [{ seat: 'codex', outcome: 'note', ms: 27400 }] })
  expect(parseRunResult('c1', text)).toEqual({ kind: 'note', note, seats: [{ seat: 'codex', outcome: 'note', elapsedMs: 27400 }] })
  // A runner that names no model leaves it empty; the band then shows the seat alone.
  expect(parseRunResult('c1', text.replace('"model":"gpt-6.1-sol",', '')).kind).toBe('note')
  // The tag is one of the two the builtin uses; anything else, or none, reads as Heads up.
  const tagged = (tag: string) => parseRunResult('c1', text.replace('"tag":"Heads up"', `"tag":${JSON.stringify(tag)}`))
  expect(tagged('You should know')).toMatchObject({ kind: 'note', note: { tag: 'You should know' } })
  expect(tagged('you should know')).toMatchObject({ kind: 'note', note: { tag: 'You should know' } })
  expect(tagged('Warning')).toMatchObject({ kind: 'note', note: { tag: 'Heads up' } })
  expect(parseRunResult('c1', text.replace('"tag":"Heads up",', ''))).toMatchObject({ kind: 'note', note: { tag: 'Heads up' } })
})

test('none and failed results keep the payload size and each seat with its reason', () => {
  expect(parseRunResult('c1', JSON.stringify({ kind: 'none', bytes: 900, seats: [codexNone] }))).toEqual({ kind: 'none', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'none', elapsedMs: 27400 }] })
  const failed = { kind: 'failed', bytes: 900, seats: [{ seat: 'codex', outcome: 'timeout', ms: 60000 }, { seat: 'gemini', outcome: 'error', ms: 1200, detail: 'exit 1: quota' }] }
  expect(parseRunResult('c1', JSON.stringify(failed))).toEqual({ kind: 'failed', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'timeout', elapsedMs: 60000 }, { seat: 'gemini', outcome: 'error', elapsedMs: 1200, detail: 'exit 1: quota' }] })
})

test('a failure before any seat ran keeps the runner reason', () => {
  const text = JSON.stringify({ kind: 'failed', bytes: 0, detail: 'session-transcript.sh: no transcript for abc', seats: [] })
  expect(parseRunResult('c1', text)).toEqual({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail: 'session-transcript.sh: no transcript for abc' }] })
})

test('a result that does not read is a failure naming the text, never a quiet none', () => {
  const runner = (detail: string) => ({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail }] })
  expect(parseRunResult('c1', '')).toEqual(runner('result.json does not read as a run result: ""'))
  expect(parseRunResult('c1', '{"kind":"maybe","bytes":1,"seats":[]}')).toEqual(runner('result.json does not read as a run result: "{\\"kind\\":\\"maybe\\",\\"bytes\\":1,\\"seats\\":[]}"'))
  expect(parseRunResult('c1', '{"kind":"note","bytes":1,"seat":"codex","ms":5,"topic":"","headline":"h","detail":"","seats":[]}').kind).toBe('failed')
  expect(parseRunResult('c1', '{"kind":"none","bytes":1,"seats":[{"seat":"codex","outcome":"maybe","ms":1}]}').kind).toBe('failed')
  expect(parseRunResult('c1', `{"kind":"none","bytes":1,"seats":[]}${'x'.repeat(300)}`)).toEqual(runner(`result.json does not read as a run result: "{\\"kind\\":\\"none\\",\\"bytes\\":1,\\"seats\\":[]}${'x'.repeat(163)}…"`))
})

test('a headline is cut to one line of 200 characters; topic and detail to theirs', () => {
  const long = { kind: 'note', bytes: 1, seat: 'codex', ms: 1, topic: `  ${'t'.repeat(150)}  `, headline: `First line\n  second ${'h'.repeat(300)}`, detail: 'd'.repeat(700), seats: [] }
  const result = parseRunResult('c1', JSON.stringify(long))
  if (result.kind !== 'note') throw new Error(`expected a note, got ${result.kind}`)
  expect(result.note.headline).toBe(`First line second ${'h'.repeat(181)}…`)
  expect(result.note.headline.length).toBe(200)
  expect(result.note.topic).toBe('t'.repeat(140))
  expect(result.note.detail).toBe('d'.repeat(600))
})

test('a repeat is a topic already seen or known, trimmed and case-folded', () => {
  const m = { ...EMPTY_MEMORY, seen: ['Backfill never ran'], known: ['Port is hardcoded'] }
  expect(isRepeat(m, ' backfill NEVER ran ')).toBe(true)
  expect(isRepeat(m, 'port is hardcoded')).toBe(true)
  expect(isRepeat(m, 'Something else')).toBe(false)
})

const checking: Session = { ...inTurn(10), phase: { kind: 'checking', turnId: 't1', checkId: 'c1', runDir: '/r/c1', startedMs: 1 } }

test('a note shows and stamps the turn its check was launched in, even after that turn ended', () => {
  const later: Session = { ...checking, turnBase: { turnId: 't2', messageCount: 30 } }
  expect(settle(later, EMPTY_MEMORY, { kind: 'note', note, seats: [] })).toEqual({ ...later, offeredTurn: 't1', phase: { kind: 'showing', note, expanded: false } })
})

test('a repeat, a none or a failure settles back to idle with the turn left free', () => {
  const idle: Session = { ...checking, phase: { kind: 'idle' } }
  expect(settle(checking, { ...EMPTY_MEMORY, known: ['backfill never ran'] }, { kind: 'note', note, seats: [] })).toEqual(idle)
  expect(settle(checking, EMPTY_MEMORY, { kind: 'none', payloadBytes: 1, seats: [] })).toEqual(idle)
  expect(settle(checking, EMPTY_MEMORY, { kind: 'failed', payloadBytes: 1, seats: [] })).toEqual(idle)
})

test('a result with no check in flight changes nothing', () => {
  const showing: Session = { ...inTurn(10), phase: { kind: 'showing', note, expanded: false } }
  expect(settle(showing, EMPTY_MEMORY, { kind: 'none', payloadBytes: 1, seats: [] })).toBe(showing)
  expect(settle(FRESH_SESSION, EMPTY_MEMORY, { kind: 'note', note, seats: [] })).toBe(FRESH_SESSION)
})

test('typing past a shown note takes it down; with none shown nothing changes', () => {
  const showing: Session = { ...inTurn(10), offeredTurn: 't1', phase: { kind: 'showing', note, expanded: true } }
  expect(typedPast(showing)).toEqual({ ...inTurn(10), offeredTurn: 't1', phase: { kind: 'idle' } })
  expect(typedPast(checking)).toBe(checking)
})

test('learn expands the note; tell, knew and dismiss close it', () => {
  const showing: Session = { ...inTurn(10), phase: { kind: 'showing', note, expanded: false } }
  expect(pressed(showing, 'learn')).toEqual({ ...showing, phase: { kind: 'showing', note, expanded: true } })
  expect(pressed({ ...showing, phase: { kind: 'showing', note, expanded: true } }, 'tell')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'knew')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'dismiss')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(checking, 'dismiss')).toBe(checking)
})

test('the band draws the headline, the seat, payload and time, and the detail once expanded', () => {
  expect(bandView({ kind: 'idle' })).toBeNull()
  expect(bandView({ kind: 'checking', turnId: 't1', checkId: 'c1', runDir: '/r/c1', startedMs: 1 })).toBeNull()
  expect(bandView({ kind: 'showing', note: { ...note, tag: 'You should know' }, expanded: false })?.tag).toBe('You should know')
  expect(bandView({ kind: 'showing', note, expanded: false })).toEqual({ tag: 'Heads up', headline: 'The test ran on an empty DB.', meta: 'codex · gpt-6.1-sol · 12.4 KB · 27 s', detail: null })
  expect(bandView({ kind: 'showing', note, expanded: true })).toEqual({ tag: 'Heads up', headline: 'The test ran on an empty DB.', meta: 'codex · gpt-6.1-sol · 12.4 KB · 27 s', detail: 'So the backfill path was skipped.' })
  expect(bandView({ kind: 'showing', note: { ...note, model: '' }, expanded: false })?.meta).toBe('codex · 12.4 KB · 27 s')
})

test('every finished check logs one line with its seats, payload and time', () => {
  expect(checkLine({ kind: 'note', note, seats: [] })).toBe('heads-up: codex · note · 12.4 KB · 27 s')
  expect(checkLine({ kind: 'none', payloadBytes: 12698, seats: [{ seat: 'codex', outcome: 'none', elapsedMs: 27400 }] })).toBe('heads-up: codex · none · 12.4 KB · 27 s')
  expect(checkLine({ kind: 'none', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'timeout', elapsedMs: 60000 }, { seat: 'gemini', outcome: 'none', elapsedMs: 3600 }] })).toBe('heads-up: codex, gemini · none · 0.9 KB · 64 s')
  expect(checkLine({ kind: 'failed', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'timeout', elapsedMs: 60000 }, { seat: 'gemini', outcome: 'error', elapsedMs: 1200, detail: 'exit 1: quota' }] }))
    .toBe('heads-up: failed · 0.9 KB · codex timeout after 60 s; gemini error after 1 s: exit 1: quota')
})

test('the tell-Claude draft quotes the note for the person to send, naming the seat', () => {
  expect(tellClaudeDraft(note)).toBe('A side check by codex (not you) raised this: The test ran on an empty DB. So the backfill path was skipped. What do you make of it?')
  expect(tellClaudeDraft({ ...note, detail: '' })).toBe('A side check by codex (not you) raised this: The test ran on an empty DB. What do you make of it?')
})

test('kilobytes reads to one decimal', () => {
  expect(kilobytes(0)).toBe('0.0 KB')
  expect(kilobytes(12698)).toBe('12.4 KB')
  expect(kilobytes(1024)).toBe('1.0 KB')
})
