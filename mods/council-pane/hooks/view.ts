// ABOUTME: Decides which council run the pane shows and turns its state into the markdown drawn there
// ABOUTME: Pure functions over plain values, so they run without the engine
import { bar, type BarFill } from './bar'
import { ANSWERED_STATES, count, type ProviderStatus } from './status'
import { COLOR } from './theme'

export type RunView = {
  providers: ProviderStatus[]
  responses: Record<string, string>
  errors: Record<string, string>
  // Seats pressed for cancel in the pane, from the watch dir's cancel folder.
  cancels?: string[]
  // Seats pressed for retry on their error row, from the watch dir's retry
  // folder, and the seats the run offers for it, from its retriable folder.
  retries?: string[]
  retriable?: string[]
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

// What a seat row's digit does now: end the seat, re-query it, or open or
// close the text under it.
type SeatAction = { press: 'cancel' | 'retry' | 'open' | 'fold'; seat: string }
type SeatNote = '' | 'cached' | 'fell back'

export type Section =
  | { kind: 'summary'; text: string }
  // One row per seat, its status and its fold header at once, with the name
  // padded to the column and the action's seat unpadded. A closed seat, or one
  // with nothing to show, is the row alone: no reason or body follows it.
  | { kind: 'seat'; key: string; fold: string; digit: string; glyph: string; glyphColor: string; vendor: string; name: string; model: string; note: SeatNote; bar: string; barColor: string; time: string; open: boolean; action?: SeatAction }
  | { kind: 'reason'; text: string }
  | { kind: 'body'; text: string }
  | { kind: 'synthesis'; key: string; fold: string; open: true; text: string }
  | { kind: 'synthesis'; key: string; fold: string; open: false }
  // The pane's keys that apply now, last.
  | { kind: 'footer'; keys: { hotkey: string; label: string }[] }
  // The empty run's one line.
  | { kind: 'note'; text: string }

// The bar takes the glyph's colour. A live seat has no share to show, so its
// bar sweeps on the pane's frame.
type SeatLook = { glyph: string; color: string; note: SeatNote; fill: (frame: number) => BarFill }
const SWEEP = (frame: number): BarFill => ({ kind: 'sweep', frame })
const FULL = (): BarFill => ({ kind: 'share', filled: 1, total: 1 })
const LIVE: SeatLook = { glyph: '\u25cf', color: COLOR.accent, note: '', fill: SWEEP }
const SET_ASIDE: SeatLook = { glyph: '\u25cb', color: COLOR.muted, note: '', fill: () => ({ kind: 'empty' }) }
// The glyph and its colour are the state; only a seat that answered some other
// way than asking says so in words. A state the pane does not know is drawn live.
const SEAT_LOOKS: Record<string, SeatLook> = {
  querying: LIVE,
  retrying: LIVE,
  complete: { glyph: '\u2713', color: COLOR.success, note: '', fill: FULL },
  cached: { glyph: '\u2713', color: COLOR.info, note: 'cached', fill: FULL },
  fallback: { glyph: '\u2713', color: COLOR.accent, note: 'fell back', fill: FULL },
  error: { glyph: '\u2717', color: COLOR.danger, note: '', fill: () => ({ kind: 'stub' }) },
  cancelled: SET_ASIDE,
  cancelling: SET_ASIDE,
}
// Frames between one seat's sweep and the next one's, so the live rows do not move in step.
const SWEEP_STAGGER = 7
// A provider with no colour of its own; a data colour, like the vendors' own.
const NEUTRAL_RGB = '113;113;122'

const jumpKey = (name: string) => `jump:${name}`
const fold = (kind: 'seat' | 'synthesis', key: string) => `${kind}:${key}`

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

// The seats whose error row can be retried: the ones the run offers, in the
// log's order, less any already pressed. The run offers a seat while its
// loop can still honour a press, and withdraws it at the relaunch.
export function seatsToRetry({ providers, retries = [], retriable = [], isDone }: Pick<RunView, 'providers' | 'retries' | 'retriable' | 'isDone'>): string[] {
  if (isDone) return []
  return providers.filter(({ name }) => retriable.includes(name) && !retries.includes(name)).map(({ name }) => name)
}

// What the band's cancel all presses: every seat a live run still has
// querying whose cancel has not been pressed yet, in the log's order.
export function seatsToCancel({ providers, cancels = [], isDone }: Pick<RunView, 'providers' | 'cancels' | 'isDone'>): string[] {
  if (isDone) return []
  return providers.filter(({ name, state }) => state === 'querying' && !cancels.includes(name)).map(({ name }) => name)
}

function summaryText(providers: ProviderStatus[]): string {
  const tally = (state: string, word: string) => (count(providers, state) > 0 ? `${count(providers, state)} ${word}` : '')
  const slowest = Math.max(0, ...providers.map(provider => provider.ms ?? 0))
  return [
    `${count(providers, ...ANSWERED_STATES)} of ${providers.length} answered`,
    tally('error', 'error'),
    tally('cancelled', 'cancelled'),
    tally('fallback', 'fell back'),
    tally('cached', 'cached'),
    slowest > 0 ? seconds(slowest) : '',
  ].filter(Boolean).join(' \u00b7 ')
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

type SeatMarks = Pick<RunView, 'cancels' | 'retries' | 'retriable' | 'isDone'>

// A seat still querying as far as the log knows, with its marker in the
// watch dir, is cancelling: the run removes the marker once it logs the seat.
function seatState({ name, state }: ProviderStatus, { cancels = [], retries = [], retriable = [], isDone }: SeatMarks): string {
  return state === 'querying' && cancels.includes(name) ? 'cancelling'
    : retriable.includes(name) && retries.includes(name) && !isDone ? 'retrying'
    : state
}

// Whether a live run's pane and band move: a seat querying or waiting on its
// retry runs a clock and a sweep, and so does the band.
export function isMoving(view: Pick<RunView, 'providers'> & SeatMarks): boolean {
  return !view.isDone && view.providers.some(provider => provider.state === 'querying' || seatState(provider, view) === 'retrying')
}

// A run that is live lists its seats with any open answers under them and
// the synthesis last. A finished one leads with its summary, and, collapsing
// when done, with the synthesis, the seats below it.
export function paneSections(
  { providers, responses, errors, cancels = [], retries = [], retriable = [], colors, isDone, synthesis, queryingSinceMs = {} }: RunView,
  { collapsesWhenDone = true, nowMs = 0, frame = 0, fitText = (text: string) => text, closed = new Set<string>() }: { collapsesWhenDone?: boolean; nowMs?: number; frame?: number; fitText?: (text: string) => string; closed?: ReadonlySet<string> } = {},
): Section[] {
  if (providers.length === 0) {
    return [{ kind: 'note', text: isDone ? 'Council finished with no answers.' : 'Waiting for the council...' }]
  }
  const shownState = (provider: ProviderStatus) => seatState(provider, { cancels, retries, retriable, isDone })
  // A querying provider's time runs from when the pane first saw it, in whole tenths.
  const elapsed = (name: string) => {
    const since = queryingSinceMs[name]
    return since === undefined ? '' : `${(Math.floor(Math.max(0, nowMs - since) / 100) / 10).toFixed(1)}s`
  }
  const shownTime = (provider: ProviderStatus) => {
    const state = shownState(provider)
    return state === 'querying' || state === 'retrying' ? elapsed(provider.name) : seconds(provider.ms)
  }
  // What hangs under a seat's row while it is open, built only then: its
  // answer, or the error of a seat that ended on one. A seat querying again
  // after a failure keeps its first error file and shows nothing.
  const textOf = ({ name, state }: ProviderStatus): (() => Section[]) | undefined => {
    const response = responses[name]
    const error = errors[name]
    if (response !== undefined) {
      // A seat whose API sibling answered has both files: the error is why
      // the seat itself did not, and it belongs above that answer. The state
      // decides, since a seat that failed and then answered on a retry keeps
      // its first attempt's error file. fitText rewrites an answer for the
      // pane's width before the budget is counted: a wide table becomes
      // records that repeat every header, which can lengthen it several times over.
      const reason: Section[] = state === 'fallback' && error !== undefined ? [{ kind: 'reason', text: noticeText(`${name} fell back: ${error}`) }] : []
      return () => [...reason, { kind: 'body', text: fitText(response) }]
    }
    return state === 'error' && error !== undefined ? () => [{ kind: 'body', text: noticeText(error) }] : undefined
  }
  // Columns are padded here so the rows line up whatever the surface's layout does.
  const width = (texts: string[]) => Math.max(...texts.map(text => text.length))
  const names = width(providers.map(provider => provider.name))
  const times = width(providers.map(shownTime))
  const cancellable = seatsToCancel({ providers, cancels, isDone })
  const retriableNow = seatsToRetry({ providers, retries, retriable, isDone })
  const seats = providers.flatMap((provider, index): Section[] => {
    const { name, model } = provider
    const key = jumpKey(name)
    const seatFold = fold('seat', key)
    const text = textOf(provider)
    const open = text !== undefined && !closed.has(seatFold)
    const look = SEAT_LOOKS[shownState(provider)] ?? LIVE
    const press = cancellable.includes(name) ? 'cancel' : retriableNow.includes(name) ? 'retry' : text ? (open ? 'fold' : 'open') : undefined
    const row: Section = {
      kind: 'seat',
      key,
      fold: seatFold,
      // The keyboard's number row: 1 to 9, then 0 for the tenth seat.
      digit: index < 10 ? String((index + 1) % 10) : '',
      glyph: look.glyph,
      glyphColor: look.color,
      vendor: `rgb(${(colors[name] ?? NEUTRAL_RGB).replaceAll(';', ',')})`,
      name: name.padEnd(names),
      model: model ?? '',
      note: look.note,
      bar: bar(look.fill(frame + index * SWEEP_STAGGER)),
      barColor: look.color,
      time: shownTime(provider).padStart(times),
      open,
      ...(press ? { action: { press, seat: name } } : {}),
    }
    return text && open ? [row, ...text()] : [row]
  })
  const synthesisKey = jumpKey('synthesis')
  const synthesisFold = fold('synthesis', synthesisKey)
  const synthesisSection: Section[] = !synthesis ? []
    : closed.has(synthesisFold) ? [{ kind: 'synthesis', key: synthesisKey, fold: synthesisFold, open: false }]
    : [{ kind: 'synthesis', key: synthesisKey, fold: synthesisFold, open: true, text: fitText(synthesis) }]
  const folds = [...providers.filter(provider => textOf(provider) !== undefined).map(({ name }) => fold('seat', jumpKey(name))), ...(synthesis ? [synthesisFold] : [])]
  return withinTextBudget([
    ...(isDone ? [{ kind: 'summary' as const, text: summaryText(providers) }] : []),
    ...(isDone && collapsesWhenDone ? [...synthesisSection, ...seats] : [...seats, ...synthesisSection]),
    footer(folds, closed, cancellable.length > 0),
  ])
}

// With two or more sections to fold, the a key folds the open ones while any
// is, else expands them all; c cancels every seat still out; the pane's own
// close mark closes it.
function footer(folds: string[], closed: ReadonlySet<string>, isCancellable: boolean): Section {
  const keys = [
    ...(folds.length > 1 ? [{ hotkey: 'a', label: folds.some(each => !closed.has(each)) ? 'fold' : 'expand' }] : []),
    ...(isCancellable ? [{ hotkey: 'c', label: 'cancel all' }] : []),
    { hotkey: '\u2715', label: 'close' },
  ]
  return { kind: 'footer', keys }
}

// The seats' folds, which close once the synthesis lands so it reads near
// the top; the synthesis stays open.
export function seatFolds(sections: Section[]): string[] {
  return sections.flatMap(section => (section.kind === 'seat' ? [section.fold] : []))
}

// Claude Code refuses a Pane render carrying more than 100000 characters of
// text and draws its own. The budget sits under that with room for what the
// pane draws around the sections (the retry row, the action labels, the footer's keys).
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

// Cuts the bodies, and only them, until the pane fits the budget: the
// synthesis, the seat rows and the reasons keep their text, and the bodies
// (the answers, and the errors already cut to their opening) share what is left. A body within an even share is left whole and its unused
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
