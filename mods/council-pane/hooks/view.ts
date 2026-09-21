// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import type { ProviderStatus } from './status'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  colors: Record<string, string>
  isDone: boolean
}

type DirEntry = { name: string; kind: string }

export function unseenRun(entries: readonly DirEntry[], shown: ReadonlySet<string>): string | undefined {
  return entries.find(entry => entry.kind === 'dir' && entry.name.startsWith('run.') && !shown.has(entry.name))?.name
}

export type Section =
  | { kind: 'note'; text: string }
  | { kind: 'status'; name: string; detail: string; color: string }
  | { kind: 'banner'; title: string; subtitle: string; background: string }
  | { kind: 'body'; text: string }
  | { kind: 'error'; title: string; text: string }

const STATE_COLORS: Record<string, string> = { querying: 'yellow', complete: 'green', cached: 'cyan', error: 'red' }
const NEUTRAL_RGB = '113;113;122'

function seconds(ms: number | undefined): string {
  return ms === undefined ? '' : `${(ms / 1000).toFixed(1)}s`
}

export function parseColors(log: string): Record<string, string> {
  const colors: Record<string, string> = {}
  for (const line of log.split('\n')) {
    const [name, rgb] = line.replace(/\r$/, '').split('\t')
    if (name && rgb && /^\d+;\d+;\d+$/.test(rgb)) colors[name] = rgb
  }
  return colors
}

export function paneSections({ providers, responses, errors, colors, isDone }: RunView): Section[] {
  if (providers.length === 0) {
    return [{ kind: 'note', text: isDone ? 'Council finished with no answers.' : 'Waiting for the council...' }]
  }
  const sections: Section[] = providers.map(({ name, state, ms }) => ({
    kind: 'status',
    name,
    detail: ms === undefined ? state : `${state}, ${seconds(ms)}`,
    color: STATE_COLORS[state] ?? 'gray',
  }))
  for (const { name, ms, model } of providers) {
    const response = responses[name]
    const error = errors[name]
    if (response !== undefined) {
      const timing = ms === undefined ? '' : `(${seconds(ms)})`
      sections.push({
        kind: 'banner',
        title: name.toUpperCase(),
        subtitle: [model, timing].filter(Boolean).join(' '),
        background: `rgb(${(colors[name] ?? NEUTRAL_RGB).replaceAll(';', ',')})`,
      })
      sections.push({ kind: 'body', text: response })
    } else if (error !== undefined) {
      sections.push({ kind: 'error', title: `${name} error`, text: error })
    }
  }
  return sections
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
