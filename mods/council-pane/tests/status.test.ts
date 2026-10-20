// ABOUTME: Tests for parsing the watch dir's status log into per-provider state
// ABOUTME: Fixtures mirror the tab-separated lines pane_status_event appends
import { test, expect } from 'bun:test'
import { count, ENDED_STATES, lastEvent, parseStatus } from '../hooks/status'

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
  expect(lastEvent(log('grok-cli\tfallback\t1200\tgrok-4.6 via grok API'))).toBe('grok-cli answered through its API')
  expect(lastEvent(log('kimi\tquerying\t\t'))).toBe('asking kimi')
  expect(lastEvent(log('grok-cli\tcancelled\t\tgrok-4.7'))).toBe('grok-cli cancelled')
  expect(lastEvent('gemini\tcomplete\t4210\t\nopenai')).toBe('gemini answered')
  expect(lastEvent('')).toBeUndefined()
})

test('count tallies the providers in any of the given states; an ended seat answered, failed or was cancelled', () => {
  const providers = [
    { name: 'gemini', state: 'complete' },
    { name: 'codex', state: 'cached' },
    { name: 'grok', state: 'error' },
    { name: 'grok-cli', state: 'cancelled' },
    { name: 'kimi', state: 'querying' },
  ]
  expect(count(providers, 'error', 'cancelled')).toBe(2)
  expect(count(providers, ...ENDED_STATES)).toBe(4)
  expect(ENDED_STATES).toEqual(['complete', 'cached', 'fallback', 'error', 'cancelled'])
})
