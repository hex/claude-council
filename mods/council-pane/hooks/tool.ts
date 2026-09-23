// ABOUTME: The council tool the model can call: its schema, and its input turned into run-council.sh arguments
// ABOUTME: Input is model-written, so it is validated here before it reaches a command line

export const TOOL_NAME = 'ask'

export const TOOL_DESCRIPTION =
  'Ask the council of external AI models one question and get each answer back. ' +
  'Call this when the user asks for the council, or when a decision would benefit from outside perspectives. ' +
  'The user is asked to confirm before anything is sent; a refusal comes back as the result; do not retry unless the reply asks for a change.'

export const TOOL_SCHEMA = {
  type: 'object',
  properties: {
    question: { type: 'string', description: 'The question, self-contained: the council sees nothing else.' },
    providers: { type: 'array', items: { type: 'string' }, description: 'Provider names; omit for every configured provider.' },
    verbosity: { type: 'string', enum: ['brief', 'standard', 'detailed'] },
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

// The confirmation the user answers before the question leaves the machine.
// Called on input councilArgs has already accepted.
export function confirmQuestion(input: Record<string, unknown>): string {
  const question = String(input.question)
  const quoted = question.length > QUOTED_MAX ? `${question.slice(0, QUOTED_MAX)}\u2026` : question
  const who = Array.isArray(input.providers) ? input.providers.join(', ') : 'every configured provider'
  return `Send "${quoted}" to ${who}?`
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
