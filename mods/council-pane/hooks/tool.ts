// ABOUTME: The council tool the model can call: its schema, the seat and verbosity choices it asks for, and its input turned into run-council.sh arguments
// ABOUTME: Input is model-written, so it is validated here before it reaches a command line

export const TOOL_NAME = 'ask'

export const TOOL_DESCRIPTION =
  'Ask the council of external AI models one question and get each answer back. ' +
  'Call this when the user asks for the council, or when a decision would benefit from outside perspectives. ' +
  'Pass providers when the user named the seats, with verbosity "standard" unless they asked for brief or detailed; ' +
  'otherwise leave providers out, and the result lists the seats and what to ask the user, sending nothing. ' +
  'The user is asked to confirm before anything is sent; a refusal comes back as the result; do not retry unless the reply asks for a change.'

export const TOOL_SCHEMA = {
  type: 'object',
  properties: {
    question: { type: 'string', description: 'The question, self-contained: the council sees nothing else.' },
    providers: { type: 'array', items: { type: 'string' }, description: 'Seat names, such as codex or openrouter-2; omit to get the list of seats.' },
    verbosity: { type: 'string', enum: ['brief', 'standard', 'detailed'], description: 'Omit to have the user choose.' },
  },
  required: ['question'],
  additionalProperties: false,
}

const VERBOSITIES = ['brief', 'standard', 'detailed']

export const SEND_LABEL = 'Send to the council'
export const KEEP_LABEL = "Don't send"

// The dialog shows a question of this many characters at most; the run still
// receives the whole question.
const SHOWN_MAX = 300
// Line ends, tabs and control characters, the escape that starts a terminal
// sequence among them.
const NOT_ONE_LINE = /[\s\u0000-\u001f\u007f-\u009f]+/g
// Format characters: the direction overrides and isolates that reorder the
// text after them, and the zero-width ones that hide inside a word.
const DRAWS_NOTHING = /\p{Cf}/gu

// The confirmation the user answers before the question leaves the machine.
// Who receives it and how verbose come first, every seat by name, and the
// question last on one line of its own, so nothing in the question can pass
// for the recipients or push them out of view.
export function confirmQuestion(question: string, seats: string[], verbosity: string): string {
  const line = question.replace(DRAWS_NOTHING, '').replace(NOT_ONE_LINE, ' ').trim()
  const shown = line.length > SHOWN_MAX ? `${line.slice(0, SHOWN_MAX)}… (the first ${SHOWN_MAX} of ${line.length} characters; the whole question is sent)` : line
  return `Send to ${seats.length} ${seats.length === 1 ? 'seat' : 'seats'} at ${verbosity} verbosity: ${seats.join(', ')}\nQuestion: ${shown}`
}

// Only the exact send label sends. `answer` is undefined when the dialog
// rejected: dismissed, or a run with no one to ask. Free text typed under
// Other goes back to the model as a plain result, not a refusal: it is
// usually an instruction, and a refusal is drawn as an error.
// The saved file ends in an empty Synthesis section the run leaves for Claude,
// and the tool route loads no skill that says so.
const SYNTHESIS_NOTE =
  '<!-- The Synthesis section above is empty on purpose: the council run never writes one. Write the synthesis yourself in your reply, under a `## 🧭 Synthesis` heading (consensus, divergence, recommendation), and never report the section as missing or empty. -->'

export function councilResult(file: string): string {
  return `${file.trimEnd()}\n\n${SYNTHESIS_NOTE}`
}

export function confirmOutcome(answer: string | undefined): { send: true } | { deny: string } | { reply: string } {
  if (answer === SEND_LABEL) return { send: true }
  if (answer === undefined) return { deny: 'The user was not asked (dialog dismissed or no one to ask), so nothing was sent to the council.' }
  if (answer === KEEP_LABEL) return { deny: 'The user chose not to send this to the council.' }
  return { reply: `The user did not send this to the council and said: ${answer}` }
}

export type Choice = 'seats' | 'verbosity'

// A call that leaves either out sends nothing: the user picks it first.
export function missingChoices(input: Record<string, unknown>): Choice[] {
  const missing: Choice[] = []
  if (input.providers === undefined) missing.push('seats')
  if (input.verbosity === undefined) missing.push('verbosity')
  return missing
}

export type Seat = { name: string; model: string }

// query-council.sh --list-default-models: one "<seat>\t<model>" per line, the
// seats a query runs when none are named. A model name may hold spaces.
export function seatsFromList(stdout: string): Seat[] {
  return stdout.split('\n').filter(line => line.includes('\t')).map(line => {
    const tab = line.indexOf('\t')
    return { name: line.slice(0, tab), model: line.slice(tab + 1) }
  })
}

const ROUTER_SEAT = /^openrouter-[1-9]\d*$/
const seatLabel = (seat: Seat) => `${seat.name} (${seat.model})`

const ASK_FIRST =
  'Nothing was sent to the council. Ask the user first, in one AskUserQuestion call holding the questions below, ' +
  'then call ask again with the same question, passing both providers and verbosity. ' +
  "Skip the asking when the user's own message already named the seats or said to ask every seat: " +
  'pass those names, and verbosity "standard" unless the user asked for brief or detailed.'

const VERBOSITY_QUESTION = [
  'Question "How verbose should the answers be?", header "Verbosity", multiSelect false, options:',
  '- "Standard (Recommended)": balanced thoroughness',
  '- "Brief": 3-5 sentences, bullets only, no code unless asked',
  '- "Detailed": thorough analysis with code examples and trade-offs',
  'Pass verbosity "standard", "brief" or "detailed" to match.',
].join('\n')

// The same questions /claude-council:ask puts (commands/ask.md, Pre-Query
// Interaction), shaped to AskUserQuestion's limit of four options a question.
function seatQuestion(seats: Seat[]): string[] {
  const list = ['Seats available now:', ...seats.map(seat => `- ${seatLabel(seat)}`), '']
  const all = `- "All ${seats.length} seats (Recommended)": every seat above`
  const pass = 'Pass the chosen seat names as providers; for All, pass every name above.'
  if (seats.length <= 3) {
    return [...list, 'Question "Which council seats should I ask?", header "Seats", multiSelect true, options:', all, ...seats.map(seat => `- "${seatLabel(seat)}"`), pass]
  }
  const routed = seats.filter(seat => ROUTER_SEAT.test(seat.name)).map(seat => seat.name)
  const direct = seats.filter(seat => !ROUTER_SEAT.test(seat.name)).map(seat => seat.name)
  const split = routed.length > 0 && direct.length > 0 ? [`- "Direct seats only": ${direct.join(', ')}`, `- "Routed models only": ${routed.join(', ')}`] : []
  return [
    ...list,
    'Question "Which council seats should I ask?", header "Seats", multiSelect false, options:',
    all,
    ...split,
    '- "Let me pick individually": choose exact seats',
    'On "Let me pick individually", make a second AskUserQuestion call splitting the seats above across up to 4 multiSelect questions of 2 to 4 options each, labelled as listed, and pass the union.',
    pass,
  ]
}

// The tool result for a call that sends nothing yet: what to ask the user, and
// how to call again with the answers.
export function choiceRequest(seats: Seat[], missing: Choice[]): string {
  const [lone] = seats
  const isLone = seats.length === 1 && lone !== undefined
  const asksVerbosity = missing.includes('verbosity')
  const asksSeats = missing.includes('seats')
  if (asksSeats && isLone && !asksVerbosity) {
    return `Nothing was sent to the council. Only one seat is available, ${seatLabel(lone)}: call ask again with the same question, passing providers ["${lone.name}"] and the same verbosity.`
  }
  const seatPart = !asksSeats ? [] : isLone ? [`Only one seat is available, ${seatLabel(lone)}: pass providers ["${lone.name}"] without asking.`, ''] : [...seatQuestion(seats), '']
  return [ASK_FIRST, '', ...seatPart, ...(asksVerbosity ? [VERBOSITY_QUESTION] : [])].join('\n').trimEnd()
}

const SEAT_NAME = /^[a-z][a-z0-9-]*$/
// Seats discovery never lists, because their program is on every PATH or each
// question bills a plan: the runner seats them only when named
// (discover_providers in scripts/lib/providers.sh). One missing here is
// refused by the tool until it is added.
const NAMED_ONLY = ['claude-cli', 'copilot-cli', 'opencode']

export type Askable = { found: string[]; namedOnly: string[] }

// The seats a call may name. Found: the ones a default query runs, and the
// ones this machine has a key or a program for though a default query leaves
// them out (an API seat its CLI shadows). Named-only: the ones the runner
// ships and nothing here has checked, so a refusal does not offer them.
// Every name passed on is one of these, so no other text reaches the runner.
export function askableSeats(defaults: string[], discovered: string[], scripts: string[]): Askable {
  const found = [...new Set([...defaults, ...discovered])].filter(name => SEAT_NAME.test(name))
  return { found, namedOnly: NAMED_ONLY.filter(name => scripts.includes(name) && !found.includes(name)) }
}

// `seats` is the named seats, each once: the one list the confirmation shows
// and the run receives.
export function councilArgs(input: Record<string, unknown>, askable: Askable): { args: string[]; seats: string[] | undefined } | { deny: string } {
  const { question, providers, verbosity } = input
  if (typeof question !== 'string' || question.trim() === '') return { deny: 'question must be a non-empty string' }
  const flags: string[] = []
  let seats: string[] | undefined
  if (providers !== undefined) {
    if (!Array.isArray(providers) || providers.length === 0 || !providers.every(name => typeof name === 'string')) {
      return { deny: 'providers must be a list of seat names, such as codex or openrouter-2' }
    }
    seats = [...new Set(providers as string[])]
    const refused = seats.filter(name => !askable.found.includes(name) && !askable.namedOnly.includes(name))
    if (refused.length > 0) {
      const offer = askable.found.length > 0 ? `The seats found here are ${askable.found.join(', ')}.` : 'No seat was found here.'
      return { deny: `Not seats the council can ask now: ${refused.join(', ')}. ${offer} Nothing was sent.` }
    }
    flags.push(`--providers=${seats.join(',')}`)
  }
  if (verbosity !== undefined) {
    if (typeof verbosity !== 'string' || !VERBOSITIES.includes(verbosity)) return { deny: 'verbosity must be brief, standard or detailed' }
    flags.push(`--verbosity=${verbosity}`)
  }
  return { args: [...flags, '--', question], seats }
}
