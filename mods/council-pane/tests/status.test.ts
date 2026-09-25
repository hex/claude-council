// ABOUTME: Tests for parsing the watch dir's status log into per-provider state
// ABOUTME: Fixtures mirror the tab-separated lines pane_status_event appends
import { test, expect } from 'bun:test'
import { lastEvent, parseStatus } from '../hooks/status'

test('the last line for a provider wins, in first-seen order', () => {
  const log = 'gemini\tquerying\t\t\nopenai\tquerying\t\t\ngemini\tcomplete\t4210\tgemini-3-pro\n'
  expect(parseStatus(log)).toEqual([
    { name: 'gemini', state: 'complete', ms: 4210, model: 'gemini-3-pro' },
    { name: 'openai', state: 'querying' },
  ])
})

test('blank lines, a line with no state, CRLF endings and a non-numeric time are tolerated', () => {
  const log = '\nkimi\n\ngrok\terror\tsoon\t\r\n'
  expect(parseStatus(log)).toEqual([{ name: 'grok', state: 'error' }])
})

test('the latest event is the log\'s last whole line, in words', () => {
  const log = (last: string) => `gemini\tquerying\t\t\nopenai\tquerying\t\t\n${last}\n`
  expect(lastEvent(log('gemini\tcomplete\t4210\tgemini-3-pro'))).toBe('gemini answered')
  expect(lastEvent(log('codex\tcached\t\t'))).toBe('codex answered from cache')
  expect(lastEvent(log('grok\terror\t\t'))).toBe('grok failed')
  expect(lastEvent(log('kimi\tquerying\t\t'))).toBe('asking kimi')
  expect(lastEvent('gemini\tcomplete\t4210\t\nopenai')).toBe('gemini answered')
  expect(lastEvent('')).toBeUndefined()
})
