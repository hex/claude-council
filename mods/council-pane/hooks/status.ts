// ABOUTME: Parses a council watch dir's status log into one entry per provider
// ABOUTME: Lines are provider, state, milliseconds, model, tab-separated; later lines supersede earlier ones

export type ProviderStatus = {
  name: string
  state: string
  ms?: number
  model?: string
}

export function parseStatus(log: string): ProviderStatus[] {
  const byName = new Map<string, ProviderStatus>()
  for (const line of log.split('\n')) {
    const [name, state, ms, model] = line.replace(/\r$/, '').split('\t')
    if (!name || !state) continue
    const seen = byName.get(name) ?? { name, state }
    seen.state = state
    if (ms && /^\d+$/.test(ms)) seen.ms = Number(ms)
    if (model) seen.model = model
    byName.set(name, seen)
  }
  return [...byName.values()]
}
