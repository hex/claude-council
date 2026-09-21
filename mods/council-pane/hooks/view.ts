// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import type { ProviderStatus } from './status'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  isDone: boolean
}

type DirEntry = { name: string; kind: string }

export function unseenRun(entries: readonly DirEntry[], shown: ReadonlySet<string>): string | undefined {
  return entries.find(entry => entry.kind === 'dir' && entry.name.startsWith('run.') && !shown.has(entry.name))?.name
}

function progressLine({ name, state, ms, model }: ProviderStatus): string {
  const timing = ms === undefined ? '' : `, ${(ms / 1000).toFixed(1)}s`
  return `- ${name}: ${state}${timing}${model ? ` (${model})` : ''}`
}

export function paneMarkdown({ providers, responses, errors, isDone }: RunView): string {
  if (providers.length === 0) return isDone ? 'Council finished with no answers.' : 'Waiting for the council...'
  const sections = providers.flatMap(({ name }) => {
    if (responses[name] !== undefined) return [`## ${name}`, responses[name]]
    if (errors[name] !== undefined) return [`## ${name} error`, errors[name]]
    return []
  })
  return [providers.map(progressLine).join('\n'), ...sections].join('\n\n')
}
