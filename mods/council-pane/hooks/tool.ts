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
const QUOTED_MAX = 300
// Past this many seats the dialog gives their count instead of their names.
const NAMED_MAX = 4

// The confirmation the user answers before the question leaves the machine.
// Called on input councilArgs has already accepted and that names both choices.
export function confirmQuestion(input: Record<string, unknown>): string {
  const question = String(input.question)
  const quoted = question.length > QUOTED_MAX ? `${question.slice(0, QUOTED_MAX)}\u2026` : question
  const seats = input.providers as string[]
  const who = seats.length > NAMED_MAX ? `${seats.length} seats` : seats.join(', ')
  return `Send "${quoted}" to ${who} at ${String(input.verbosity)} verbosity?`
}

// Only the exact send label sends. `answer` is undefined when the dialog
// rejected: dismissed, or a run with no one to ask. Free text typed under
// Other goes back to the model as a plain result, not a refusal: it is
// usually an instruction, and a refusal is drawn as an error.
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
    'On "Let me pick individually", make a second AskUserQuestion call splitting the seats above across up to 4 multiSelect questions of at most 4 options each, labelled as listed, and pass the union.',
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

// A seat named outright may sit outside the default set: a shadowed API seat
// such as openai, or an opt-in one such as claude-cli. The runner knows a name
// when a providers/<name>.sh exists or it is one of the router's numbered seats.
export function unknownSeats(named: string[], available: string[], scripts: string[]): string | undefined {
  const unknown = named.filter(name => !available.includes(name) && !scripts.includes(name) && !ROUTER_SEAT.test(name))
  if (unknown.length === 0) return undefined
  const offer = available.length > 0 ? `The seats available now are ${available.join(', ')}.` : 'No seat is available now.'
  return `Not council seats: ${unknown.join(', ')}. ${offer} Nothing was sent.`
}

export function councilArgs(input: Record<string, unknown>): { args: string[] } | { deny: string } {
  const { question, providers, verbosity } = input
  if (typeof question !== 'string' || question.trim() === '') return { deny: 'question must be a non-empty string' }
  const flags: string[] = []
  if (providers !== undefined) {
    const isNames = Array.isArray(providers) && providers.length > 0 && providers.every(name => typeof name === 'string' && /^[a-z][a-z0-9-]*$/.test(name))
    if (!isNames) return { deny: 'providers must be names like codex or openrouter-2' }
    flags.push(`--providers=${(providers as string[]).join(',')}`)
  }
  if (verbosity !== undefined) {
    if (typeof verbosity !== 'string' || !VERBOSITIES.includes(verbosity)) return { deny: 'verbosity must be brief, standard or detailed' }
    flags.push(`--verbosity=${verbosity}`)
  }
  return { args: [...flags, '--', question] }
}
