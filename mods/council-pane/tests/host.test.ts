// ABOUTME: Tests for choosing where a council run's pane is drawn: the mod or tmux
// ABOUTME: Covers spotting a council run, reading the stored or asked choice, and the /council-pane arguments
import { test, expect } from 'bun:test'
import { isCouncilRun, hostFrom, paneCommand, decideHost, hostRowLabel, HOST_LABELS } from '../hooks/host'

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
  expect(paneCommand(' ASK ')).toEqual({ action: 'forget' })
  expect(paneCommand('tmux')).toEqual({ action: 'unknown' })
})

test('decideHost: an explicit setting wins, ask falls to the remembered answer, then to a question', () => {
  expect(decideHost({ setting: 'claude-code', remembered: 'tmux', isInTmux: true })).toBe('mod')
  expect(decideHost({ setting: 'tmux', remembered: 'mod', isInTmux: true })).toBe('tmux')
  expect(decideHost({ setting: 'ask', remembered: 'tmux', isInTmux: true })).toBe('tmux')
  expect(decideHost({ setting: 'ask', remembered: undefined, isInTmux: true })).toBe('ask')
})

test('decideHost: outside tmux the only pane is the one in Claude Code, unless tmux was chosen outright', () => {
  expect(decideHost({ setting: 'ask', remembered: 'tmux', isInTmux: false })).toBe('mod')
  expect(decideHost({ setting: 'ask', remembered: undefined, isInTmux: false })).toBe('mod')
  expect(decideHost({ setting: 'tmux', remembered: undefined, isInTmux: false })).toBe('tmux')
})

test('hostRowLabel shows what ask has remembered', () => {
  expect(hostRowLabel('Council pane opens in', 'ask', 'tmux')).toBe('Council pane opens in (remembered: tmux)')
  expect(hostRowLabel('Council pane opens in', 'ask', 'mod')).toBe('Council pane opens in (remembered: claude-code)')
  expect(hostRowLabel('Council pane opens in', 'ask', undefined)).toBe('Council pane opens in')
  expect(hostRowLabel('Council pane opens in', 'tmux', 'mod')).toBe('Council pane opens in')
})
