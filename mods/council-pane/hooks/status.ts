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

const EVENT: Record<string, (name: string) => string> = {
  complete: name => `${name} answered`,
  cached: name => `${name} answered from cache`,
  error: name => `${name} failed`,
  querying: name => `asking ${name}`,
}

// The band's latest event: the last whole line of the log, in words. A line
// still being written has no state yet and is skipped.
export function lastEvent(log: string): string | undefined {
  const lines = log.split('\n').map(line => line.replace(/\r$/, '').split('\t'))
  for (const [name, state] of lines.reverse()) {
    if (!name || !state) continue
    return (EVENT[state] ?? (n => `${n} ${state}`))(name)
  }
  return undefined
}
