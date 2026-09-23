// ABOUTME: Pure decisions for the specialist tool: rows, call shapes, dialog text, prompts, results
// ABOUTME: No engine calls here, so every rule runs under bun test

export type Roles = Record<string, { name: string; prompt: string }>
export type Specialist = { name: string; model: string; perspective: string; when: string }

const ROW = /^\s*([^=\s]+)\s*=\s*(\S+)\s+as\s+([^,\s]+)\s*,\s*when:\s*(.+?)\s*$/
const NAME = /^[a-z][a-z0-9-]{0,23}$/
const WHEN_MAX = 200
const SHAPE = 'expected: name = model as perspective, when: use-when'
export const SLOTS = ['specialist_1', 'specialist_2', 'specialist_3', 'specialist_4']

export function parseSpecialist(row: unknown, roles: Roles): Specialist | { error: string } | undefined {
  if (row === undefined || (typeof row === 'string' && row.trim() === '')) return undefined
  if (typeof row !== 'string') return { error: SHAPE }
  const match = ROW.exec(row)
  if (!match) return { error: SHAPE }
  const [, name = '', model = '', perspective = '', when = ''] = match
  if (!NAME.test(name)) return { error: `name '${name}' must be lowercase letters, digits and dashes, starting with a letter` }
  if (!Object.hasOwn(roles, perspective)) return { error: `unknown perspective '${perspective}'` }
  if (when.length > WHEN_MAX) return { error: `use-when is longer than ${WHEN_MAX} characters` }
  return { name, model, perspective, when }
}

export function specialistRoster(options: Record<string, unknown>, roles: Roles): { specialists: Specialist[]; problems: string[] } {
  const specialists: Specialist[] = []
  const problems: string[] = []
  const usedBy = new Map<string, string>()
  for (const slot of SLOTS) {
    const parsed = parseSpecialist(options[slot], roles)
    if (parsed === undefined) continue
    if ('error' in parsed) { problems.push(`${slot} ignored: ${parsed.error}`); continue }
    const earlier = usedBy.get(parsed.name)
    if (earlier) { problems.push(`${slot} ignored: the name '${parsed.name}' is already used by ${earlier}`); continue }
    usedBy.set(parsed.name, slot)
    specialists.push(parsed)
  }
  return { specialists, problems }
}

export function specialistDescription(list: Specialist[]): string {
  const roster = list.map(s => `${s.name} (${s.perspective}, ${s.model}), use when: ${s.when}`).join('; ')
  return (
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    `Specialists: ${roster}. ` +
    'Suggest one when a task matches its use-when. Start with {specialist, task}; send review feedback with {run, message}; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'The user confirms before anything starts or is sent. A refusal comes back as the result; do not retry unless the reply asks for a change.'
  )
}

export function specialistSchema(list: Specialist[]): Record<string, unknown> {
  return {
    type: 'object',
    properties: {
      specialist: { type: 'string', enum: list.map(s => s.name) },
      task: { type: 'string', description: 'Start: the task, self-contained; the specialist sees only its worktree.' },
      run: { type: 'string', description: 'Follow-up or finish: the run id a start returned.' },
      message: { type: 'string', description: 'Follow-up: feedback for the specialist, e.g. a failing test.' },
      finish: { type: 'string', enum: ['merge', 'discard'] },
    },
    additionalProperties: false,
  }
}
