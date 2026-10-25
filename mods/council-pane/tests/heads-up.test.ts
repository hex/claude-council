// ABOUTME: Tests for the heads-up side-check's pure rules: config, memory, cadence, the runner's result and the band's words
// ABOUTME: Expected values are literals; none is rebuilt from the functions under test
import { test, expect } from 'bun:test'
import { acknowledgePause, pausedLine, storedSession, applyAnswer, avoidList, bandView, tagMark, checkLine, kilobytes, tellClaudeDraft, decide, isRepeat, parseRunResult, pressed, settle, typedPast, EMPTY_MEMORY, FRESH_SESSION, type HeadsUpConfig, mergeMemory, parseConfig, parseMemory, type Memory, EMPTY_COUNTS, parseCounts, bumped, countsLine, pressesLine, headsUpCommand, withEnabled, headsUpStatus, statusText, toastLine, introTail, seatsFromDiscovery, seatOptions, seatFromAnswer, everyFromAnswer, SCOPE, EVERY_LABELS, receiptLine, modelFile, modelOptions, modelFromAnswer, effortOptions, effortFromAnswer, MODEL_QUESTION, EFFORT_QUESTION, SEAT_QUESTION } from '../hooks/heads-up'
import type { Note, Session } from '../types'

test('with the row off, only a file saying enabled true turns it on; it takes the defaults: codex, every 3', () => {
  expect(parseConfig(undefined, false)).toEqual({ enabled: false })
  expect(parseConfig('{"enabled": true}', false)).toEqual({ enabled: true, seat: 'codex', every: 3 })
  expect(parseConfig('{"enabled": true, "seat": "grok-cli", "every": 4}', false)).toEqual({ enabled: true, seat: 'grok-cli', every: 4 })
  expect(parseConfig('{"enabled": true, "model": {"model": "gpt-6.1-sol", "effort": "high"}}', false)).toEqual({ enabled: true, seat: 'codex', every: 3, model: { model: 'gpt-6.1-sol', effort: 'high' } })
  expect(parseConfig('{"enabled": true, "seat": "gemini", "model": {}}', false)).toEqual({ enabled: true, seat: 'gemini', every: 3 })
  expect(parseConfig('{"seat": "gemini"}', false)).toEqual({ enabled: false })
  expect(parseConfig('{"enabled": false}', false)).toEqual({ enabled: false })
})

test('with the row on, it is on unless the file says enabled false; the file still sets the seat and every', () => {
  expect(parseConfig(undefined, true)).toEqual({ enabled: true, seat: 'codex', every: 3 })
  expect(parseConfig('{"seat": "gemini", "every": 5}', true)).toEqual({ enabled: true, seat: 'gemini', every: 5 })
  expect(parseConfig('{"enabled": true, "every": 2}', true)).toEqual({ enabled: true, seat: 'codex', every: 2 })
  expect(parseConfig('{"enabled": false, "seat": "gemini"}', true)).toEqual({ enabled: false })
})

test('a file that does not hold a usable config is off and says why, whatever the row', () => {
  for (const row of [false, true]) {
    expect(parseConfig('{"enabled": tru', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json is not valid JSON; heads-up is off' })
    expect(parseConfig('[true]', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json must hold a JSON object; heads-up is off' })
    expect(parseConfig('null', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json must hold a JSON object; heads-up is off' })
    expect(parseConfig('{"enabled": "yes"}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: enabled must be true or false; heads-up is off' })
    expect(parseConfig('{"enabled": true, "seat": "../x"}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seat "../x" is not a plain lowercase word; heads-up is off' })
    expect(parseConfig('{"enabled": true, "seat": 3}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seat 3 is not a plain lowercase word; heads-up is off' })
    expect(parseConfig('{"enabled": true, "seat": ["codex"]}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seat ["codex"] is not a plain lowercase word; heads-up is off' })
    expect(parseConfig('{"enabled": true, "seats": ["codex", "gemini"]}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: seats is not a key; one seat goes under "seat"; heads-up is off' })
    expect(parseConfig('{"enabled": true, "models": {"codex": {"model": "gpt-6.1-sol"}}}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: models is not a key; the seat\'s pick goes under "model"; heads-up is off' })
    expect(parseConfig('{"enabled": true, "every": 1}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: every must be a whole number of at least 2, got 1; heads-up is off' })
    expect(parseConfig('{"enabled": true, "every": 2.5}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: every must be a whole number of at least 2, got 2.5; heads-up is off' })
    expect(parseConfig('{"enabled": true, "model": "gpt-6.1-sol"}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: model must be an object of {model, effort}; heads-up is off' })
    expect(parseConfig('{"enabled": true, "model": {"effort": "Hi gh"}}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: effort for codex must be lowercase letters, got "Hi gh"; heads-up is off' })
    expect(parseConfig('{"enabled": true, "seat": "gemini", "model": {"model": 3}}', row)).toEqual({ enabled: false, problem: '.claude/council-heads-up.json: model for gemini must be a string, got 3; heads-up is off' })
  }
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

test('a press resets the backoff and records the topic; knew and understood also mark it known', () => {
  const backedOff: Memory = { seen: [], known: [], typedPastInARow: 2, looksToSkip: 1 }
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'dismiss')).toEqual({ seen: ['Fixture DB empty'], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'learn')).toEqual({ seen: ['Fixture DB empty'], known: [], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'knew')).toEqual({ seen: ['Fixture DB empty'], known: ['Fixture DB empty'], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'understood')).toEqual({ seen: ['Fixture DB empty'], known: ['Fixture DB empty'], typedPastInARow: 0, looksToSkip: 0 })
  expect(applyAnswer(backedOff, 'Fixture DB empty', 'turn-off')).toEqual({ seen: ['Fixture DB empty'], known: [], typedPastInARow: 0, looksToSkip: 0 })
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

const on: HeadsUpConfig = { enabled: true, seat: 'codex', every: 3 }
const note: Note = { id: 'c1', tag: 'Heads up', topic: 'Backfill never ran', headline: 'The test ran on an empty DB.', title: 'The backfill path was skipped', points: ['The fixture had no rows, so the backfill loop never ran.', 'Seed one row and rerun the migration test.'], seat: 'codex', model: 'gpt-6.1-sol', payloadBytes: 12698, elapsedMs: 27400 }

test('a check fires at each positive multiple of every requests into a turn, never at its first', () => {
  expect(decide(on, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 0 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence' })
  expect(decide(on, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 2 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence' })
  expect(decide(on, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 3 }, 1000)).toEqual({ kind: 'launch', checkId: 'check-1000' })
  expect(decide(on, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 6 }, 2000)).toEqual({ kind: 'launch', checkId: 'check-2000' })
  expect(decide({ ...on, every: 2 }, FRESH_SESSION, EMPTY_MEMORY, { turnId: 't1', index: 2 }, 3000)).toEqual({ kind: 'launch', checkId: 'check-3000' })
})

test('a cadence point is skipped while off, a note shows, a check runs, or the turn had its note', () => {
  const step = { turnId: 't1', index: 3 }
  expect(decide({ enabled: false }, FRESH_SESSION, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'disabled' })
  const showing: Session = { ...FRESH_SESSION, phase: { kind: 'showing', note, expanded: false } }
  expect(decide(on, showing, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'showing' })
  const checking: Session = { ...FRESH_SESSION, phase: { kind: 'checking', turnId: 't1', checkId: 'c0', runDir: '/r/c0', startedMs: 1 } }
  expect(decide(on, checking, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'checking' })
  const offered: Session = { ...FRESH_SESSION, offeredTurn: 't1' }
  expect(decide(on, offered, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'offered-this-turn' })
})

const OUT_OF_CREDITS = 'Your workspace is out of credits. Add credits to continue.'
const paused: Session = { ...FRESH_SESSION, paused: { seat: 'codex', detail: OUT_OF_CREDITS, acknowledged: false } }

test('a paused session skips every cadence point, dismissed or not; off and off-cadence are still told first', () => {
  const step = { turnId: 't1', index: 3 }
  expect(decide(on, paused, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'paused' })
  expect(decide(on, acknowledgePause(paused), EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'paused' })
  expect(decide({ enabled: false }, paused, EMPTY_MEMORY, step, 1000)).toEqual({ kind: 'skip', why: 'disabled' })
  expect(decide(on, paused, EMPTY_MEMORY, { turnId: 't1', index: 2 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence' })
})

test('a stored session without a pause field reads as not paused, and checks launch from it', () => {
  const stored = { offeredTurn: 't0', phase: { kind: 'idle' } } as const
  expect(storedSession(stored)).toEqual({ offeredTurn: 't0', phase: { kind: 'idle' }, paused: null })
  expect(decide(on, storedSession(stored), EMPTY_MEMORY, { turnId: 't1', index: 3 }, 1000)).toEqual({ kind: 'launch', checkId: 'check-1000' })
  expect(storedSession(paused)).toEqual(paused)
})

test('dismissing the pause row acknowledges it and keeps the pause; with no pause nothing changes', () => {
  expect(acknowledgePause(paused)).toEqual({ ...FRESH_SESSION, paused: { seat: 'codex', detail: OUT_OF_CREDITS, acknowledged: true } })
  expect(acknowledgePause(FRESH_SESSION)).toBe(FRESH_SESSION)
})

test('the pause row names the seat and its own words', () => {
  expect(pausedLine({ seat: 'codex', detail: OUT_OF_CREDITS, acknowledged: false }))
    .toBe('heads-up paused · codex is out of credits · Your workspace is out of credits. Add credits to continue.')
})

test('backoff spends one skipped check per cadence point and hands back the memory to write', () => {
  const backedOff = { ...EMPTY_MEMORY, typedPastInARow: 2, looksToSkip: 2 }
  expect(decide(on, FRESH_SESSION, backedOff, { turnId: 't1', index: 3 }, 1000)).toEqual({ kind: 'skip', why: 'backoff', memory: { ...EMPTY_MEMORY, typedPastInARow: 2, looksToSkip: 1 } })
  expect(decide(on, FRESH_SESSION, backedOff, { turnId: 't1', index: 2 }, 1000)).toEqual({ kind: 'skip', why: 'off-cadence' })
})

const codexNone = { seat: 'codex', outcome: 'none', ms: 27400 }

test('a note result reads into the note the band draws, its seat outcomes kept', () => {
  const text = JSON.stringify({ kind: 'note', bytes: 12698, seat: 'codex', model: 'gpt-6.1-sol', ms: 27400, tag: 'Heads up', topic: 'Backfill never ran', headline: 'The test ran on an empty DB.', title: 'The backfill path was skipped', points: ['The fixture had no rows, so the backfill loop never ran.', 'Seed one row and rerun the migration test.'], seats: [{ seat: 'codex', outcome: 'note', ms: 27400 }] })
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

test('none and failed results keep the payload size and the seat with its reason', () => {
  expect(parseRunResult('c1', JSON.stringify({ kind: 'none', bytes: 900, seats: [codexNone] }))).toEqual({ kind: 'none', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'none', elapsedMs: 27400 }] })
  const failed = { kind: 'failed', bytes: 900, seats: [{ seat: 'gemini', outcome: 'error', ms: 1200, detail: 'exit 1: quota' }] }
  expect(parseRunResult('c1', JSON.stringify(failed))).toEqual({ kind: 'failed', payloadBytes: 900, seats: [{ seat: 'gemini', outcome: 'error', elapsedMs: 1200, detail: 'exit 1: quota' }] })
})

test('a seat out of credits reads as quota, carrying the seat and its words; without them it does not read', () => {
  const text = JSON.stringify({ kind: 'quota', bytes: 900, seats: [{ seat: 'codex', outcome: 'quota', ms: 3100, detail: OUT_OF_CREDITS }] })
  expect(parseRunResult('c1', text)).toEqual({ kind: 'quota', seat: 'codex', detail: OUT_OF_CREDITS, payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'quota', elapsedMs: 3100, detail: OUT_OF_CREDITS }] })
  expect(parseRunResult('c1', JSON.stringify({ kind: 'quota', bytes: 900, seats: [{ seat: 'codex', outcome: 'error', ms: 3100, detail: 'exit 1' }] })).kind).toBe('failed')
  expect(parseRunResult('c1', JSON.stringify({ kind: 'quota', bytes: 900, seats: [{ seat: 'codex', outcome: 'quota', ms: 3100 }] })).kind).toBe('failed')
  expect(checkLine({ kind: 'quota', seat: 'codex', detail: OUT_OF_CREDITS, payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'quota', elapsedMs: 3100, detail: OUT_OF_CREDITS }] }))
    .toBe('heads-up: paused · codex out of credits after 3 s: Your workspace is out of credits. Add credits to continue. · /heads-up on resumes')
})

test('a check the runner skipped keeps its reason and asks for no band', () => {
  const text = JSON.stringify({ kind: 'skipped', bytes: 0, detail: 'digest: nothing in the window to review', seats: [] })
  expect(parseRunResult('c1', text)).toEqual({ kind: 'skipped', detail: 'digest: nothing in the window to review' })
  expect(parseRunResult('c1', JSON.stringify({ kind: 'skipped', bytes: 0, seats: [] })).kind).toBe('failed')
  expect(checkLine({ kind: 'skipped', detail: 'digest: nothing in the window to review' })).toBe('heads-up: skipped · digest: nothing in the window to review')
})

test('a failure before any seat ran keeps the runner reason', () => {
  const text = JSON.stringify({ kind: 'failed', bytes: 0, detail: 'session-transcript.sh: no transcript for abc', seats: [] })
  expect(parseRunResult('c1', text)).toEqual({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail: 'session-transcript.sh: no transcript for abc' }] })
})

test('a result that does not read is a failure naming the text, never a quiet none', () => {
  const runner = (detail: string) => ({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail }] })
  expect(parseRunResult('c1', '')).toEqual(runner('result.json does not read as a run result: ""'))
  expect(parseRunResult('c1', '{"kind":"maybe","bytes":1,"seats":[]}')).toEqual(runner('result.json does not read as a run result: "{\\"kind\\":\\"maybe\\",\\"bytes\\":1,\\"seats\\":[]}"'))
  expect(parseRunResult('c1', '{"kind":"note","bytes":1,"seat":"codex","ms":5,"topic":"","headline":"h","title":"","points":[],"seats":[]}').kind).toBe('failed')
  expect(parseRunResult('c1', '{"kind":"note","bytes":1,"seat":"codex","ms":5,"topic":"t","headline":"h","title":"","points":"one","seats":[]}').kind).toBe('failed')
  expect(parseRunResult('c1', '{"kind":"none","bytes":1,"seats":[{"seat":"codex","outcome":"maybe","ms":1}]}').kind).toBe('failed')
  expect(parseRunResult('c1', `{"kind":"none","bytes":1,"seats":[]}${'x'.repeat(300)}`)).toEqual(runner(`result.json does not read as a run result: "{\\"kind\\":\\"none\\",\\"bytes\\":1,\\"seats\\":[]}${'x'.repeat(163)}…"`))
})

test('a headline is cut to one line of 200 characters; topic, title and points to theirs, blank points dropped, seven points to six', () => {
  const long = { kind: 'note', bytes: 1, seat: 'codex', ms: 1, topic: `  ${'t'.repeat(150)}  `, headline: `First line\n  second ${'h'.repeat(300)}`, title: `  ${'a'.repeat(100)}`, points: ['', ' one ', 'p'.repeat(250), '3', '4', '5', '6', '7'], seats: [] }
  const result = parseRunResult('c1', JSON.stringify(long))
  if (result.kind !== 'note') throw new Error(`expected a note, got ${result.kind}`)
  expect(result.note.headline).toBe(`First line second ${'h'.repeat(181)}…`)
  expect(result.note.headline.length).toBe(200)
  expect(result.note.topic).toBe('t'.repeat(140))
  expect(result.note.title).toBe('a'.repeat(80))
  expect(result.note.points).toEqual(['one', 'p'.repeat(200), '3', '4', '5', '6'])
})

test('a markdown link in a title or point is flattened to its text and address', () => {
  const linked = { kind: 'note', bytes: 1, seat: 'codex', ms: 1, topic: 't', headline: 'h', title: 'See the [advisory](https://example.com/a)', points: ['Read [this](https://example.com/b) and [that](https://example.com/c).'], seats: [] }
  const result = parseRunResult('c1', JSON.stringify(linked))
  if (result.kind !== 'note') throw new Error(`expected a note, got ${result.kind}`)
  expect(result.note.title).toBe('See the advisory (https://example.com/a)')
  expect(result.note.points).toEqual(['Read this (https://example.com/b) and that (https://example.com/c).'])
})

test('a repeat is a topic already seen or known, trimmed and case-folded', () => {
  const m = { ...EMPTY_MEMORY, seen: ['Backfill never ran'], known: ['Port is hardcoded'] }
  expect(isRepeat(m, ' backfill NEVER ran ')).toBe(true)
  expect(isRepeat(m, 'port is hardcoded')).toBe(true)
  expect(isRepeat(m, 'Something else')).toBe(false)
})

const checking: Session = { ...FRESH_SESSION, phase: { kind: 'checking', turnId: 't1', checkId: 'c1', runDir: '/r/c1', startedMs: 1 } }

test('a note shows and stamps the turn its check was launched in', () => {
  expect(settle(checking, EMPTY_MEMORY, { kind: 'note', note, seats: [] })).toEqual({ ...checking, offeredTurn: 't1', phase: { kind: 'showing', note, expanded: false } })
})

test('a repeat, a none or a failure settles back to idle with the turn left free', () => {
  const idle: Session = { ...checking, phase: { kind: 'idle' } }
  expect(settle(checking, { ...EMPTY_MEMORY, known: ['backfill never ran'] }, { kind: 'note', note, seats: [] })).toEqual(idle)
  expect(settle(checking, EMPTY_MEMORY, { kind: 'none', payloadBytes: 1, seats: [] })).toEqual(idle)
  expect(settle(checking, EMPTY_MEMORY, { kind: 'failed', payloadBytes: 1, seats: [] })).toEqual(idle)
  expect(settle(checking, EMPTY_MEMORY, { kind: 'skipped', detail: 'digest: nothing in the window to review' })).toEqual(idle)
})

test('a seat out of credits settles to idle and pauses the session with its seat and words, not yet dismissed', () => {
  expect(settle(checking, EMPTY_MEMORY, { kind: 'quota', seat: 'codex', detail: OUT_OF_CREDITS, payloadBytes: 900, seats: [] }))
    .toEqual({ ...checking, phase: { kind: 'idle' }, paused: { seat: 'codex', detail: OUT_OF_CREDITS, acknowledged: false } })
})

test('a result with no check in flight changes nothing', () => {
  const showing: Session = { ...FRESH_SESSION, phase: { kind: 'showing', note, expanded: false } }
  expect(settle(showing, EMPTY_MEMORY, { kind: 'none', payloadBytes: 1, seats: [] })).toBe(showing)
  expect(settle(FRESH_SESSION, EMPTY_MEMORY, { kind: 'note', note, seats: [] })).toBe(FRESH_SESSION)
})

test('typing past a shown note takes it down; with none shown nothing changes', () => {
  const showing: Session = { ...FRESH_SESSION, offeredTurn: 't1', phase: { kind: 'showing', note, expanded: true } }
  expect(typedPast(showing)).toEqual({ ...FRESH_SESSION, offeredTurn: 't1', phase: { kind: 'idle' } })
  expect(typedPast(checking)).toBe(checking)
})

test('learn expands the note; tell, knew, understood and dismiss close it', () => {
  const showing: Session = { ...FRESH_SESSION, phase: { kind: 'showing', note, expanded: false } }
  expect(pressed(showing, 'learn')).toEqual({ ...showing, phase: { kind: 'showing', note, expanded: true } })
  expect(pressed({ ...showing, phase: { kind: 'showing', note, expanded: true } }, 'tell')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'knew')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'understood')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'turn-off')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(showing, 'dismiss')).toEqual({ ...showing, phase: { kind: 'idle' } })
  expect(pressed(checking, 'dismiss')).toBe(checking)
})

test('the band draws the headline, the seat, payload and time, and the title and points once expanded', () => {
  expect(bandView({ kind: 'idle' })).toBeNull()
  expect(bandView({ kind: 'checking', turnId: 't1', checkId: 'c1', runDir: '/r/c1', startedMs: 1 })).toBeNull()
  expect(bandView({ kind: 'showing', note: { ...note, tag: 'You should know' }, expanded: false })?.tag).toBe('You should know')
  expect(bandView({ kind: 'showing', note, expanded: false })).toEqual({ tag: 'Heads up', headline: 'The test ran on an empty DB.', meta: 'codex · gpt-6.1-sol · 12.4 KB · 27 s', more: null, id: note.id })
  expect(bandView({ kind: 'showing', note, expanded: true })).toEqual({ tag: 'Heads up', headline: 'The test ran on an empty DB.', meta: 'codex · gpt-6.1-sol · 12.4 KB · 27 s', more: { title: 'The backfill path was skipped', points: ['The fixture had no rows, so the backfill loop never ran.', 'Seed one row and rerun the migration test.'] }, id: note.id })
  expect(bandView({ kind: 'showing', note: { ...note, model: '' }, expanded: false })?.meta).toBe('codex · 12.4 KB · 27 s')
})

test('every finished check logs one line with its seat, payload and time', () => {
  expect(checkLine({ kind: 'note', note, seats: [] })).toBe('heads-up: codex · note · 12.4 KB · 27 s')
  expect(checkLine({ kind: 'none', payloadBytes: 12698, seats: [{ seat: 'codex', outcome: 'none', elapsedMs: 27400 }] })).toBe('heads-up: codex · none · 12.4 KB · 27 s')
  expect(checkLine({ kind: 'failed', payloadBytes: 900, seats: [{ seat: 'codex', outcome: 'timeout', elapsedMs: 60000 }] })).toBe('heads-up: failed · 0.9 KB · codex timeout after 60 s')
  expect(checkLine({ kind: 'failed', payloadBytes: 0, seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail: 'transcript: no transcript for abc' }, { seat: 'gemini', outcome: 'error', elapsedMs: 1200, detail: 'exit 1: quota' }] }))
    .toBe('heads-up: failed · 0.0 KB · runner error after 0 s: transcript: no transcript for abc; gemini error after 1 s: exit 1: quota')
})

test('the tell-Claude draft quotes the note as a list and asks for a check before action, naming the seat', () => {
  expect(tellClaudeDraft(note)).toBe([
    'A side check by codex (not you) flagged this: The test ran on an empty DB.',
    'The backfill path was skipped\n- The fixture had no rows, so the backfill loop never ran.\n- Seed one row and rerun the migration test.',
    'Treat this as a claim, not a conclusion. Before continuing: verify it against the evidence, report what you find, and only then act on the last bullet.',
  ].join('\n\n'))
  expect(tellClaudeDraft({ ...note, title: '', points: [] })).toBe('A side check by codex (not you) flagged this: The test ran on an empty DB.\n\nTreat this as a claim, not a conclusion. Before continuing: verify it against the evidence, report what you find, and only then act on it.')
  expect(tellClaudeDraft({ ...note, tag: 'You should know', title: '', points: ['Quote the value.'] })).toBe('A side check by codex (not you) flagged this: The test ran on an empty DB.\n\n- Quote the value.\n\nTake this into account before continuing and say whether it changes your plan.')
})

test('the band badge is ! for a Heads up and ? for a You should know', () => {
  expect(tagMark('Heads up')).toBe('!')
  expect(tagMark('You should know')).toBe('?')
})

test('kilobytes reads to one decimal', () => {
  expect(kilobytes(0)).toBe('0.0 KB')
  expect(kilobytes(12698)).toBe('12.4 KB')
  expect(kilobytes(1024)).toBe('1.0 KB')
})

test('stored counts read field by field as zero; any other key is dropped', () => {
  expect(parseCounts(undefined)).toEqual(EMPTY_COUNTS)
  expect(parseCounts({ checks: 3, none: 2, notes: 1, quota: 5, learn: -1, tell: 'x', extra: 9 })).toEqual({ ...EMPTY_COUNTS, none: 2, notes: 1, quota: 5 })
})

test('a bump adds one to its count and leaves the rest', () => {
  expect(bumped(EMPTY_COUNTS, 'none')).toEqual({ ...EMPTY_COUNTS, none: 1 })
  expect(bumped(EMPTY_COUNTS, 'none', 'learn')).toEqual({ ...EMPTY_COUNTS, none: 1, learn: 1 })
  expect(bumped(bumped(EMPTY_COUNTS, 'typedPast'), 'typedPast').typedPast).toBe(2)
})

test('the counts line names every count in a fixed order', () => {
  expect(countsLine(EMPTY_COUNTS)).toBe('checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0')
  const full = { none: 8, notes: 2, repeats: 1, failed: 1, quota: 4, learn: 2, tell: 1, knew: 0, understood: 1, dismiss: 1, turnOff: 1, typedPast: 3 }
  expect(countsLine(full)).toBe('checks 16 · none 8 · notes 2 · repeats 1 · failed 1 · out of credits 4')
  expect(pressesLine(full)).toBe('learn 2 · tell 1 · knew 0 · understood 1 · dismiss 1 · turned off 1 · typed past 3')
})

test('the heads-up command reads on with an optional seat, off and status, and refuses anything else', () => {
  expect(headsUpCommand('')).toEqual({ action: 'status' })
  expect(headsUpCommand(' Status ')).toEqual({ action: 'status' })
  expect(headsUpCommand('on')).toEqual({ action: 'on' })
  expect(headsUpCommand('ON grok-cli')).toEqual({ action: 'on', seat: 'grok-cli' })
  expect(headsUpCommand('on Gemini')).toEqual({ action: 'on', seat: 'gemini' })
  expect(headsUpCommand('on gemini grok-cli')).toEqual({ action: 'unknown', why: 'on takes one seat, got 2: gemini, grok-cli' })
  expect(headsUpCommand('on gemini,grok-cli')).toEqual({ action: 'unknown', why: 'on takes one seat, got 2: gemini, grok-cli' })
  expect(headsUpCommand('on ../x')).toEqual({ action: 'unknown', why: 'seat "../x" is not a plain lowercase word' })
  expect(headsUpCommand('OFF')).toEqual({ action: 'off' })
  expect(headsUpCommand('off gemini')).toEqual({ action: 'unknown', why: 'off takes no words' })
  expect(headsUpCommand('maybe')).toEqual({ action: 'unknown', why: 'unknown word "maybe"' })
  expect(headsUpCommand('setup')).toEqual({ action: 'setup' })
  expect(headsUpCommand('setup now')).toEqual({ action: 'unknown', why: 'setup takes no words' })
})

test('switching the project file keeps its seat and every, takes a new seat when given, and starts a fresh file when there is none or it is broken', () => {
  expect(withEnabled(undefined, true)).toBe('{"enabled": true}\n')
  expect(withEnabled(undefined, false)).toBe('{"enabled": false}\n')
  expect(withEnabled('{"enabled": true, "seat": "gemini", "every": 5}', false)).toBe('{"enabled": false, "seat": "gemini", "every": 5}\n')
  expect(withEnabled('{"seat": "gemini"}', true)).toBe('{"enabled": true, "seat": "gemini"}\n')
  expect(withEnabled('{"seat": "gemini", "every": 5}', true, 'grok-cli')).toBe('{"enabled": true, "seat": "grok-cli", "every": 5}\n')
  expect(withEnabled(undefined, true, 'gemini')).toBe('{"enabled": true, "seat": "gemini"}\n')
  expect(withEnabled('{"enabled": tru', true)).toBe('{"enabled": true}\n')
  expect(withEnabled('[1]', true)).toBe('{"enabled": true}\n')
  expect(withEnabled('{"every": 5}', true, 'gemini', 9)).toBe('{"enabled": true, "every": 9, "seat": "gemini"}\n')
  expect(withEnabled(undefined, undefined, 'gemini', 3)).toBe('{"seat": "gemini", "every": 3}\n')
  expect(withEnabled('{"model": {}}', false)).toBe('{"enabled": false}\n')
  expect(withEnabled('{"enabled": true, "seats": ["codex", "gemini"], "models": {"codex": {"model": "x"}}, "every": 3}', true, 'codex')).toBe('{"enabled": true, "every": 3, "seat": "codex"}\n')
  expect(withEnabled('{"seat": "gemini", "model": {"model": "old"}}', true, 'codex', 3, {})).toBe('{"enabled": true, "seat": "codex", "every": 3}\n')
  expect(withEnabled('{"model": {"model": "old"}}', true, 'codex', 3, { model: 'gpt-6.1-sol', effort: 'high' })).toBe('{"enabled": true, "model": {"model": "gpt-6.1-sol", "effort": "high"}, "seat": "codex", "every": 3}\n')
})

test('a pick belongs to its seat: naming another seat drops it, naming the same one keeps it', () => {
  expect(withEnabled('{"enabled": true, "model": {"model": "gpt-6.1-sol", "effort": "high"}}', true, 'gemini')).toBe('{"enabled": true, "seat": "gemini"}\n')
  expect(withEnabled('{"seat": "gemini", "model": {"model": "gemini-2.5-pro"}}', true, 'grok-cli')).toBe('{"enabled": true, "seat": "grok-cli"}\n')
  expect(withEnabled('{"model": {"model": "gpt-6.1-sol"}}', true, 'codex')).toBe('{"enabled": true, "model": {"model": "gpt-6.1-sol"}, "seat": "codex"}\n')
  expect(withEnabled('{"seat": "gemini", "model": {"model": "gemini-2.5-pro"}}', false)).toBe('{"enabled": false, "seat": "gemini", "model": {"model": "gemini-2.5-pro"}}\n')
})

test('the toast is the status on one line: state, seat, cadence and the checks, without the presses', () => {
  const counts = { ...EMPTY_COUNTS, none: 3, notes: 1, learn: 1 }
  expect(toastLine(headsUpStatus({ enabled: true, seat: 'codex', every: 3 }, false, '{"enabled": true}', counts, null)))
    .toBe('Heads-up side-check: on for this project · codex · every 3 requests · checks 4 · none 3 · notes 1 · repeats 0 · failed 0 · out of credits 0')
  expect(toastLine(headsUpStatus({ enabled: false, seat: 'codex', every: 3 }, false, undefined, EMPTY_COUNTS, null)))
    .toBe('Heads-up side-check: off · checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0')
  expect(toastLine(headsUpStatus({ enabled: true, seat: 'codex', every: 3 }, false, '{"enabled": true}', { ...EMPTY_COUNTS, quota: 1 }, paused.paused)))
    .toBe('Heads-up side-check: on for this project · codex · every 3 requests · codex out of credits this session · /heads-up on to resume · checks 1 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 1')
})

test('status names the effective state and which switch set it, then the counts, one aligned row per fact', () => {
  const counts = { ...EMPTY_COUNTS, none: 3, notes: 1, learn: 1 }
  expect(statusText(headsUpStatus({ enabled: true, seat: 'codex', every: 3 }, false, '{"enabled": true}', counts, null))).toBe(
    'Heads-up side-check: on for this project\n'
    + '  by       .claude/council-heads-up.json (the /config row is off)\n'
    + '  seat     codex\n'
    + '  every    3 requests\n'
    + '  checks   checks 4 · none 3 · notes 1 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 1 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
  expect(statusText(headsUpStatus({ enabled: true, seat: 'codex', every: 3, model: { model: 'gpt-6.1-sol', effort: 'high' } }, true, undefined, EMPTY_COUNTS, null))).toBe(
    'Heads-up side-check: on for every project\n'
    + '  by       the /config row (no .claude/council-heads-up.json here)\n'
    + '  seat     codex (gpt-6.1-sol, high)\n'
    + '  every    3 requests\n'
    + '  checks   checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
  expect(statusText(headsUpStatus({ enabled: false }, true, '{"enabled": false}', EMPTY_COUNTS, null))).toBe(
    'Heads-up side-check: off for this project\n'
    + '  by       .claude/council-heads-up.json (the /config row is on)\n'
    + '  turn on  /heads-up on [seat] turns it on here\n'
    + '  checks   checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
  expect(statusText(headsUpStatus({ enabled: false }, false, undefined, EMPTY_COUNTS, null))).toBe(
    'Heads-up side-check: off\n'
    + '  by       the /config row is off, no .claude/council-heads-up.json here\n'
    + '  turn on  /heads-up on [seat] for this project, the /config row "Heads-up side-check" for every project\n'
    + '  checks   checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
  expect(statusText(headsUpStatus({ enabled: false, problem: '.claude/council-heads-up.json is not valid JSON; heads-up is off' }, true, '{', EMPTY_COUNTS, null))).toBe(
    'Heads-up side-check: off\n'
    + '  problem  .claude/council-heads-up.json is not valid JSON; heads-up is off\n'
    + '  checks   checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
})

test('status says while the session is paused, dismissed or not, and what resumes it; off for the project it still says so', () => {
  const counts = { ...EMPTY_COUNTS, none: 1305, notes: 56, failed: 29, quota: 331 }
  expect(statusText(headsUpStatus({ enabled: true, seat: 'codex', every: 3 }, false, '{"enabled": true}', counts, paused.paused))).toBe(
    'Heads-up side-check: on for this project\n'
    + '  by       .claude/council-heads-up.json (the /config row is off)\n'
    + '  seat     codex\n'
    + '  every    3 requests\n'
    + '  paused   codex out of credits this session · /heads-up on to resume\n'
    + '  checks   checks 1721 · none 1305 · notes 56 · repeats 0 · failed 29 · out of credits 331\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
  expect(statusText(headsUpStatus({ enabled: false }, false, '{"enabled": false}', EMPTY_COUNTS, acknowledgePause(paused).paused))).toBe(
    'Heads-up side-check: off for this project\n'
    + '  by       .claude/council-heads-up.json (the /config row is off)\n'
    + '  turn on  /heads-up on [seat] turns it on here\n'
    + '  paused   codex out of credits this session · /heads-up on to resume\n'
    + '  checks   checks 0 · none 0 · notes 0 · repeats 0 · failed 0 · out of credits 0\n'
    + '  presses  learn 0 · tell 0 · knew 0 · understood 0 · dismiss 0 · turned off 0 · typed past 0')
})

test('the one-time intro is a tail on the prompt hint, once per install, only while the check is off', () => {
  expect(introTail({ shown: false, enabled: false })).toEqual({ tail: 'Tip: /heads-up on lets another model watch long turns and flag what Claude missed', markShown: true })
  expect(introTail({ shown: false, enabled: true })).toEqual({ markShown: true })
  expect(introTail({ shown: true, enabled: false })).toEqual({ markShown: false })
})

test('the seats on offer are what the council discovers, codex first and the router as one seat', () => {
  expect(seatsFromDiscovery('antigravity codex gemini openrouter-1 openrouter-2 perplexity\n')).toEqual(['codex', 'antigravity', 'gemini', 'openrouter', 'perplexity'])
  expect(seatsFromDiscovery('antigravity grok-cli\n')).toEqual(['antigravity', 'grok-cli'])
  expect(seatsFromDiscovery('\n')).toEqual([])
})

test('the dialog asks for one seat of at most four, and the answer reads back as one checked seat', () => {
  expect(SEAT_QUESTION).toBe('Which seat should reread the turn?')
  expect(seatOptions(['codex', 'grok-cli', 'ollama', 'gemini', 'grok'])).toEqual(['codex', 'grok-cli', 'ollama', 'gemini'])
  expect(seatOptions([])).toEqual(['codex', 'gemini'])
  expect(seatFromAnswer('gemini')).toEqual({ seat: 'gemini' })
  expect(seatFromAnswer(' Grok-CLI ')).toEqual({ seat: 'grok-cli' })
  expect(seatFromAnswer('codex, gemini')).toEqual({ why: 'one seat, got 2: codex, gemini' })
  expect(seatFromAnswer('')).toEqual({ why: 'no seat named' })
  expect(seatFromAnswer('../x')).toEqual({ why: 'seat "../x" is not a plain lowercase word' })
})

test('the cadence answer is one of the three labels or a typed whole number of at least 2', () => {
  expect(EVERY_LABELS).toEqual(['Every 3 requests', 'Every 6 requests', 'Every 9 requests'])
  expect(everyFromAnswer('Every 6 requests')).toEqual({ every: 6 })
  expect(everyFromAnswer('12')).toEqual({ every: 12 })
  expect(everyFromAnswer('every 4')).toEqual({ every: 4 })
  expect(everyFromAnswer('1')).toEqual({ why: 'every must be a whole number of at least 2, got "1"' })
  expect(everyFromAnswer('lots')).toEqual({ why: 'every must be a whole number of at least 2, got "lots"' })
})

test('the scope labels name the three outcomes', () => {
  expect(SCOPE).toEqual({ project: 'This project', all: 'Every project', off: 'Off for this project' })
})

test('a check that found nothing leaves a receipt for the prompt hint', () => {
  expect(receiptLine({ kind: 'none', payloadBytes: 8500, seats: [{ seat: 'gemini', outcome: 'none', elapsedMs: 11200 }] })).toBe('heads-up: gemini read 8.3 KB in 11 s, nothing to flag')
})

test('the model file for the runner holds the seat\'s pick, and is empty when nothing was picked', () => {
  expect(modelFile({ enabled: true, seat: 'gemini', every: 3 })).toBe('')
  expect(modelFile({ enabled: true, seat: 'codex', every: 3, model: { model: 'gpt-6.1-sol', effort: 'high' } })).toBe('{"model":"gpt-6.1-sol","effort":"high"}')
})

test('the model dialog offers the current model first, then the catalog, four in all; without a catalog it says to type one', () => {
  expect(MODEL_QUESTION('gemini')).toBe('Which model should gemini use?')
  expect(modelOptions('gemini-flash-latest', undefined)).toEqual(['Keep gemini-flash-latest', 'Type a model id under Other'])
  expect(modelOptions('gpt-6.1-sol', ['gpt-6.1-sol', 'gpt-6-luna', 'gpt-6-mini', 'gpt-5', 'gpt-4'])).toEqual(['Keep gpt-6.1-sol', 'gpt-6-luna', 'gpt-6-mini', 'gpt-5'])
  expect(modelFromAnswer('Keep gpt-6.1-sol')).toBeUndefined()
  expect(modelFromAnswer('Type a model id under Other')).toBeUndefined()
  expect(modelFromAnswer('gpt-6-luna')).toBe('gpt-6-luna')
  expect(modelFromAnswer('  ')).toBeUndefined()
})

test('the effort dialog offers the default first, four in all, and reads back lowercase letters', () => {
  expect(EFFORT_QUESTION).toBe('How hard should codex think?')
  expect(effortOptions(['low', 'medium', 'high', 'xhigh', 'max'], 'medium')).toEqual(['medium (default)', 'low', 'high', 'xhigh'])
  expect(effortOptions([], '')).toEqual(['low', 'medium', 'high', 'xhigh'])
  expect(effortFromAnswer('medium (default)')).toEqual({})
  expect(effortFromAnswer('high')).toEqual({ effort: 'high' })
  expect(effortFromAnswer('Hi gh')).toEqual({ why: 'effort must be lowercase letters, got "Hi gh"' })
})
