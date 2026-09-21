// ABOUTME: Tests for parsing the watch dir's status log into per-provider state
// ABOUTME: Fixtures mirror the tab-separated lines pane_status_event appends
import { test, expect } from 'bun:test'
import { parseStatus } from '../hooks/status'

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
