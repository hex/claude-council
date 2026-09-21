// ABOUTME: Tests for choosing which council run the pane shows and the markdown it draws
// ABOUTME: Expected strings are written out by hand, never rebuilt from the code under test
import { test, expect } from 'bun:test'
import { unseenRun, paneMarkdown, markdownBlocks } from '../hooks/view'

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

test('paneMarkdown lists provider progress, then each answer and error under its own heading', () => {
  const text = paneMarkdown({
    providers: [
      { name: 'gemini', state: 'complete', ms: 4210, model: 'gemini-3-pro' },
      { name: 'openai', state: 'querying' },
      { name: 'grok', state: 'error', ms: 900 },
    ],
    responses: { gemini: 'Use Postgres.' },
    errors: { grok: 'HTTP 429' },
    isDone: false,
  })
  expect(text).toBe(
    [
      '- gemini: complete, 4.2s (gemini-3-pro)',
      '- openai: querying',
      '- grok: error, 0.9s',
      '',
      '## gemini',
      '',
      'Use Postgres.',
      '',
      '## grok error',
      '',
      'HTTP 429',
    ].join('\n'),
  )
})

test('paneMarkdown says so when the run has finished or has not reported yet', () => {
  const empty = { providers: [], responses: {}, errors: {} }
  expect(paneMarkdown({ ...empty, isDone: false })).toBe('Waiting for the council...')
  expect(paneMarkdown({ ...empty, isDone: true })).toBe('Council finished with no answers.')
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
