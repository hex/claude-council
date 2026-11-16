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
  expect(isCouncilRun('bash /x/scripts/run-council.sh -h')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh -- -h')).toBe(true)
  expect(isCouncilRun('grep -rn run-council.sh scripts/')).toBe(false)
  expect(isCouncilRun('cat scripts/run-council.sh')).toBe(false)
  expect(isCouncilRun('cd /x && bash "scripts/run-council.sh" --verbosity=brief -- "q"')).toBe(true)
})

test('isCouncilRun leaves a run that asks for no pane alone, wherever the flag sits before the separator', () => {
  expect(isCouncilRun('bash /x/scripts/run-council.sh "q" --no-pane')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --no-pane --providers=codex -- "q"')).toBe(false)
  expect(isCouncilRun('bash /x/scripts/run-council.sh --providers=codex -- "what does --no-pane do"')).toBe(true)
  expect(isCouncilRun('bash /x/scripts/run-council.sh -- q --no-pane')).toBe(true)
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

test('isCouncilRun answers within two seconds on a megabyte of anything', () => {
  const run = 'bash /x/run-council.sh -- q'
  const inputs: [string, boolean][] = [
    ['(a;'.repeat(20_000), false],
    ['(a;'.repeat(350_000), false],
    [`${'(a;'.repeat(350_000)}cat run-council.sh`, false],
    [`${';'.repeat(1_000_000)}cat run-council.sh`, false],
    ['run-council.sh/'.repeat(70_000), false],
    ['bash "run-council.sh '.repeat(50_000), false],
    [`${'timeout 5 env X=1 '.repeat(60_000)}${run}`, true],
    [`${'a/'.repeat(500_000)} ${run}`, false],
    [`${'a/'.repeat(500_000)}bash /x/run-council.sh -- q`, true],
    [`bash /x/run-council.sh ${'--list-'.repeat(140_000)}!`, true],
    [`bash /x/run-council.sh ${'--list-x '.repeat(110_000)}`, false],
    [`${'"$('.repeat(330_000)}cat run-council.sh`, false],
    [`${'"$(a) '.repeat(160_000)}cat run-council.sh`, false],
  ]
  for (const [input, expected] of inputs) {
    const started = performance.now()
    expect(isCouncilRun(input)).toBe(expected)
    expect(performance.now() - started).toBeLessThan(2000)
  }
}, 120_000)

test('isCouncilRun skips the value a runner option takes, and a runner that only reports', () => {
  expect(isCouncilRun('timeout -s KILL 600 bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('env -u FOO bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('env -i bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('nice -n 10 nohup bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('command -v bash /x/run-council.sh')).toBe(false)
  expect(isCouncilRun('command -V bash /x/run-council.sh')).toBe(false)
  expect(isCouncilRun('command bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('env echo bash /x/run-council.sh')).toBe(false)
})

test('isCouncilRun reads quotes: a separator or a flag inside them is text', () => {
  expect(isCouncilRun('git commit -m "docs (timeout 5 bash scripts/run-council.sh)"')).toBe(false)
  expect(isCouncilRun("echo 'a; bash /x/run-council.sh -- q'")).toBe(false)
  expect(isCouncilRun('bash /x/run-council.sh -- "what does --help do"')).toBe(true)
  expect(isCouncilRun('bash /x/run-council.sh --providers=codex -- --jobs')).toBe(true)
  expect(isCouncilRun('bash /x/run-council.sh --jobs; bash /x/run-council.sh -- "q"')).toBe(true)
  expect(isCouncilRun('bash /x/run-council.sh \\\n  --jobs')).toBe(false)
  expect(isCouncilRun('bash /x/run-council.sh \\\n  --providers=codex -- "q"')).toBe(true)
  expect(isCouncilRun('bash /x/not-run-council.sh -- "q"')).toBe(false)
})

test('isCouncilRun reads a run captured inside double quotes', () => {
  expect(isCouncilRun('OUT="$(bash "/x y/scripts/run-council.sh" --providers=codex -- "q")"')).toBe(true)
  expect(isCouncilRun('echo "saved: $(timeout 600 bash /x/run-council.sh -- "q" | tail -1)"')).toBe(true)
  expect(isCouncilRun('OUT="$(bash /x/run-council.sh --jobs)"')).toBe(false)
  expect(isCouncilRun('echo "$(date) bash /x/run-council.sh -- q"')).toBe(false)
  expect(isCouncilRun('echo "a $( (cd /x; ls) ) b; bash /x/run-council.sh -- q"')).toBe(false)
})

test('isCouncilRun reads a script path built from a command inside double quotes', () => {
  expect(isCouncilRun('bash "$(pwd)/scripts/run-council.sh" -- "q"')).toBe(true)
  expect(isCouncilRun('bash "$(dirname "$0")/run-council.sh" -- q')).toBe(true)
  expect(isCouncilRun('timeout 600 bash "$(cd /x; pwd)/scripts/run-council.sh" --providers=codex -- "q"')).toBe(true)
  expect(isCouncilRun('bash "$(pwd)/scripts/run-council.sh" --jobs')).toBe(false)
  expect(isCouncilRun('cat "$(pwd)/scripts/run-council.sh"')).toBe(false)
  expect(isCouncilRun('echo "$(pwd)" bash /x/run-council.sh -- q')).toBe(false)
})

test('isCouncilRun reads an escaped backslash inside double quotes as one backslash, so the quote after it closes', () => {
  expect(isCouncilRun(String.raw`echo "a\\"; bash "/x y/scripts/run-council.sh" -- "q"`)).toBe(true)
  expect(isCouncilRun(String.raw`echo "a\\" bash /x/run-council.sh -- q`)).toBe(false)
  expect(isCouncilRun(String.raw`echo "a\"; bash /x/run-council.sh -- q"`)).toBe(false)
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
