// ABOUTME: Where a council run's pane is drawn: inside Claude Code by this mod, or in tmux
// ABOUTME: The pane_host setting decides; on ask the answer is asked once, kept in the plugin store, and forgotten with /council-pane ask

export type PaneHost = 'mod' | 'tmux'

export const HOST_STORE_KEY = 'pane_host'

export const HOST_QUESTION = 'Where should the council pane open?'

export const HOST_LABELS: Record<PaneHost, string> = {
  mod: 'Inside Claude Code',
  tmux: 'tmux pane',
}

// A query starts a pane; fetching, cancelling or listing jobs, listing models
// and asking for help do not, and neither does a command that only names the
// script (a grep, a cat): the script has to be what bash is given to run.
//
// The command is read once, left to right, into words. A quoted stretch is
// part of its word, spaces and separators included, so the desktop app's
// plugin folder reads as one path and a mention inside a commit message is
// text. A backslash before a space keeps the space in the word, before a line
// end joins the lines, and anywhere else is itself: a Windows separator.
// `;`, `&`, `|`, `(`, `)` and a line end close a segment. A segment is a query
// when its words are, in order: any `NAME=value` words; any runners, each with
// its options, durations and assignments; bash, by name or path; the script,
// by its file name; and no listing flag before a `--`, since what follows that
// is the question.
const SCRIPT_NAME = 'run-council.sh'
const ASSIGNMENT = /^[A-Za-z_]\w*=/
const NOT_A_QUERY = /^--(?:result|cancel|jobs|help|list-[a-z-]+)(?:=|$)/
// Programs that run the command they are given, each with the options of its
// own that take the next word as their value.
const RUNNERS = new Map<string, readonly string[]>([
  ['timeout', ['-s', '--signal', '-k', '--kill-after']],
  ['env', ['-u', '--unset', '-C', '--chdir']],
  ['nice', ['-n', '--adjustment']],
  ['exec', ['-a']],
  ['command', []],
  ['nohup', []],
  ['time', []],
])
// With these, `command` describes the program instead of running it.
const DESCRIBES = ['-v', '-V']

const baseName = (word: string) => word.slice(Math.max(word.lastIndexOf('/'), word.lastIndexOf('\\')) + 1)

function isQuery(words: string[]): boolean {
  let at = 0
  while (at < words.length && ASSIGNMENT.test(words[at]!)) at++
  for (let valued = RUNNERS.get(baseName(words[at] ?? '')); valued !== undefined; valued = RUNNERS.get(baseName(words[at] ?? ''))) {
    const isCommand = baseName(words[at]!) === 'command'
    at++
    while (at < words.length) {
      const word = words[at]!
      if (isCommand && DESCRIBES.includes(word)) return false
      if (valued.includes(word)) at += 2
      else if (word.startsWith('-') || /^\d/.test(word) || ASSIGNMENT.test(word)) at++
      else break
    }
  }
  if (baseName(words[at] ?? '') !== 'bash' || baseName(words[at + 1] ?? '') !== SCRIPT_NAME) return false
  for (let flag = at + 2; flag < words.length && words[flag] !== '--'; flag++) {
    if (NOT_A_QUERY.test(words[flag]!)) return false
  }
  return true
}

// Runs before every Bash command, so it reads each character once: the time
// it takes grows with the command's length and no faster.
export function isCouncilRun(command: string): boolean {
  if (!command.includes(SCRIPT_NAME)) return false
  let words: string[] = []
  let word: string | undefined
  let quote = ''
  const endWord = () => {
    if (word !== undefined) words.push(word)
    word = undefined
  }
  for (let at = 0; at < command.length; at++) {
    const char = command[at]!
    const next = command[at + 1]
    if (quote !== '') {
      if (char === quote) quote = ''
      else if (quote === '"' && char === '\\' && next === '"') word += command[++at]!
      else word += char
    } else if (char === '"' || char === "'") {
      quote = char
      word ??= ''
    } else if (char === '\\' && next === '\n') {
      at++
    } else if (char === '\\' && (next === ' ' || next === '\t')) {
      word = (word ?? '') + command[++at]!
    } else if (char === ' ' || char === '\t' || char === '\r') {
      endWord()
    } else if (';&|()\n'.includes(char)) {
      endWord()
      if (words.length > 0) {
        if (isQuery(words)) return true
        words = []
      }
    } else {
      word = (word ?? '') + char
    }
  }
  endWord()
  return isQuery(words)
}

export function hostFrom(value: unknown): PaneHost | undefined {
  if (value === 'mod' || value === HOST_LABELS.mod) return 'mod'
  if (value === 'tmux' || value === HOST_LABELS.tmux) return 'tmux'
  return undefined
}

export type HostSetting = 'ask' | 'claude-code' | 'tmux'

export function hostSetting(value: unknown): HostSetting {
  return value === 'claude-code' || value === 'tmux' ? value : 'ask'
}

// The settings row decides outright unless it says ask; then the remembered
// answer does, and with none the person is asked. Outside tmux the pane in
// Claude Code is the only one there is, so nothing is asked there.
export function decideHost(facts: { setting: HostSetting; remembered: PaneHost | undefined; isInTmux: boolean }): PaneHost | 'ask' {
  if (facts.setting === 'claude-code') return 'mod'
  if (facts.setting === 'tmux') return 'tmux'
  if (!facts.isInTmux) return 'mod'
  return facts.remembered ?? 'ask'
}

export function hostRowLabel(label: string, setting: HostSetting, remembered: PaneHost | undefined): string {
  if (setting !== 'ask' || !remembered) return label
  return `${label} \u2192 ${remembered === 'mod' ? 'Claude' : 'tmux'}`
}

export type PaneCommand = { action: 'reopen' } | { action: 'forget' } | { action: 'unknown' }

export function paneCommand(args: string): PaneCommand {
  const word = args.trim().toLowerCase()
  if (word === '') return { action: 'reopen' }
  return word === 'ask' ? { action: 'forget' } : { action: 'unknown' }
}
