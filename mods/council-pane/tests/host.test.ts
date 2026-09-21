// ABOUTME: Tests for choosing where a council run's pane is drawn: the mod or tmux
// ABOUTME: Covers spotting a council run, reading the stored or asked choice, and the /council-pane arguments
import { test, expect } from 'bun:test'
import { isCouncilRun, hostFrom, paneCommand, HOST_LABELS } from '../hooks/host'

test('isCouncilRun spots a query, not a fetch, a cancel or a listing', () => {
  expect(isCouncilRun('python3 task.py report; bash /x/scripts/run-council.sh --providers=codex -- "q"')).toBe(true)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --async -- "q"')).toBe(true)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --result=job-1')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --cancel=job-1')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/query-council.sh --list-default-models')).toBe(false)
  expect(isCouncilRun('git status')).toBe(false)
})

test('hostFrom reads a stored value or a dialog label, and nothing else', () => {
  expect(hostFrom('mod')).toBe('mod')
  expect(hostFrom('tmux')).toBe('tmux')
  expect(hostFrom(HOST_LABELS.mod)).toBe('mod')
  expect(hostFrom(HOST_LABELS.tmux)).toBe('tmux')
  expect(hostFrom('whatever I typed under Other')).toBeUndefined()
  expect(hostFrom(undefined)).toBeUndefined()
  expect(hostFrom(42)).toBeUndefined()
})

test('paneCommand reads the /council-pane argument', () => {
  expect(paneCommand('')).toEqual({ action: 'reopen' })
  expect(paneCommand('  tmux ')).toEqual({ action: 'choose', host: 'tmux' })
  expect(paneCommand('MOD')).toEqual({ action: 'choose', host: 'mod' })
  expect(paneCommand('ask')).toEqual({ action: 'forget' })
  expect(paneCommand('sideways')).toEqual({ action: 'unknown' })
})
