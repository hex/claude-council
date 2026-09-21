// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import type { ProviderStatus } from './status'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  colors: Record<string, string>
  isDone: boolean
  synthesis?: string
}

type DirEntry = { name: string; kind: string }

export function unseenRun(entries: readonly DirEntry[], shown: ReadonlySet<string>): string | undefined {
  return entries.find(entry => entry.kind === 'dir' && entry.name.startsWith('run.') && !shown.has(entry.name))?.name
}

export type Section =
  | { kind: 'note'; text: string }
  | { kind: 'status'; glyph: string; glyphColor: string; name: string; state: string; stateColor: string; time: string; model: string }
  | { kind: 'summary'; text: string }
  | { kind: 'strip'; items: { glyph: string; color: string; name: string; hotkey: string; target?: string }[] }
  | { kind: 'banner'; key: string; title: string; subtitle: string; background: string }
  | { kind: 'body'; text: string }
  | { kind: 'synthesis'; key: string; text: string }
  | { kind: 'error'; key: string; title: string; text: string }

const STATE_COLORS: Record<string, string> = { querying: 'yellow', complete: 'green', cached: 'cyan', error: 'red' }
const NEUTRAL_RGB = '113;113;122'

const jumpKey = (name: string) => `jump:${name}`

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

// Columns are padded here so the rows line up whatever the surface's layout does.
function statusRows(providers: ProviderStatus[], vendor: (name: string) => string, glyph: (state: string) => string): Section[] {
  const width = (texts: string[]) => Math.max(...texts.map(text => text.length))
  const names = width(providers.map(provider => provider.name))
  const states = width(providers.map(provider => provider.state))
  const times = width(providers.map(provider => seconds(provider.ms)))
  return providers.map(({ name, state, ms, model }) => ({
    kind: 'status',
    glyph: glyph(state),
    glyphColor: state === 'error' ? 'red' : vendor(name),
    name: name.padEnd(names),
    state: state.padEnd(states),
    stateColor: STATE_COLORS[state] ?? 'gray',
    time: seconds(ms).padStart(times),
    model: model ?? '',
  }))
}

function doneSummary(
  providers: ProviderStatus[],
  vendor: (name: string) => string,
  glyph: (state: string) => string,
  hasSection: (name: string) => boolean,
): Section[] {
  const count = (state: string) => providers.filter(provider => provider.state === state).length
  const answered = count('complete') + count('cached')
  const slowest = Math.max(0, ...providers.map(provider => provider.ms ?? 0))
  const parts = [
    `${answered} of ${providers.length} answered`,
    count('error') > 0 ? `${count('error')} error` : '',
    count('cached') > 0 ? `${count('cached')} cached` : '',
    slowest > 0 ? seconds(slowest) : '',
  ]
  return [
    { kind: 'summary', text: parts.filter(Boolean).join(' \u00b7 ') },
    {
      kind: 'strip',
      // The digit is the hotkey that jumps to the provider's section while the pane has the keys.
      items: providers.map(({ name, state }, index) => ({
        glyph: glyph(state),
        color: state === 'error' ? 'red' : vendor(name),
        name,
        hotkey: index < 9 ? String(index + 1) : '',
        ...(hasSection(name) ? { target: jumpKey(name) } : {}),
      })),
    },
  ]
}

export function paneSections(
  { providers, responses, errors, colors, isDone, synthesis }: RunView,
  { collapsesWhenDone = true }: { collapsesWhenDone?: boolean } = {},
): Section[] {
  if (providers.length === 0) {
    return [{ kind: 'note', text: isDone ? 'Council finished with no answers.' : 'Waiting for the council...' }]
  }
  const vendor = (name: string) => `rgb(${(colors[name] ?? NEUTRAL_RGB).replaceAll(';', ',')})`
  const glyph = (state: string) => (state === 'error' ? '\u2717' : '\u25cf')
  const hasSection = (name: string) => responses[name] !== undefined || errors[name] !== undefined
  const sections: Section[] = isDone && collapsesWhenDone ? doneSummary(providers, vendor, glyph, hasSection) : statusRows(providers, vendor, glyph)
  for (const { name, ms, model } of providers) {
    const response = responses[name]
    const error = errors[name]
    if (response !== undefined) {
      const timing = ms === undefined ? '' : `(${seconds(ms)})`
      sections.push({
        kind: 'banner',
        key: jumpKey(name),
        title: name.toUpperCase(),
        subtitle: [model, timing].filter(Boolean).join(' '),
        background: vendor(name),
      })
      sections.push({ kind: 'body', text: response })
    } else if (error !== undefined) {
      sections.push({ kind: 'error', key: jumpKey(name), title: `${name} error`, text: error })
    }
  }
  if (synthesis) {
    // It is written last and read last; landing above the answers would push them down mid-read.
    sections.push({ kind: 'synthesis', key: jumpKey('synthesis'), text: synthesis })
    const strip = sections.find(section => section.kind === 'strip')
    if (strip?.kind === 'strip') {
      strip.items.push({ glyph: '\u2261', color: `rgb(${NEUTRAL_RGB.replaceAll(';', ',')})`, name: 'synthesis', hotkey: '0', target: jumpKey('synthesis') })
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
