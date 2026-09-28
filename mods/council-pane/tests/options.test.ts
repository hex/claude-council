// ABOUTME: Tests for reading the pane's settings out of the options register receives
// ABOUTME: Absent or wrongly typed values fall back to the documented defaults
import { test, expect } from 'bun:test'
import { paneOptions } from '../hooks/options'

test('defaults: pane on, collapse when done, no wake, tool offered', () => {
  expect(paneOptions({})).toEqual({ host: 'ask', collapsesWhenDone: true, wakesOnAsyncDone: false, offersTool: true, roundLimitSeconds: 3600 })
})

test('declared values are taken, anything that is not a boolean is ignored', () => {
  expect(paneOptions({ pane_host: 'tmux', collapse_when_done: 'no', wake_on_async_done: true, council_tool: false })).toEqual({
    host: 'tmux',
    collapsesWhenDone: true,
    wakesOnAsyncDone: true,
    offersTool: false,
    roundLimitSeconds: 3600,
  })
})

test('an unknown pane_host value falls back to ask', () => {
  expect(paneOptions({ pane_host: 'sideways' }).host).toBe('ask')
})

test('the round limit takes minutes as whole seconds, 0 for none, and ignores anything else', () => {
  expect(paneOptions({ specialist_round_limit: 15 }).roundLimitSeconds).toBe(900)
  expect(paneOptions({ specialist_round_limit: 0 }).roundLimitSeconds).toBe(0)
  expect(paneOptions({ specialist_round_limit: 0.5 }).roundLimitSeconds).toBe(30)
  expect(paneOptions({ specialist_round_limit: 90.5 }).roundLimitSeconds).toBe(5430)
  // A positive limit never rounds down to 0, which would mean no limit at all.
  expect(paneOptions({ specialist_round_limit: 0.001 }).roundLimitSeconds).toBe(1)
  for (const bad of [-5, Infinity, NaN, '30', null]) expect(paneOptions({ specialist_round_limit: bad }).roundLimitSeconds).toBe(3600)
})
