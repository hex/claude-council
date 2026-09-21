// ABOUTME: Tests for reading the pane's settings out of the options register receives
// ABOUTME: Absent or wrongly typed values fall back to the documented defaults
import { test, expect } from 'bun:test'
import { paneOptions } from '../hooks/options'

test('defaults: pane on, collapse when done, no wake', () => {
  expect(paneOptions({})).toEqual({ isEnabled: true, collapsesWhenDone: true, wakesOnAsyncDone: false })
})

test('declared values are taken, anything that is not a boolean is ignored', () => {
  expect(paneOptions({ pane: false, collapse_when_done: 'no', wake_on_async_done: true })).toEqual({
    isEnabled: false,
    collapsesWhenDone: true,
    wakesOnAsyncDone: true,
  })
})
