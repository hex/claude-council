// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import { ANSWERED_STATES, type ProviderStatus } from './status'
import { COLOR } from './theme'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  colors: Record<string, string>
  isDone: boolean
  // The status log's last event in words, for the band.
  latest?: string
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
  // cancellable: a querying row while the run is live, which draws the cancel
  // button; cancel: its hotkey, a digit for the first nine rows only.
  | { kind: 'status'; glyph: string; glyphColor: string; name: string; state: string; stateColor: string; time: string; model: string; cancellable: boolean; cancel?: string }
  | { kind: 'summary'; text: string }
  | { kind: 'strip'; items: { glyph: string; color: string; name: string; hotkey: string; target?: string }[] }
  | { kind: 'banner'; key: string; title: string; subtitle: string; background: string }
  | { kind: 'body'; text: string }
  | { kind: 'reason'; text: string }
  | { kind: 'synthesis'; key: string; text: string }
  | { kind: 'error'; key: string; title: string; text: string }

const STATE_COLORS: Record<string, string> = { querying: COLOR.warning, complete: COLOR.success, cached: COLOR.info, error: COLOR.danger, fallback: COLOR.warning, cancelled: COLOR.muted, cancelling: COLOR.muted }
// What the pane writes to a seat's row between the press and the run's answer.
const CANCELLING = 'cancelling'
export const CANCEL_HINT = 'click \u2717 to cancel a seat, or ctrl+x tab then its digit'
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
// A cancelled seat's glyph is hollow and grey, where an error is a red cross.
const glyphColor = (name: string, state: string, vendor: (name: string) => string) =>
  state === 'error' ? COLOR.danger : state === 'cancelled' ? COLOR.muted : vendor(name)

// A seat is drawn as cancelling from the press until the run's log says so;
// the pane names which. Rows with a key get a hint line after them.
function statusRows(
  providers: ProviderStatus[],
  vendor: (name: string) => string,
  glyph: (state: string) => string,
  elapsed: (name: string) => string,
  cancellable: (state: string) => boolean,
  cancelKey: (index: number) => string | undefined,
): Section[] {
  const shownTime = ({ name, state, ms }: ProviderStatus) => (state === 'querying' ? elapsed(name) : seconds(ms))
  const width = (texts: string[]) => Math.max(...texts.map(text => text.length))
  const names = width(providers.map(provider => provider.name))
  const states = width(providers.map(provider => provider.state))
  const times = width(providers.map(shownTime))
  let keyed = false
  const rows: Section[] = providers.map((provider, index) => {
    const canCancel = cancellable(provider.state)
    const cancel = canCancel ? cancelKey(index) : undefined
    if (canCancel) keyed = true
    return {
      kind: 'status',
      glyph: glyph(provider.state),
      glyphColor: glyphColor(provider.name, provider.state, vendor),
      name: provider.name.padEnd(names),
      state: provider.state.padEnd(states),
      stateColor: STATE_COLORS[provider.state] ?? COLOR.muted,
      time: shownTime(provider).padStart(times),
      model: provider.model ?? '',
      cancellable: canCancel,
      ...(cancel ? { cancel } : {}),
    }
  })
  if (keyed) rows.push({ kind: 'note', text: CANCEL_HINT })
  return rows
}

function doneSummary(
  providers: ProviderStatus[],
  vendor: (name: string) => string,
  glyph: (state: string) => string,
  hasSection: (name: string) => boolean,
): Section[] {
  const count = (state: string) => providers.filter(provider => provider.state === state).length
  const answered = providers.filter(provider => ANSWERED_STATES.includes(provider.state)).length
  const slowest = Math.max(0, ...providers.map(provider => provider.ms ?? 0))
  const parts = [
    `${answered} of ${providers.length} answered`,
    count('error') > 0 ? `${count('error')} error` : '',
    count('cancelled') > 0 ? `${count('cancelled')} cancelled` : '',
    count('fallback') > 0 ? `${count('fallback')} fell back` : '',
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
        color: glyphColor(name, state, vendor),
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
  { collapsesWhenDone = true, frame = 0, nowMs = 0, fitText = (text: string) => text, cancelling = new Set<string>() }: { collapsesWhenDone?: boolean; frame?: number; nowMs?: number; fitText?: (text: string) => string; cancelling?: ReadonlySet<string> } = {},
): Section[] {
  if (providers.length === 0) {
    return [{ kind: 'note', text: isDone ? 'Council finished with no answers.' : 'Waiting for the council...' }]
  }
  // A seat still querying as far as the log knows, but already pressed.
  const shown = providers.map(provider => (provider.state === 'querying' && cancelling.has(provider.name) ? { ...provider, state: CANCELLING } : provider))
  const vendor = (name: string) => `rgb(${(colors[name] ?? NEUTRAL_RGB).replaceAll(';', ',')})`
  const glyph = (state: string) => {
    if (state === 'error') return '\u2717'
    if (state === 'cancelled' || state === CANCELLING) return '\u25cb'
    return state === 'querying' ? spinner(frame) : '\u25cf'
  }
  // The digit also jumps to the seat's section once the run is done, so it is only a cancel key while the run is live.
  const cancellable = (state: string) => !isDone && state === 'querying'
  const cancelKey = (index: number) => (index < 9 ? String(index + 1) : undefined)
  // A querying provider's time runs from when the pane first saw it, in whole tenths.
  const elapsed = (name: string) => {
    const since = queryingSinceMs[name]
    return since === undefined ? '' : `${(Math.floor(Math.max(0, nowMs - since) / 100) / 10).toFixed(1)}s`
  }
  const stateOf = new Map(providers.map(provider => [provider.name, provider.state]))
  // A cancelled seat's error file draws nothing (see below), so there is nothing to jump to.
  const hasSection = (name: string) => responses[name] !== undefined || (errors[name] !== undefined && stateOf.get(name) !== 'cancelled')
  const sections: Section[] = isDone && collapsesWhenDone ? doneSummary(shown, vendor, glyph, hasSection) : statusRows(shown, vendor, glyph, elapsed, cancellable, cancelKey)
  for (const { name, state, ms, model } of providers) {
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
      // A seat whose API sibling answered has both files: the error is why
      // the seat itself did not, and it belongs above that answer. The state
      // decides, since a seat that failed and then answered on a retry keeps
      // its first attempt's error file.
      if (state === 'fallback' && error !== undefined) sections.push({ kind: 'reason', text: noticeText(`${name} fell back: ${error}`) })
      // fitText rewrites an answer for the pane's width before the budget is
      // counted: a wide table becomes records that repeat every header, which
      // can lengthen it several times over.
      sections.push({ kind: 'body', text: fitText(response) })
    } else if (error !== undefined && state !== 'fallback' && state !== 'cancelled') {
      // A fallback seat's error file is its reason, written just before the
      // answer its API gave: with no answer yet there is nothing to show. A
      // cancelled seat's says only that the reader cancelled it; its row does.
      sections.push({ kind: 'error', key: jumpKey(name), title: `${name} error`, text: noticeText(error) })
    }
  }
  if (synthesis) {
    // It is written last and read last; landing above the answers would push them down mid-read.
    sections.push({ kind: 'synthesis', key: jumpKey('synthesis'), text: fitText(synthesis) })
    const strip = sections.find(section => section.kind === 'strip')
    if (strip?.kind === 'strip') {
      strip.items.push({ glyph: '\u2261', color: `rgb(${NEUTRAL_RGB.replaceAll(';', ',')})`, name: 'synthesis', hotkey: '0', target: jumpKey('synthesis') })
    }
  }
  return withinTextBudget(sections)
}

// Claude Code refuses a Pane render carrying more than 100000 characters of
// text and draws its own. The budget sits under that with room for what the
// pane draws around the sections (the retry row, the jump strip's names).
const PANE_TEXT_BUDGET = 80000
const CLIPPED = (more: number) => `\n\n_\u2026 ${more} more characters; the whole answer is in the result (/claude-council:result)_`

// An error or a fallback reason is drawn as its opening only: a provider can
// hand back a whole HTML error page. The section carries what is drawn, so
// the budget below counts that and no more.
const NOTICE_LIMIT = 2000
const noticeText = (text: string) => markdownBlocks(text, NOTICE_LIMIT)[0] ?? ''

// Every string a section carries, counted without copying any of them: this
// runs on each frame of a live pane.
const sectionLength = (section: Section) => {
  let length = 0
  for (const value of Object.values(section)) if (typeof value === 'string') length += value.length
  return length
}

// Cuts the answer bodies, and only them, until the pane fits the budget: the
// synthesis, banners, status rows and errors keep their text, and the bodies
// share what is left. A body within an even share is left whole and its unused
// room goes to the longer ones, which are all cut to the same length, so one
// long answer beside short ones is cut only as far as the budget demands.
export function withinTextBudget(sections: Section[], budget: number = PANE_TEXT_BUDGET): Section[] {
  const total = sections.reduce((sum, section) => sum + sectionLength(section), 0)
  if (total <= budget) return sections
  const lengths = sections.flatMap(section => (section.kind === 'body' ? [section.text.length] : [])).sort((a, b) => a - b)
  let room = budget - (total - lengths.reduce((sum, length) => sum + length, 0))
  let left = lengths.length
  for (const length of lengths) {
    if (length * left > room) break
    room -= length
    left--
  }
  const cap = Math.max(0, Math.floor(room / Math.max(1, left)))
  return sections.map(section => (section.kind !== 'body' || section.text.length <= cap ? section : { kind: 'body', text: clipped(section.text, cap) }))
}

const FENCE_CLOSE = '\n```'

// The opening of an answer and a note saying how much is left out, together
// within `room`. The room set aside is for the longest the note can be and a
// closing fence, so the result never runs past it. The cut does not fall
// between the two halves of one character, and a code block it lands in is
// closed first (a backtick fence; a tilde one is rare enough to leave), so the
// note reads as text and the rest of the pane is not drawn as code.
function clipped(text: string, room: number): string {
  let cut = Math.max(0, room - CLIPPED(text.length).length - FENCE_CLOSE.length)
  const last = cut > 0 ? text.charCodeAt(cut - 1) : 0
  if (last >= 0xd800 && last <= 0xdbff) cut--
  const kept = text.slice(0, cut)
  const isInsideFence = (kept.match(/^ {0,3}```/gm)?.length ?? 0) % 2 === 1
  return kept + (isInsideFence ? FENCE_CLOSE : '') + CLIPPED(text.length - cut)
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
