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

test('isCouncilRun ignores the script being listed, asked for help, or only named', () => {
  expect(isCouncilRun('bash /x/scripts/run-council.sh --jobs')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --help')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --list-available')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --list-default-models')).toBe(false)
  expect(isCouncilRun('grep -rn run-council.sh scripts/')).toBe(false)
  expect(isCouncilRun('cat scripts/run-council.sh')).toBe(false)
  expect(isCouncilRun('cd /x && bash "scripts/run-council.sh" --verbosity=brief -- "q"')).toBe(true)
})

test('isCouncilRun reads a quoted script path with spaces in it', () => {
  expect(isCouncilRun('bash "/Users/alice/Library/Application Support/Claude/plugin_1/scripts/run-council.sh" -- "is water wet"')).toBe(true)
  expect(isCouncilRun("bash '/opt/my plugins/scripts/run-council.sh' --providers=codex -- 'q'")).toBe(true)
  expect(isCouncilRun('bash "/Users/alice/Library/Application Support/Claude/plugin_1/scripts/run-council.sh" --jobs')).toBe(false)
  expect(isCouncilRun('bash "/Users/alice/Library/Application Support/Claude/plugin_1/scripts/query-council.sh" --list-default-models')).toBe(false)
  expect(isCouncilRun('bash "/x/my scripts/check-status.sh"; cat "/x/my scripts/run-council.sh"')).toBe(false)
  expect(isCouncilRun('bash /Users/alice/Library/Application\\ Support/Claude/plugin_1/scripts/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('bash /x/my\\ scripts/check-status.sh; cat /x/run-council.sh')).toBe(false)
})

test('isCouncilRun counts bash only where a command starts', () => {
  expect(isCouncilRun('echo bash "do not run run-council.sh"')).toBe(false)
  expect(isCouncilRun('rg bash "my notes/run-council.sh"')).toBe(false)
  expect(isCouncilRun("grep -rn bash 'docs/run-council.sh'")).toBe(false)
  expect(isCouncilRun('mkdir -p out\nbash "/x y/scripts/run-council.sh" -- "q"')).toBe(true)
  expect(isCouncilRun('cd /x || exit; (bash scripts/run-council.sh -- "q")')).toBe(true)
  expect(isCouncilRun('true | bash scripts/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('COUNCIL_TIMEOUT=500 GROK_MODEL="grok 4" bash "/x y/scripts/run-council.sh" -- "q"')).toBe(true)
})

test('isCouncilRun reads bash behind timeout or env, and by its own path', () => {
  expect(isCouncilRun('timeout 600 bash "/x y/scripts/run-council.sh" -- "q"')).toBe(true)
  expect(isCouncilRun('env X=1 bash /x/scripts/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('/bin/bash /x/scripts/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('/usr/bin/env bash "/x y/scripts/run-council.sh" -- "q"')).toBe(true)
  expect(isCouncilRun('cd /x && timeout -k 5 300 /bin/bash scripts/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('timeout 600 bash /x/scripts/run-council.sh --jobs')).toBe(false)
  expect(isCouncilRun('echo timeout 5 bash "do not run run-council.sh"')).toBe(false)
  expect(isCouncilRun('echo /bin/bash "notes/run-council.sh"')).toBe(false)
  expect(isCouncilRun('rg env bash "my notes/run-council.sh"')).toBe(false)
})

test('isCouncilRun reads a bare Windows path, whose backslashes escape nothing', () => {
  expect(isCouncilRun('bash C:\\x\\scripts\\run-council.sh --providers=codex -- "q"')).toBe(true)
  expect(isCouncilRun('bash "C:\\Program Files\\x\\scripts\\run-council.sh" -- "q"')).toBe(true)
  expect(isCouncilRun('bash C:\\x\\scripts\\run-council.sh --jobs')).toBe(false)
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

test('hostRowLabel shows what ask has remembered, short enough for the settings column', () => {
  expect(hostRowLabel('Pane opens in', 'ask', 'tmux')).toBe('Pane opens in \u2192 tmux')
  expect(hostRowLabel('Pane opens in', 'ask', 'mod')).toBe('Pane opens in \u2192 Claude')
  expect(hostRowLabel('Pane opens in', 'ask', undefined)).toBe('Pane opens in')
  expect(hostRowLabel('Pane opens in', 'tmux', 'mod')).toBe('Pane opens in')
  // The menu appends " · council-pane" and cuts the row at about 41 characters.
  expect(`${hostRowLabel('Pane opens in', 'ask', 'mod')} \u00b7 council-pane`.length).toBeLessThanOrEqual(41)
})
