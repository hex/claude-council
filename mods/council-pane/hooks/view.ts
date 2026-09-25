// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import type { ProviderStatus } from './status'
import { COLOR } from './theme'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  colors: Record<string, string>
  isDone: boolean
  synthesis?: string
  // When the pane first saw each provider querying; the status log carries no clock.
  queryingSinceMs?: Record<string, number>
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

const STATE_COLORS: Record<string, string> = { querying: COLOR.warning, complete: COLOR.success, cached: COLOR.info, error: COLOR.danger }
// A provider with no colour of its own; a data colour, like the vendors' own.
const NEUTRAL_RGB = '113;113;122'
const SPINNER = ['\u280b', '\u2819', '\u2839', '\u2838', '\u283c', '\u2834', '\u2826', '\u2827', '\u2807', '\u280f']
export const spinner = (frame: number) => SPINNER[frame % SPINNER.length] ?? '\u25cf'

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
function statusRows(
  providers: ProviderStatus[],
  vendor: (name: string) => string,
  glyph: (state: string) => string,
  elapsed: (name: string) => string,
): Section[] {
  const shownTime = ({ name, state, ms }: ProviderStatus) => (state === 'querying' ? elapsed(name) : seconds(ms))
  const width = (texts: string[]) => Math.max(...texts.map(text => text.length))
  const names = width(providers.map(provider => provider.name))
  const states = width(providers.map(provider => provider.state))
  const times = width(providers.map(shownTime))
  return providers.map(provider => ({
    kind: 'status',
    glyph: glyph(provider.state),
    glyphColor: provider.state === 'error' ? COLOR.danger : vendor(provider.name),
    name: provider.name.padEnd(names),
    state: provider.state.padEnd(states),
    stateColor: STATE_COLORS[provider.state] ?? COLOR.muted,
    time: shownTime(provider).padStart(times),
    model: provider.model ?? '',
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
        color: state === 'error' ? COLOR.danger : vendor(name),
        name,
        hotkey: index < 9 ? String(index + 1) : '',
        ...(hasSection(name) ? { target: jumpKey(name) } : {}),
      })),
    },
  ]
}

// When each provider now querying was first seen querying. One that stops
// loses its entry, so a provider the person retries starts a fresh clock.
export function queryingSince(since: Record<string, number>, providers: ProviderStatus[], nowMs: number): Record<string, number> {
  const next: Record<string, number> = {}
  for (const { name, state } of providers) {
    if (state === 'querying') next[name] = since[name] ?? nowMs
  }
  return next
}

export function paneSections(
  { providers, responses, errors, colors, isDone, synthesis, queryingSinceMs = {} }: RunView,
  { collapsesWhenDone = true, frame = 0, nowMs = 0 }: { collapsesWhenDone?: boolean; frame?: number; nowMs?: number } = {},
): Section[] {
  if (providers.length === 0) {
    return [{ kind: 'note', text: isDone ? 'Council finished with no answers.' : 'Waiting for the council...' }]
  }
  const vendor = (name: string) => `rgb(${(colors[name] ?? NEUTRAL_RGB).replaceAll(';', ',')})`
  const glyph = (state: string) => {
    if (state === 'error') return '\u2717'
    return state === 'querying' ? spinner(frame) : '\u25cf'
  }
  // A querying provider's time runs from when the pane first saw it, in whole tenths.
  const elapsed = (name: string) => {
    const since = queryingSinceMs[name]
    return since === undefined ? '' : `${(Math.floor(Math.max(0, nowMs - since) / 100) / 10).toFixed(1)}s`
  }
  const hasSection = (name: string) => responses[name] !== undefined || errors[name] !== undefined
  const sections: Section[] = isDone && collapsesWhenDone ? doneSummary(providers, vendor, glyph, hasSection) : statusRows(providers, vendor, glyph, elapsed)
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
const MARKDOWN_LIMIT = 10000

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
