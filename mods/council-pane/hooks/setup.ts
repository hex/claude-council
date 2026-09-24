// ABOUTME: Pure decisions for the specialist setup screen: Codex's model catalog, one validator, rows and drafts
// ABOUTME: No engine calls here, so every rule runs under bun test
import { parseSpecialist, SLOTS, type Roles } from './specialist'

export type CatalogModel = { slug: string; listed: boolean; efforts: string[] }
export type Catalog = { models: CatalogModel[] } | { error: string }

const CATALOG = 'codex debug models'

export function parseCatalog(run: { exitCode: number; stdout: string; stderr: string }): Catalog {
  if (run.exitCode !== 0) return { error: run.stderr.split('\n')[0]?.trim() || `${CATALOG} exited ${run.exitCode}` }
  let data: unknown
  try { data = JSON.parse(run.stdout) } catch { return { error: `${CATALOG} printed something that is not JSON` } }
  const list = (data as { models?: unknown }).models
  if (!Array.isArray(list) || list.length === 0) return { error: `${CATALOG} printed no models list` }
  const models: CatalogModel[] = []
  for (const entry of list as Record<string, unknown>[]) {
    if (typeof entry.slug !== 'string' || entry.slug === '') return { error: `${CATALOG}: a model has no slug` }
    const levels = entry.supported_reasoning_levels
    if (!Array.isArray(levels)) return { error: `${CATALOG}: model '${entry.slug}' has no supported_reasoning_levels` }
    const efforts = levels.map(level => (level as { effort?: unknown }).effort).filter((e): e is string => typeof e === 'string')
    models.push({ slug: entry.slug, listed: entry.visibility === 'list', efforts })
  }
  return { models }
}

export type Fields = { name: string; model: string; perspective: string; effort: string; when: string }

export function rowText(f: Fields): string {
  return `${f.name} = ${f.model} as ${f.perspective}, ${f.effort ? `effort: ${f.effort}, ` : ''}when: ${f.when}`
}

// The fields a user types are checked here first, so each error names its field;
// the row then goes through parseSpecialist, the same reader session start uses.
export function checkSpecialist(f: Fields, slot: string, context: { roles: Roles; models: CatalogModel[]; options: Record<string, unknown> }): { row: string } | { error: string } {
  if (f.name.trim() === '') return { error: 'name is empty' }
  if (f.when.trim() === '') return { error: 'use-when is empty' }
  if (/[\r\n]/.test(f.when)) return { error: 'use-when must be one line' }
  const model = context.models.find(m => m.slug === f.model)
  if (!model) return { error: `model '${f.model}' is not in Codex's catalog: ${context.models.filter(m => m.listed).map(m => m.slug).join(', ')}` }
  if (f.effort && !model.efforts.includes(f.effort)) return { error: `effort '${f.effort}' is not offered by ${model.slug}: ${model.efforts.join(', ')}` }
  const row = rowText(f)
  const parsed = parseSpecialist(row, context.roles)
  if (parsed === undefined) return { error: 'the row is empty' }
  if ('error' in parsed) return parsed
  for (const other of SLOTS) {
    if (other === slot) continue
    const theirs = parseSpecialist(context.options[other], context.roles)
    if (theirs && !('error' in theirs) && theirs.name === parsed.name) return { error: `name '${parsed.name}' is already used by ${other}` }
  }
  return { row }
}

export function freeSlot(options: Record<string, unknown>): string | undefined {
  return SLOTS.find(slot => typeof options[slot] !== 'string' || (options[slot] as string).trim() === '')
}
