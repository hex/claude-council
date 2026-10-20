// ABOUTME: Reads Codex's model catalog from `codex debug models`: each model, whether Codex lists it, its efforts
// ABOUTME: A failed run or output that is not a catalog is an error, never an empty list

// defaultEffort is what the model uses when nothing sets one.
export type CatalogModel = { slug: string; listed: boolean; efforts: string[]; defaultEffort: string }
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
    const efforts = (levels as { effort?: unknown }[]).map(level => level.effort).filter((effort): effort is string => typeof effort === 'string')
    const defaultEffort = typeof entry.default_reasoning_level === 'string' ? entry.default_reasoning_level : ''
    models.push({ slug: entry.slug, listed: entry.visibility === 'list', efforts, defaultEffort })
  }
  return { models }
}
