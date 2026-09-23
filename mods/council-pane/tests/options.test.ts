// ABOUTME: Tests for reading the pane's settings out of the options register receives
// ABOUTME: Absent or wrongly typed values fall back to the documented defaults
import { test, expect } from 'bun:test'
import { paneOptions } from '../hooks/options'

test('defaults: pane on, collapse when done, no wake, tool offered', () => {
  expect(paneOptions({})).toEqual({ host: 'ask', collapsesWhenDone: true, wakesOnAsyncDone: false, offersTool: true })
})

test('declared values are taken, anything that is not a boolean is ignored', () => {
  expect(paneOptions({ pane_host: 'tmux', collapse_when_done: 'no', wake_on_async_done: true, council_tool: false })).toEqual({
    host: 'tmux',
    collapsesWhenDone: true,
    wakesOnAsyncDone: true,
    offersTool: false,
  })
})

test('an unknown pane_host value falls back to ask', () => {
  expect(paneOptions({ pane_host: 'sideways' }).host).toBe('ask')
})
