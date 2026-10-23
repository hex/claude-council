// ABOUTME: Tests for choosing which council run the pane shows and the markdown it draws
// ABOUTME: Expected strings are written out by hand, never rebuilt from the code under test
import { test, expect } from 'bun:test'
import { unseenRun, paneSections, parseColors, markdownBlocks, queryingSince, withinTextBudget, seatsToCancel, seatFolds } from '../hooks/view'

test('unseenRun names the first run dir not shown before, ignoring other entries', () => {
  const entries = [
    { name: '.keep', kind: 'file' },
    { name: 'run.aaa111', kind: 'dir' },
    { name: 'run.bbb222', kind: 'dir' },
    { name: 'run.notes', kind: 'file' },
  ]
  expect(unseenRun(entries, new Set(['run.aaa111']))).toBe('run.bbb222')
  expect(unseenRun(entries, new Set(['run.aaa111', 'run.bbb222']))).toBeUndefined()
})

test('paneSections gives one row per seat, its answer or its error text under it, then the footer', () => {
  const sections = paneSections({
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210, model: 'gemini-3-pro' },
      { name: 'openai', state: 'querying' },
      { name: 'grok', state: 'error', ms: 900 },
    ],
    responses: { gemini: 'Use Postgres.' },
    errors: { grok: 'HTTP 429' },
    colors: { gemini: '59;130;246', grok: '239;68;68' },
    isDone: false,
  })
  expect(sections).toEqual([
    { kind: 'seat', key: 'jump:gemini', fold: 'seat:jump:gemini', digit: '1', glyph: '✓', glyphColor: 'success', vendor: 'rgb(59,130,246)', name: 'gemini', model: 'gemini-3-pro', note: '', time: '4.2s', open: true, action: { press: 'fold', seat: 'gemini' } },
    { kind: 'body', text: 'Use Postgres.' },
    { kind: 'seat', key: 'jump:openai', fold: 'seat:jump:openai', digit: '2', glyph: '●', glyphColor: 'warning', vendor: 'rgb(113,113,122)', name: 'openai', model: '', note: '', time: '    ', open: false, action: { press: 'cancel', seat: 'openai' } },
    { kind: 'seat', key: 'jump:grok', fold: 'seat:jump:grok', digit: '3', glyph: '✗', glyphColor: 'error', vendor: 'rgb(239,68,68)', name: 'grok  ', model: '', note: '', time: '0.9s', open: true, action: { press: 'fold', seat: 'grok' } },
    { kind: 'body', text: 'HTTP 429' },
    { kind: 'footer', keys: [{ hotkey: 'a', label: 'fold' }, { hotkey: 'c', label: 'cancel all' }, { hotkey: '✕', label: 'close' }] },
  ])
})

test('the glyph and its colour carry the state, and only a cached or fell-back seat says so in words', () => {
  const states = ['querying', 'complete', 'cached', 'fallback', 'error', 'cancelled']
  const sections = paneSections({
    providers: states.map(state => ({ name: state, state })),
    responses: {}, errors: {}, colors: {}, isDone: false,
  })
  const looks = sections.flatMap(section => (section.kind === 'seat' ? [[section.glyph, section.glyphColor, section.note]] : []))
  expect(looks).toEqual([
    ['●', 'warning', ''],
    ['✓', 'success', ''],
    ['✓', 'suggestion', 'cached'],
    ['✓', 'warning', 'fell back'],
    ['✗', 'error', ''],
    ['○', 'inactive', ''],
  ])
})

const action = (sections: ReturnType<typeof paneSections>) => sections.flatMap(section => (section.kind === 'seat' ? [section.action?.press ?? 'none'] : []))

test('a seat row\'s action is cancel while it queries, retry on an offered error, open or fold over its text, else none', () => {
  const view = {
    providers: [
      { name: 'codex', state: 'querying' },
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'grok-cli', state: 'error', ms: 900 },
      { name: 'kimi', state: 'error', ms: 300 },
      { name: 'openai', state: 'querying' },
    ],
    responses: { gemini: 'Use Postgres.' }, errors: { 'grok-cli': 'HTTP 429', kimi: 'HTTP 500' }, colors: {},
    cancels: ['openai'],
    retriable: ['grok-cli'],
    isDone: false,
  }
  // openai's cancel is pressed: it draws as cancelling, its digit with no verb.
  expect(action(paneSections(view))).toEqual(['cancel', 'fold', 'retry', 'fold', 'none'])
  expect(paneSections(view).find(section => section.kind === 'seat' && section.name.trim() === 'openai')).toMatchObject({ glyph: '○', glyphColor: 'inactive', digit: '5', open: false })
  expect(action(paneSections(view, { closed: new Set(['seat:jump:gemini', 'seat:jump:kimi']) }))).toEqual(['cancel', 'open', 'retry', 'open', 'none'])
  // A retry press draws the seat as retrying, live, until the run relaunches it; its text stays to fold.
  const pressed = paneSections({ ...view, retries: ['grok-cli'] })
  expect(pressed.find(section => section.kind === 'seat' && section.name.trim() === 'grok-cli')).toMatchObject({ glyph: '●', glyphColor: 'warning', action: { press: 'fold', seat: 'grok-cli' } })
  // A press whose offer the run withdrew is a plain error again.
  expect(paneSections({ ...view, retries: ['grok-cli'], retriable: [] }).find(section => section.kind === 'seat' && section.name.trim() === 'grok-cli')).toMatchObject({ glyph: '✗', glyphColor: 'error' })
  // A cancel marker for a seat past querying changes nothing.
  const stale = paneSections({ ...view, cancels: ['gemini'] })
  expect(stale[0]).toMatchObject({ glyph: '●', action: { press: 'cancel', seat: 'codex' } })
  expect(stale[1]).toMatchObject({ glyph: '✓', glyphColor: 'success' })
  // A finished run cancels and retries nothing; what is left is its text.
  expect(action(paneSections({ ...view, isDone: true }))).toEqual(['none', 'fold', 'fold', 'fold', 'none'])
})

test('a retriable error keeps its text open under the row while its digit retries', () => {
  const sections = paneSections({
    providers: [{ name: 'gemini', state: 'querying' }, { name: 'kimi', state: 'error', ms: 300 }],
    responses: {}, errors: { kimi: 'HTTP 500' }, colors: {}, retriable: ['kimi'], isDone: false,
  })
  expect(sections.slice(1, 3)).toEqual([
    { kind: 'seat', key: 'jump:kimi', fold: 'seat:jump:kimi', digit: '2', glyph: '✗', glyphColor: 'error', vendor: 'rgb(113,113,122)', name: 'kimi  ', model: '', note: '', time: '0.3s', open: true, action: { press: 'retry', seat: 'kimi' } },
    { kind: 'body', text: 'HTTP 500' },
  ])
})

test('a seat keeps its digit through a retry and its answer', () => {
  const digits = (sections: ReturnType<typeof paneSections>) => sections.flatMap(section => (section.kind === 'seat' ? [`${section.name.trim()} ${section.digit}`] : []))
  const failed = { providers: [{ name: 'gemini', state: 'complete', ms: 4210 }, { name: 'kimi', state: 'error', ms: 300 }, { name: 'openai', state: 'querying' }], responses: { gemini: 'a' }, errors: { kimi: 'HTTP 500' }, colors: {}, retriable: ['kimi'], isDone: false }
  expect(digits(paneSections(failed))).toEqual(['gemini 1', 'kimi 2', 'openai 3'])
  const retrying = { ...failed, retries: ['kimi'] }
  expect(digits(paneSections(retrying))).toEqual(['gemini 1', 'kimi 2', 'openai 3'])
  const answered = { ...failed, providers: [{ name: 'gemini', state: 'complete', ms: 4210 }, { name: 'kimi', state: 'complete', ms: 1500 }, { name: 'openai', state: 'complete', ms: 900 }], responses: { gemini: 'a', kimi: 'b', openai: 'c' }, retriable: [], isDone: true }
  expect(digits(paneSections(answered))).toEqual(['gemini 1', 'kimi 2', 'openai 3'])
})

test('the first ten seats carry a digit, the tenth 0, and the eleventh none but still its button', () => {
  const providers = Array.from({ length: 11 }, (_, index) => ({ name: `seat-${index + 1}`, state: 'querying' }))
  const rows = paneSections({ providers, responses: {}, errors: {}, colors: {}, isDone: false }).filter(section => section.kind === 'seat')
  expect(rows.map(row => (row.kind === 'seat' ? row.digit : undefined))).toEqual(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', ''])
  // The seat's name travels unpadded in its action, since the row's is padded to the column.
  expect(rows.map(row => (row.kind === 'seat' ? row.action?.seat : undefined))).toEqual(providers.map(provider => provider.name))
  expect(rows.at(-1)).toMatchObject({ digit: '', action: { press: 'cancel', seat: 'seat-11' } })
})

test('cancel all takes every seat still querying, in order, skipping one already pressed', () => {
  const view = {
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'grok-cli', state: 'querying' },
      { name: 'kimi', state: 'error', ms: 900 },
      { name: 'openai', state: 'querying' },
      { name: 'codex', state: 'querying' },
    ],
    isDone: false,
  }
  expect(seatsToCancel(view)).toEqual(['grok-cli', 'openai', 'codex'])
  expect(seatsToCancel({ ...view, cancels: ['openai'] })).toEqual(['grok-cli', 'codex'])
  // A marker for a seat past querying keeps nothing else out.
  expect(seatsToCancel({ ...view, cancels: ['gemini'] })).toEqual(['grok-cli', 'openai', 'codex'])
  expect(seatsToCancel({ ...view, cancels: ['grok-cli', 'openai', 'codex'] })).toEqual([])
  // A finished run has nothing to cancel, whatever its log last said.
  expect(seatsToCancel({ ...view, isDone: true })).toEqual([])
})

test('a cancelled seat draws a grey hollow ring, and a finished run leads with its summary', () => {
  const sections = paneSections({
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'grok-cli', state: 'cancelled', model: 'grok-4.7' },
    ],
    // The run removes a cancelled seat's error file; the status line is all.
    responses: { gemini: 'a' },
    errors: {},
    colors: { gemini: '59;130;246' },
    isDone: true,
  })
  expect(sections).toEqual([
    { kind: 'summary', text: '1 of 2 answered · 1 cancelled · 4.2s' },
    { kind: 'seat', key: 'jump:gemini', fold: 'seat:jump:gemini', digit: '1', glyph: '✓', glyphColor: 'success', vendor: 'rgb(59,130,246)', name: 'gemini  ', model: '', note: '', time: '4.2s', open: true, action: { press: 'fold', seat: 'gemini' } },
    { kind: 'body', text: 'a' },
    { kind: 'seat', key: 'jump:grok-cli', fold: 'seat:jump:grok-cli', digit: '2', glyph: '○', glyphColor: 'inactive', vendor: 'rgb(113,113,122)', name: 'grok-cli', model: 'grok-4.7', note: '', time: '    ', open: false },
    { kind: 'footer', keys: [{ hotkey: '✕', label: 'close' }] },
  ])
})

const answered = {
  providers: [
    { name: 'gemini', state: 'complete', ms: 4210 },
    { name: 'grok-cli', state: 'fallback', ms: 1200 },
    { name: 'kimi', state: 'error', ms: 900 },
  ],
  responses: { gemini: 'Use Postgres.', 'grok-cli': 'Use SQLite.' },
  errors: { 'grok-cli': 'usage limit', kimi: 'HTTP 429' },
  colors: {},
  isDone: true,
  synthesis: 'Postgres, mostly.',
}

test('a closed section draws its row alone; an open one keeps its text', () => {
  const sections = paneSections(answered, { closed: new Set(['seat:jump:grok-cli', 'seat:jump:kimi', 'synthesis:jump:synthesis']) })
  expect(sections).toEqual([
    { kind: 'summary', text: '2 of 3 answered · 1 error · 1 fell back · 4.2s' },
    { kind: 'synthesis', key: 'jump:synthesis', fold: 'synthesis:jump:synthesis', open: false },
    { kind: 'seat', key: 'jump:gemini', fold: 'seat:jump:gemini', digit: '1', glyph: '✓', glyphColor: 'success', vendor: 'rgb(113,113,122)', name: 'gemini  ', model: '', note: '', time: '4.2s', open: true, action: { press: 'fold', seat: 'gemini' } },
    { kind: 'body', text: 'Use Postgres.' },
    // The fallback reason goes with the answer it explains, so a closed seat hides both.
    { kind: 'seat', key: 'jump:grok-cli', fold: 'seat:jump:grok-cli', digit: '2', glyph: '✓', glyphColor: 'warning', vendor: 'rgb(113,113,122)', name: 'grok-cli', model: '', note: 'fell back', time: '1.2s', open: false, action: { press: 'open', seat: 'grok-cli' } },
    { kind: 'seat', key: 'jump:kimi', fold: 'seat:jump:kimi', digit: '3', glyph: '✗', glyphColor: 'error', vendor: 'rgb(113,113,122)', name: 'kimi    ', model: '', note: '', time: '0.9s', open: false, action: { press: 'open', seat: 'kimi' } },
    { kind: 'footer', keys: [{ hotkey: 'a', label: 'fold' }, { hotkey: '✕', label: 'close' }] },
  ])
})

test('the footer lists only the keys that apply now: a to fold or expand two or more, c while a seat can be cancelled, then close', () => {
  const view = {
    providers: [{ name: 'gemini', state: 'complete', ms: 4210 }, { name: 'kimi', state: 'error', ms: 300 }, { name: 'openai', state: 'querying' }],
    responses: { gemini: 'a' }, errors: { kimi: 'HTTP 500' }, colors: {}, isDone: false,
  }
  const footer = (options: Parameters<typeof paneSections>[1], change = {}) => paneSections({ ...view, ...change }, options).at(-1)
  expect(footer({})).toEqual({ kind: 'footer', keys: [{ hotkey: 'a', label: 'fold' }, { hotkey: 'c', label: 'cancel all' }, { hotkey: '✕', label: 'close' }] })
  // One section left open is enough to fold.
  expect(footer({ closed: new Set(['seat:jump:gemini']) })).toEqual({ kind: 'footer', keys: [{ hotkey: 'a', label: 'fold' }, { hotkey: 'c', label: 'cancel all' }, { hotkey: '✕', label: 'close' }] })
  expect(footer({ closed: new Set(['seat:jump:gemini', 'seat:jump:kimi']) })).toEqual({ kind: 'footer', keys: [{ hotkey: 'a', label: 'expand' }, { hotkey: 'c', label: 'cancel all' }, { hotkey: '✕', label: 'close' }] })
  // Once every querying seat's cancel is pressed, c goes.
  expect(footer({}, { cancels: ['openai'] })).toEqual({ kind: 'footer', keys: [{ hotkey: 'a', label: 'fold' }, { hotkey: '✕', label: 'close' }] })
  // With one section to fold there is no a.
  expect(footer({}, { errors: {} })).toEqual({ kind: 'footer', keys: [{ hotkey: 'c', label: 'cancel all' }, { hotkey: '✕', label: 'close' }] })
})

test('the seat folds are what closes when the synthesis lands, the synthesis itself not', () => {
  expect(seatFolds(paneSections(answered))).toEqual(['seat:jump:gemini', 'seat:jump:grok-cli', 'seat:jump:kimi'])
})

test('each seat appears once, live or finished', () => {
  for (const isDone of [false, true]) {
    const seats = paneSections({ ...answered, isDone }).flatMap(section => (section.kind === 'seat' ? [section.name.trim()] : []))
    expect(seats).toEqual(['gemini', 'grok-cli', 'kimi'])
  }
})

test('a finished run opens on its summary and the synthesis, the seats below; a live one keeps the synthesis last', () => {
  const view = {
    providers: [{ name: 'kimi', state: 'cached' }, { name: 'codex', state: 'complete', ms: 2000 }],
    responses: { kimi: 'x', codex: 'y' }, errors: {}, colors: {},
    isDone: true,
    synthesis: '**Consensus.** SQLite.',
  }
  const kinds = (sections: ReturnType<typeof paneSections>) => sections.map(section => section.kind)
  // The pane closes the seat folds as the synthesis lands.
  const folded = new Set(['seat:jump:kimi', 'seat:jump:codex'])
  expect(kinds(paneSections(view, { closed: folded }))).toEqual(['summary', 'synthesis', 'seat', 'seat', 'footer'])
  expect(paneSections(view, { closed: folded })[1]).toEqual({ kind: 'synthesis', key: 'jump:synthesis', fold: 'synthesis:jump:synthesis', open: true, text: '**Consensus.** SQLite.' })
  expect(kinds(paneSections({ ...view, isDone: false }))).toEqual(['seat', 'body', 'seat', 'body', 'synthesis', 'footer'])
  // Collapsing off keeps the live order under the summary.
  expect(kinds(paneSections(view, { collapsesWhenDone: false }))).toEqual(['summary', 'seat', 'body', 'seat', 'body', 'synthesis', 'footer'])
})

test('a closed answer leaves its share of the text budget to the open ones', () => {
  const long = { ...answered, responses: { gemini: 'g'.repeat(60000), 'grok-cli': 'k'.repeat(60000) }, synthesis: undefined }
  const body = (sections: ReturnType<typeof paneSections>) => sections.find(section => section.kind === 'body') as { kind: 'body'; text: string }
  expect(body(paneSections(long)).text).toMatch(/^g+\n\n_… \d+ more characters; the whole answer is in the result/)
  expect(body(paneSections(long, { closed: new Set(['seat:jump:grok-cli']) })).text).toBe('g'.repeat(60000))
})

test('paneSections falls back to a neutral vendor colour and notes an empty run', () => {
  const base = { responses: {}, errors: {}, colors: {} }
  expect(paneSections({ ...base, providers: [], isDone: false })).toEqual([{ kind: 'note', text: 'Waiting for the council...' }])
  expect(paneSections({ ...base, providers: [], isDone: true })).toEqual([{ kind: 'note', text: 'Council finished with no answers.' }])
  const [, seat] = paneSections({ ...base, providers: [{ name: 'kimi', state: 'cached' }], responses: { kimi: 'x' }, isDone: true })
  expect(seat).toEqual({ kind: 'seat', key: 'jump:kimi', fold: 'seat:jump:kimi', digit: '1', glyph: '✓', glyphColor: 'suggestion', vendor: 'rgb(113,113,122)', name: 'kimi', model: '', note: 'cached', time: '', open: true, action: { press: 'fold', seat: 'kimi' } })
})

test('paneSections shows why a seat fell back, between its row and the answer its API gave', () => {
  const sections = paneSections({
    providers: [{ name: 'grok-cli', state: 'fallback', ms: 1200, model: 'grok-4.6 via grok API' }],
    responses: { 'grok-cli': 'Use Postgres.' },
    errors: { 'grok-cli': 'Error from grok CLI: sandbox could not be applied' },
    colors: {},
    isDone: false,
  })
  expect(sections).toEqual([
    { kind: 'seat', key: 'jump:grok-cli', fold: 'seat:jump:grok-cli', digit: '1', glyph: '✓', glyphColor: 'warning', vendor: 'rgb(113,113,122)', name: 'grok-cli', model: 'grok-4.6 via grok API', note: 'fell back', time: '1.2s', open: true, action: { press: 'fold', seat: 'grok-cli' } },
    { kind: 'reason', text: 'grok-cli fell back: Error from grok CLI: sandbox could not be applied' },
    { kind: 'body', text: 'Use Postgres.' },
    { kind: 'footer', keys: [{ hotkey: '✕', label: 'close' }] },
  ])
  // A plain answer with no error on disk gets no reason line.
  const plain = paneSections({
    providers: [{ name: 'codex', state: 'complete' }],
    responses: { codex: 'x' }, errors: {}, colors: {}, isDone: false,
  })
  expect(plain.map(section => section.kind)).toEqual(['seat', 'body', 'footer'])
  // Nor does a seat that failed, was retried and then answered itself: the
  // first attempt's error file stays on disk, and it is not why anything fell back.
  const retried = paneSections({
    providers: [{ name: 'kimi', state: 'complete' }],
    responses: { kimi: 'x' }, errors: { kimi: 'HTTP 429' }, colors: {}, isDone: false,
  })
  expect(retried.map(section => section.kind)).toEqual(['seat', 'body', 'footer'])
})

test('a fallback seat whose answer has not landed yet shows nothing to open, not an error', () => {
  // The run writes the reason and the fallback status before the answer; a
  // poll in between must not paint the seat red.
  const sections = paneSections({
    providers: [{ name: 'grok-cli', state: 'fallback' }],
    responses: {}, errors: { 'grok-cli': 'sandbox could not be applied' }, colors: {}, isDone: false,
  })
  expect(sections).toEqual([
    { kind: 'seat', key: 'jump:grok-cli', fold: 'seat:jump:grok-cli', digit: '1', glyph: '✓', glyphColor: 'warning', vendor: 'rgb(113,113,122)', name: 'grok-cli', model: '', note: 'fell back', time: '', open: false },
    { kind: 'footer', keys: [{ hotkey: '✕', label: 'close' }] },
  ])
})

test('an error is carried at the length the pane draws, so a huge one does not squeeze the answers', () => {
  const sections = paneSections({
    providers: [{ name: 'openai', state: 'error' }, { name: 'gemini', state: 'complete' }],
    responses: { gemini: 'g'.repeat(20000) },
    errors: { openai: 'Raw response: ' + '<html>'.repeat(15000) },
    colors: {}, isDone: false,
  })
  const [, error, , answer] = sections as { kind: string; text: string }[]
  expect(error!.text.length).toBe(2000)
  expect(error!.text.startsWith('Raw response: <html><html>')).toBe(true)
  expect(answer!.text).toBe('g'.repeat(20000))
})

test('a cut inside a code block closes the block before the note, and never splits a character', () => {
  const code = 'intro\n\n```js\n' + 'x = 1\n'.repeat(400) + '```\n'
  const [clipped] = withinTextBudget([{ kind: 'body', text: code }], 600) as { kind: 'body'; text: string }[]
  expect(clipped!.text.length).toBeLessThanOrEqual(600)
  // The block is closed on its own line, straight before the note.
  expect(clipped!.text).toMatch(/\n```\n\n_\u2026 \d+ more characters;/)
  expect((clipped!.text.match(/^```/gm) ?? []).length % 2).toBe(0)
  // Two UTF-16 units per face: whichever budget puts the cut between them,
  // the kept text still holds whole faces only.
  const faces = '\u{1F600}'.repeat(500)
  for (const budget of [300, 301]) {
    const [cut] = withinTextBudget([{ kind: 'body', text: faces }], budget) as { kind: 'body'; text: string }[]
    const kept = cut!.text.split('\n\n_')[0]!
    expect(kept.length % 2).toBe(0)
    expect(cut!.text.length).toBeLessThanOrEqual(budget)
  }
})

test('the done summary says how many seats their API sibling answered', () => {
  const sections = paneSections({
    providers: [
      { name: 'codex', state: 'complete', ms: 2000 },
      { name: 'grok-cli', state: 'fallback', ms: 1200 },
      { name: 'kimi', state: 'error' },
    ],
    responses: { codex: 'a', 'grok-cli': 'b' }, errors: { 'grok-cli': 'sandbox', kimi: 'HTTP 429' }, colors: {}, isDone: true,
  })
  expect(sections[0]).toEqual({ kind: 'summary', text: '2 of 3 answered \u00b7 1 error \u00b7 1 fell back \u00b7 2.0s' })
})

test('a live seat counts up and a settled one keeps its final time, in the same column', () => {
  const view = {
    providers: [
      { name: 'codex', state: 'querying' },
      { name: 'kimi', state: 'complete', ms: 9200 },
    ],
    responses: {},
    errors: {},
    colors: {},
    isDone: false,
    queryingSinceMs: { codex: 1_000 },
  }
  const [codex, kimi] = paneSections(view, { nowMs: 13_450 })
  expect(codex).toMatchObject({ kind: 'seat', glyph: '●', time: '12.4s' })
  expect(kimi).toMatchObject({ kind: 'seat', glyph: '✓', time: ' 9.2s' })
  // A provider with no start recorded has a blank time.
  const [first] = paneSections({ ...view, queryingSinceMs: {} }, { nowMs: 13_450 })
  expect(first).toMatchObject({ glyph: '●', time: '    ' })
  // A clock reading older than the start (the first frame lands before the first tick) shows zero.
  const [early] = paneSections(view, { nowMs: 0 })
  expect(early).toMatchObject({ time: '0.0s' })
})

test('parseColors keeps the last colour written for each provider', () => {
  expect(parseColors('grok\t1;2;3\nkimi\t63;63;70\ngrok\t239;68;68\nbad line\n')).toEqual({ grok: '239;68;68', kimi: '63;63;70' })
})

test('paneSections keeps the whole pane under the engine\'s text limit by clipping long answers evenly', () => {
  // Claude Code refuses a Pane render carrying more than 100000 characters
  // and draws its own; ten answers of 15k each would. The synthesis is read
  // last and is never cut; the answers share what is left.
  const names = Array.from({ length: 10 }, (_, i) => `seat${i}`)
  const sections = paneSections({
    providers: names.map(name => ({ name, state: 'complete', ms: 1000, model: 'm' })),
    responses: Object.fromEntries(names.map(name => [name, `${name} says `.padEnd(15000, 'x')])),
    errors: {},
    colors: {},
    isDone: false,
    synthesis: 'S'.repeat(3000),
  })
  const text = (section: { kind: string }) => Object.values(section).filter((v): v is string => typeof v === 'string').join('')
  const total = sections.reduce((sum, section) => sum + text(section).length, 0)
  expect(total).toBeLessThanOrEqual(80000)
  const bodies = sections.filter(section => section.kind === 'body') as { kind: 'body'; text: string }[]
  expect(bodies).toHaveLength(10)
  for (const body of bodies) {
    expect(body.text.startsWith('seat')).toBe(true)
    expect(body.text).toMatch(/\n\n_\u2026 \d+ more characters; the whole answer is in the result \(\/claude-council:result\)_$/)
  }
  const synthesis = sections.find(section => section.kind === 'synthesis') as { kind: 'synthesis'; text: string }
  expect(synthesis.text).toBe('S'.repeat(3000))
  // An answer that fits its share is left alone, cut or not elsewhere.
  const mixed = paneSections({
    providers: [{ name: 'a', state: 'complete' }, { name: 'b', state: 'complete' }],
    responses: { a: 'short', b: 'y'.repeat(90000) },
    errors: {}, colors: {}, isDone: false,
  })
  const [first, second] = mixed.filter(section => section.kind === 'body') as { kind: 'body'; text: string }[]
  expect(first.text).toBe('short')
  expect(second.text.length).toBeLessThan(80000)
  // Equal answers get equal room, and no clipped body runs past its share.
  expect(new Set(bodies.map(body => body.text.length)).size).toBe(1)
})

test('paneSections counts the budget on the text as fitted to the pane, which can be longer', () => {
  // Fitting a wide table to a narrow pane rewrites each row as a record that
  // repeats every header, so an answer under the budget can be over it once
  // fitted. The stand-in here triples the text.
  const names = ['a', 'b', 'c']
  const sections = paneSections({
    providers: names.map(name => ({ name, state: 'complete' })),
    responses: Object.fromEntries(names.map(name => [name, 'y'.repeat(15000)])),
    errors: {}, colors: {}, isDone: false,
    synthesis: 'S'.repeat(1000),
  }, { fitText: text => text.repeat(3) })
  const drawn = sections.reduce((sum, section) => sum + Object.values(section).filter((v): v is string => typeof v === 'string').join('').length, 0)
  expect(drawn).toBeLessThanOrEqual(80000)
  const bodies = sections.filter(section => section.kind === 'body') as { kind: 'body'; text: string }[]
  expect(bodies.every(body => /more characters; the whole answer is in the result/.test(body.text))).toBe(true)
  // The synthesis is fitted too, and still never cut.
  expect(sections.find(section => section.kind === 'synthesis')).toEqual({ kind: 'synthesis', key: 'jump:synthesis', fold: 'synthesis:jump:synthesis', open: true, text: 'S'.repeat(3000) })
})

test('markdownBlocks keeps a short text whole and drops control characters Markdown refuses', () => {
  expect(markdownBlocks('ok\r\n\tdone\u001b[0m\u0007', 100)).toEqual(['ok\n\tdone[0m'])
})

test('markdownBlocks splits a long text at paragraph breaks, every block within the limit', () => {
  const text = ['aaaa', 'bbbb', 'cccc'].join('\n\n')
  expect(markdownBlocks(text, 10)).toEqual(['aaaa\n\nbbbb', 'cccc'])
})

test('markdownBlocks cuts a single paragraph longer than the limit', () => {
  expect(markdownBlocks('abcdefghij', 4)).toEqual(['abcd', 'efgh', 'ij'])
})

test('queryingSince starts a clock when a provider queries and drops it when it stops, so a retry starts over', () => {
  const first = queryingSince({}, [{ name: 'grok', state: 'querying' }, { name: 'kimi', state: 'complete' }], 1000)
  expect(first).toEqual({ grok: 1000 })
  expect(queryingSince(first, [{ name: 'grok', state: 'querying' }], 1500)).toEqual({ grok: 1000 })
  const failed = queryingSince(first, [{ name: 'grok', state: 'error' }], 2000)
  expect(failed).toEqual({})
  expect(queryingSince(failed, [{ name: 'grok', state: 'querying' }], 9000)).toEqual({ grok: 9000 })
})
