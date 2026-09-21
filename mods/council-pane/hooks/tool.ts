// ABOUTME: The council tool the model can call: its schema, and its input turned into run-council.sh arguments
// ABOUTME: Input is model-written, so it is validated here before it reaches a command line

export const TOOL_NAME = 'ask'

export const TOOL_DESCRIPTION =
  'Ask the council of external AI models one question and get each answer back. ' +
  'Call this only when the user has asked for the council; never convene it on your own initiative.'

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
