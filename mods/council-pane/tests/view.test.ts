// ABOUTME: Tests for choosing which council run the pane shows and the markdown it draws
// ABOUTME: Expected strings are written out by hand, never rebuilt from the code under test
import { test, expect } from 'bun:test'
import { unseenRun, paneSections, parseColors, markdownBlocks } from '../hooks/view'

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
    { kind: 'status', glyph: '\u25cf', glyphColor: 'rgb(59,130,246)', name: 'gemini', state: 'complete', stateColor: 'green', time: '4.2s', model: 'gemini-3-pro' },
    { kind: 'status', glyph: '\u25cf', glyphColor: 'rgb(113,113,122)', name: 'openai', state: 'querying', stateColor: 'yellow', time: '    ', model: '' },
    { kind: 'status', glyph: '\u2717', glyphColor: 'red', name: 'grok  ', state: 'error   ', stateColor: 'red', time: '0.9s', model: '' },
    { kind: 'banner', key: 'jump:gemini', title: 'GEMINI', subtitle: 'gemini-3-pro (4.2s)', background: 'rgb(59,130,246)' },
    { kind: 'body', text: 'Use Postgres.' },
    { kind: 'error', key: 'jump:grok', title: 'grok error', text: 'HTTP 429' },
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
        { glyph: '\u2717', color: 'red', name: 'grok', hotkey: '3', target: 'jump:grok' },
      ],
    },
  ])
})

test('paneSections keeps the status rows on a finished run when collapsing is off', () => {
  const view = { providers: [{ name: 'kimi', state: 'cached' }], responses: {}, errors: {}, colors: {}, isDone: true }
  expect(paneSections(view, { collapsesWhenDone: false }).map(section => section.kind)).toEqual(['status'])
  expect(paneSections(view).map(section => section.kind)).toEqual(['summary', 'strip'])
})

test('paneSections shows the synthesis above the provider answers', () => {
  const kinds = paneSections({
    providers: [{ name: 'kimi', state: 'cached' }],
    responses: { kimi: 'x' },
    errors: {},
    colors: {},
    isDone: true,
    synthesis: '**Consensus.** SQLite.',
  })
  expect(kinds.map(section => section.kind)).toEqual(['summary', 'strip', 'synthesis', 'banner', 'body'])
  expect(kinds[2]).toEqual({ kind: 'synthesis', text: '**Consensus.** SQLite.' })
})

test('parseColors keeps the last colour written for each provider', () => {
  expect(parseColors('grok\t1;2;3\nkimi\t63;63;70\ngrok\t239;68;68\nbad line\n')).toEqual({ grok: '239;68;68', kimi: '63;63;70' })
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
