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
// `;`, `&`, `|`, `(`, `)` and a line end close a segment. A `$(` inside double
// quotes holds segments of its own up to its `)`, and the word around it goes
// on from there with nothing in its place. A segment is a query
// when its words are, in order: any `NAME=value` words; any runners, each with
// its options, durations and assignments; bash, by name or path; the script,
// by its file name; and no listing flag before a `--`, since what follows that
// is the question. A query told `--no-pane` before the `--` starts none.
const SCRIPT_NAME = 'run-council.sh'
const ASSIGNMENT = /^[A-Za-z_]\w*=/
const NOT_A_QUERY = /^(?:-h$|--(?:result|cancel|jobs|help|list-[a-z-]+)(?:=|$))/
const NO_PANE = '--no-pane'
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
  // `words[at]!` here and in the inner loop: the loop's own test holds `at` below words.length.
  while (at < words.length && ASSIGNMENT.test(words[at]!)) at++
  for (let valued = RUNNERS.get(baseName(words[at] ?? '')); valued !== undefined; valued = RUNNERS.get(baseName(words[at] ?? ''))) {
    // `!`: a runner was found under this word's name, and no runner has the empty name a missing word reads as.
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
  // `words[flag]!`: the loop's test holds `flag` below words.length.
  for (let flag = at + 2; flag < words.length && words[flag] !== '--'; flag++) {
    if (NOT_A_QUERY.test(words[flag]!) || words[flag] === NO_PANE) return false
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
  // One entry for each open parenthesis: for a `$(` met inside double quotes,
  // the segment it interrupted, which its `)` returns to; nothing for a bare one.
  const opened: ({ words: string[]; word: string | undefined } | undefined)[] = []
  const endsOnQuery = () => {
    if (word !== undefined) words.push(word)
    word = undefined
    if (words.length === 0) return false
    if (isQuery(words)) return true
    words = []
    return false
  }
  for (let at = 0; at < command.length; at++) {
    // `!`: the loop's test holds `at` below command.length.
    const char = command[at]!
    const next = command[at + 1]
    if (quote !== '') {
      if (char === quote) quote = ''
      // `command[++at]!` is `next`, which this branch has matched against a character.
      else if (quote === '"' && char === '\\' && (next === '"' || next === '\\')) word += command[++at]!
      else if (quote === '"' && char === '$' && next === '(') {
        at++
        opened.push({ words, word })
        words = []
        word = undefined
        quote = ''
      } else word += char
    } else if (char === '"' || char === "'") {
      quote = char
      word ??= ''
    } else if (char === '\\' && next === '\n') {
      at++
    } else if (char === '\\' && (next === ' ' || next === '\t')) {
      // `command[++at]!` is `next`, the space or tab matched above.
      word = (word ?? '') + command[++at]!
    } else if (char === ' ' || char === '\t' || char === '\r') {
      if (word !== undefined) words.push(word)
      word = undefined
    } else if (';&|()\n'.includes(char)) {
      if (endsOnQuery()) return true
      if (char === '(') opened.push(undefined)
      else if (char === ')') {
        const outer = opened.pop()
        if (outer) {
          words = outer.words
          word = outer.word
          quote = '"'
        }
      }
    } else {
      word = (word ?? '') + char
    }
  }
  return endsOnQuery()
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
