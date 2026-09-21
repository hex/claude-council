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

// A Markdown element takes at most this many characters, tab and newline its
// only control characters; a tree holding one that breaks either rule is not drawn.
export const MARKDOWN_LIMIT = 10000

export function markdownBlocks(text: string, limit: number = MARKDOWN_LIMIT): string[] {
  const clean = text.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
  const blocks: string[] = []
  let block = ''
  for (const paragraph of clean.split('\n\n')) {
    const joined = block ? `${block}\n\n${paragraph}` : paragraph
    if (joined.length <= limit) {
      block = joined
      continue
    }
    if (block) blocks.push(block)
    block = paragraph
    while (block.length > limit) {
      blocks.push(block.slice(0, limit))
      block = block.slice(limit)
    }
  }
  if (block) blocks.push(block)
  return blocks
}
