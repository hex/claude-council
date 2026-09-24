// ABOUTME: Pure decisions for the specialist setup screen: Codex's model catalog, one validator, rows and drafts
// ABOUTME: No engine calls here, so every rule runs under bun test
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
