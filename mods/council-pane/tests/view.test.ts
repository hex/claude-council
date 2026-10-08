// ABOUTME: Tests for choosing which council run the pane shows and the markdown it draws
// ABOUTME: Expected strings are written out by hand, never rebuilt from the code under test
import { test, expect } from 'bun:test'
import { unseenRun, paneSections, parseColors, markdownBlocks, queryingSince, withinTextBudget } from '../hooks/view'

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

test('paneSections gives a coloured status row per provider, then a banner and body or an error for each', () => {
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
    { kind: 'status', glyph: '\u25cf', glyphColor: 'rgb(59,130,246)', name: 'gemini', state: 'complete', stateColor: 'success', time: '4.2s', model: 'gemini-3-pro' },
    { kind: 'status', glyph: '\u280b', glyphColor: 'rgb(113,113,122)', name: 'openai', state: 'querying', stateColor: 'warning', time: '    ', model: '', cancel: '2' },
    { kind: 'status', glyph: '\u2717', glyphColor: 'error', name: 'grok  ', state: 'error   ', stateColor: 'error', time: '0.9s', model: '' },
    { kind: 'note', text: 'click \u2717 to cancel a seat, or ctrl+x tab then its digit' },
    { kind: 'banner', key: 'jump:gemini', title: 'GEMINI', subtitle: 'gemini-3-pro (4.2s)', background: 'rgb(59,130,246)' },
    { kind: 'body', text: 'Use Postgres.' },
    { kind: 'error', key: 'jump:grok', title: 'grok error', text: 'HTTP 429' },
  ])
})

test('a querying row carries its digit as the cancel key while the run is live, and none once it is done', () => {
  const view = {
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'grok-cli', state: 'querying' },
      { name: 'kimi', state: 'querying' },
    ],
    responses: {}, errors: {}, colors: {},
    isDone: false,
  }
  const live = paneSections(view)
  expect(live.map(section => section.kind === 'status' ? section.cancel : undefined)).toEqual([undefined, '2', '3'])
  // The hint names the keys the way the retry row does, once per run.
  expect(live.at(-1)).toEqual({ kind: 'note', text: 'click ✗ to cancel a seat, or ctrl+x tab then its digit' })
  // A seat whose cancel is on its way draws as cancelling, with no key.
  const pending = paneSections(view, { cancelling: new Set(['grok-cli']) })
  expect(pending[1]).toMatchObject({ kind: 'status', state: 'cancelling', stateColor: 'inactive', glyph: '\u25cb' })
  expect(pending[1]).not.toHaveProperty('cancel')
  const done = paneSections({ ...view, isDone: true }, { collapsesWhenDone: false })
  expect(done.map(section => section.kind === 'status' ? section.cancel : undefined)).toEqual([undefined, undefined, undefined])
  expect(done.at(-1)?.kind).toBe('status')
})

test('a cancelled seat draws in grey and is counted apart in the summary', () => {
  const sections = paneSections({
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'grok-cli', state: 'cancelled', model: 'grok-4.7' },
    ],
    responses: { gemini: 'a' },
    errors: { 'grok-cli': 'cancelled from the pane' },
    colors: { gemini: '59;130;246' },
    isDone: true,
  })
  expect(sections.slice(0, 2)).toEqual([
    { kind: 'summary', text: '1 of 2 answered · 1 cancelled · 4.2s' },
    {
      kind: 'strip',
      items: [
        { glyph: '●', color: 'rgb(59,130,246)', name: 'gemini', hotkey: '1', target: 'jump:gemini' },
        { glyph: '○', color: 'inactive', name: 'grok-cli', hotkey: '2' },
      ],
    },
  ])
  // Its error file says only that it was cancelled: no error section is drawn for it.
  expect(sections.map(section => section.kind)).toEqual(['summary', 'strip', 'banner', 'body'])
  const live = paneSections({
    providers: [{ name: 'grok-cli', state: 'cancelled', model: 'grok-4.7' }],
    responses: {}, errors: { 'grok-cli': 'cancelled from the pane' }, colors: {}, isDone: false,
  })
  expect(live).toEqual([
    { kind: 'status', glyph: '○', glyphColor: 'inactive', name: 'grok-cli', state: 'cancelled', stateColor: 'inactive', time: '', model: 'grok-4.7' },
  ])
})

test('paneSections falls back to a neutral banner colour and notes an empty run', () => {
  const base = { responses: {}, errors: {}, colors: {} }
  expect(paneSections({ ...base, providers: [], isDone: false })).toEqual([{ kind: 'note', text: 'Waiting for the council...' }])
  expect(paneSections({ ...base, providers: [], isDone: true })).toEqual([{ kind: 'note', text: 'Council finished with no answers.' }])
  const [, , banner] = paneSections({ ...base, providers: [{ name: 'kimi', state: 'cached' }], responses: { kimi: 'x' }, isDone: true })
  expect(banner).toEqual({ kind: 'banner', key: 'jump:kimi', title: 'KIMI', subtitle: '', background: 'rgb(113,113,122)' })
})

test('paneSections collapses the status rows to a summary and a strip once the run is done', () => {
  const sections = paneSections({
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210 },
      { name: 'codex', state: 'cached' },
      { name: 'grok', state: 'error', ms: 900 },
    ],
    responses: { gemini: 'a' },
    errors: { grok: 'b' },
    colors: { gemini: '59;130;246' },
    isDone: true,
  })
  // A provider with nothing drawn below (codex) has no jump target.
  expect(sections.slice(0, 2)).toEqual([
    { kind: 'summary', text: '2 of 3 answered \u00b7 1 error \u00b7 1 cached \u00b7 4.2s' },
    {
      kind: 'strip',
      items: [
        { glyph: '\u25cf', color: 'rgb(59,130,246)', name: 'gemini', hotkey: '1', target: 'jump:gemini' },
        { glyph: '\u25cf', color: 'rgb(113,113,122)', name: 'codex', hotkey: '2' },
        { glyph: '\u2717', color: 'error', name: 'grok', hotkey: '3', target: 'jump:grok' },
      ],
    },
  ])
})

test('paneSections keeps the status rows on a finished run when collapsing is off', () => {
  const view = { providers: [{ name: 'kimi', state: 'cached' }], responses: {}, errors: {}, colors: {}, isDone: true }
  expect(paneSections(view, { collapsesWhenDone: false }).map(section => section.kind)).toEqual(['status'])
  expect(paneSections(view).map(section => section.kind)).toEqual(['summary', 'strip'])
})

test('paneSections shows the synthesis after the provider answers, with a jump to it in the strip', () => {
  const kinds = paneSections({
    providers: [{ name: 'kimi', state: 'cached' }],
    responses: { kimi: 'x' },
    errors: {},
    colors: {},
    isDone: true,
    synthesis: '**Consensus.** SQLite.',
  })
  expect(kinds.map(section => section.kind)).toEqual(['summary', 'strip', 'banner', 'body', 'synthesis'])
  expect(kinds[4]).toEqual({ kind: 'synthesis', key: 'jump:synthesis', text: '**Consensus.** SQLite.' })
  const strip = kinds[1]
  expect(strip?.kind === 'strip' ? strip.items.at(-1) : undefined).toEqual({
    glyph: '\u2261',
    color: 'rgb(113,113,122)',
    name: 'synthesis',
    hotkey: '0',
    target: 'jump:synthesis',
  })
})

test('paneSections shows why a seat fell back, between its banner and the answer its API gave', () => {
  const sections = paneSections({
    providers: [{ name: 'grok-cli', state: 'fallback', ms: 1200, model: 'grok-4.6 via grok API' }],
    responses: { 'grok-cli': 'Use Postgres.' },
    errors: { 'grok-cli': 'Error from grok CLI: sandbox could not be applied' },
    colors: {},
    isDone: false,
  })
  expect(sections.slice(1)).toEqual([
    { kind: 'banner', key: 'jump:grok-cli', title: 'GROK-CLI', subtitle: 'grok-4.6 via grok API (1.2s)', background: 'rgb(113,113,122)' },
    { kind: 'reason', text: 'grok-cli fell back: Error from grok CLI: sandbox could not be applied' },
    { kind: 'body', text: 'Use Postgres.' },
  ])
  // A plain answer with no error on disk gets no reason line.
  const plain = paneSections({
    providers: [{ name: 'codex', state: 'complete' }],
    responses: { codex: 'x' }, errors: {}, colors: {}, isDone: false,
  })
  expect(plain.map(section => section.kind)).toEqual(['status', 'banner', 'body'])
  // Nor does a seat that failed, was retried and then answered itself: the
  // first attempt's error file stays on disk, and it is not why anything fell back.
  const retried = paneSections({
    providers: [{ name: 'kimi', state: 'complete' }],
    responses: { kimi: 'x' }, errors: { kimi: 'HTTP 429' }, colors: {}, isDone: false,
  })
  expect(retried.map(section => section.kind)).toEqual(['status', 'banner', 'body'])
})

test('a fallback seat whose answer has not landed yet shows nothing, not an error', () => {
  // The run writes the reason and the fallback status before the answer; a
  // poll in between must not paint the seat red.
  const sections = paneSections({
    providers: [{ name: 'grok-cli', state: 'fallback' }],
    responses: {}, errors: { 'grok-cli': 'sandbox could not be applied' }, colors: {}, isDone: false,
  })
  expect(sections.map(section => section.kind)).toEqual(['status'])
})

test('an error is carried at the length the pane draws, so a huge one does not squeeze the answers', () => {
  const sections = paneSections({
    providers: [{ name: 'openai', state: 'error' }, { name: 'gemini', state: 'complete' }],
    responses: { gemini: 'g'.repeat(20000) },
    errors: { openai: 'Raw response: ' + '<html>'.repeat(15000) },
    colors: {}, isDone: false,
  })
  const error = sections.find(section => section.kind === 'error') as { kind: 'error'; text: string }
  expect(error.text.length).toBe(2000)
  expect(error.text.startsWith('Raw response: <html><html>')).toBe(true)
  const body = sections.find(section => section.kind === 'body') as { kind: 'body'; text: string }
  expect(body.text).toBe('g'.repeat(20000))
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

test('a querying provider spins and counts up; a settled one keeps its dot and final time', () => {
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
  const [codex, kimi] = paneSections(view, { frame: 13, nowMs: 13_450 })
  expect(codex).toMatchObject({ kind: 'status', glyph: '\u2838', time: '12.4s' })
  expect(kimi).toMatchObject({ kind: 'status', glyph: '\u25cf', time: ' 9.2s' })
  // Frame 0 and a provider with no start recorded: first spinner frame, blank time.
  const [first] = paneSections({ ...view, queryingSinceMs: {} }, { frame: 0, nowMs: 13_450 })
  expect(first).toMatchObject({ glyph: '\u280b', time: '    ' })
  // A clock reading older than the start (the first frame lands before the first tick) shows zero.
  const [early] = paneSections(view, { frame: 0, nowMs: 0 })
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
  expect(sections.find(section => section.kind === 'synthesis')).toEqual({ kind: 'synthesis', key: 'jump:synthesis', text: 'S'.repeat(3000) })
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
