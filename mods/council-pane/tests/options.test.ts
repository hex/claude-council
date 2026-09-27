// ABOUTME: Tests for reading the pane's settings out of the options register receives
// ABOUTME: Absent or wrongly typed values fall back to the documented defaults
import { test, expect } from 'bun:test'
import { paneOptions } from '../hooks/options'

test('defaults: pane on, collapse when done, no wake, tool offered', () => {
  expect(paneOptions({})).toEqual({ host: 'ask', collapsesWhenDone: true, wakesOnAsyncDone: false, offersTool: true, roundLimitMinutes: 60 })
})

test('declared values are taken, anything that is not a boolean is ignored', () => {
  expect(paneOptions({ pane_host: 'tmux', collapse_when_done: 'no', wake_on_async_done: true, council_tool: false })).toEqual({
    host: 'tmux',
    collapsesWhenDone: true,
    wakesOnAsyncDone: true,
    offersTool: false,
    roundLimitMinutes: 60,
  })
})

test('an unknown pane_host value falls back to ask', () => {
  expect(paneOptions({ pane_host: 'sideways' }).host).toBe('ask')
})

test('the round limit takes whole minutes, 0 for none, and ignores anything else', () => {
  expect(paneOptions({ specialist_round_limit: 15 }).roundLimitMinutes).toBe(15)
  expect(paneOptions({ specialist_round_limit: 0 }).roundLimitMinutes).toBe(0)
  for (const bad of [-5, 1.5, '30', null]) expect(paneOptions({ specialist_round_limit: bad }).roundLimitMinutes).toBe(60)
})
