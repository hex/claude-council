// ABOUTME: Pure policy for the heads-up side-check: cadence, backoff, memory, the runner's result and the band's words
// ABOUTME: No engine calls, so every rule runs under bun test; pane.tsx is the shell that feeds events in

import type { Note, Phase, Session } from '../types'

/** Fire when the message index within the turn is a positive multiple of this; the builtin's number. */
export const DEFAULT_EVERY = 6
/** seen and known each keep this many topics, newest last; the builtin's cap. */
export const TOPIC_CAP = 50
export const TOPIC_CHARS = 140
export const DETAIL_CHARS = 600
export const HEADLINE_CHARS = 200
/** The builtin's test for "nothing to say", applied to a text seat's first line. */
export const NONE = /^none\s*(?:[.!?()[\]:;,-]|$)/i
/** A seat name becomes a script path in the runner, so it is only ever a plain word here. */
const SEAT_SHAPE = /^[a-z][a-z0-9-]+$/

export const CONFIG_FILE = '.claude/council-heads-up.json'
export const STORE_KEY = 'heads-up'

/** Parsed project file. Only parseConfig builds one; `seats` are shape-checked words, the runner owns the list. */
export type HeadsUpConfig =
  | { enabled: true; seats: readonly string[]; every: number }
  | { enabled: false; problem?: string }

/**
 * Missing -> off. Malformed JSON, a non-object, `enabled !== true`, a seat that
 * is not a plain word, or an `every` below 2 -> off with a problem the shell
 * logs once: a side-agent that never fires should say why.
 */
export function parseConfig(text: string | undefined): HeadsUpConfig {
  if (text === undefined) return { enabled: false }
  const off = (why: string): HeadsUpConfig => ({ enabled: false, problem: `${CONFIG_FILE}${why}; heads-up is off` })
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return off(' is not valid JSON')
  }
  if (!isRecord(raw)) return off(' must hold a JSON object')
  if (raw.enabled !== true) return off(': enabled is not true')
  const seats = raw.seats ?? ['codex']
  if (!Array.isArray(seats) || seats.length === 0) return off(': seats must be a non-empty list of seat names')
  const words = seats.filter((seat): seat is string => typeof seat === 'string' && SEAT_SHAPE.test(seat))
  const badSeat: unknown = seats.find(seat => !words.includes(seat))
  if (words.length !== seats.length) return off(`: seat ${JSON.stringify(badSeat)} is not a plain lowercase word`)
  const every = raw.every ?? DEFAULT_EVERY
  if (typeof every !== 'number' || !Number.isInteger(every) || every < 2) return off(`: every must be a whole number of at least 2, got ${JSON.stringify(every)}`)
  return { enabled: true, seats: words, every }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Persisted in $.store under STORE_KEY, shared across sessions (read-merge-write). */
export type Memory = {
  /** Topics already shown, any answer. Newest last. */
  readonly seen: readonly string[]
  /** Topics the person said they knew. Newest last. */
  readonly known: readonly string[]
  /** Notes the person typed past, in a row. */
  readonly typedPastInARow: number
  /** Checks still to skip because of typedPastInARow. */
  readonly looksToSkip: number
}
export const EMPTY_MEMORY: Memory = { seen: [], known: [], typedPastInARow: 0, looksToSkip: 0 }

/** Whatever the store holds -> Memory; a field off its shape takes the empty value. */
export function parseMemory(raw: unknown): Memory {
  if (!isRecord(raw)) return EMPTY_MEMORY
  const topics = (value: unknown): string[] => (Array.isArray(value) && value.every(item => typeof item === 'string') ? value : [])
  const count = (value: unknown): number => (typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : 0)
  return { seen: topics(raw.seen), known: topics(raw.known), typedPastInARow: count(raw.typedPastInARow), looksToSkip: count(raw.looksToSkip) }
}

const fold = (topic: string) => topic.trim().toLowerCase()

// Each topic once by its folded form, the later copy kept, then the newest TOPIC_CAP.
function newestUnique(topics: readonly string[]): string[] {
  const kept = topics.filter((topic, at) => !topics.slice(at + 1).some(later => fold(later) === fold(topic)))
  return kept.slice(-TOPIC_CAP)
}

// Appends a topic not yet held; a held one stays where it is, so a second press changes nothing.
function withTopic(topics: readonly string[], topic: string): readonly string[] {
  return topics.some(held => fold(held) === fold(topic)) ? topics : [...topics, topic].slice(-TOPIC_CAP)
}

/** Two sessions wrote at once: lists are union-merged newest last and capped, counters are ours. */
export function mergeMemory(stored: Memory, ours: Memory): Memory {
  return { ...ours, seen: newestUnique([...stored.seen, ...ours.seen]), known: newestUnique([...stored.known, ...ours.known]) }
}

export type Answer = 'learn' | 'tell' | 'knew' | 'dismiss' | 'typed-past'

/**
 * The builtin's transitions:
 * - any press: typedPastInARow = 0, looksToSkip = 0; the topic joins seen (and known on 'knew')
 * - typed-past: typedPastInARow += 1, looksToSkip = typedPastInARow; the topic joins seen
 * 'learn' and 'tell' are one note's two presses; the lists take the topic once.
 * Idempotent on the lists (dedupe by case-folded topic); the shell applies it once per note id.
 */
export function applyAnswer(m: Memory, topic: string, a: Answer): Memory {
  const seen = withTopic(m.seen, topic)
  if (a === 'typed-past') return { ...m, seen, typedPastInARow: m.typedPastInARow + 1, looksToSkip: m.typedPastInARow + 1 }
  return { seen, known: a === 'knew' ? withTopic(m.known, topic) : m.known, typedPastInARow: 0, looksToSkip: 0 }
}

/** The runner's `avoid.txt`: seen and known, one per line, for the prompt's AVOID slot. */
export function avoidList(m: Memory): string {
  const topics = [...m.seen, ...m.known].filter((topic, at, all) => all.findIndex(other => fold(other) === fold(topic)) === at)
  return topics.map(topic => `${topic}\n`).join('')
}

export const FRESH_SESSION: Session = { turnBase: null, offeredTurn: null, phase: { kind: 'idle' }, pendingContext: null }

/** What turn.step carries that the rules read: the turn, and the conversation's message count at this step. */
export type StepFacts = { turnId: string; index: number; messageCount: number }

/** Every decision carries the session to write; the caller persists it when it differs. */
export type Decision =
  | { kind: 'skip'; why: 'disabled' | 'off-cadence' | 'showing' | 'checking' | 'offered-this-turn'; session: Session }
  | { kind: 'skip'; why: 'backoff'; session: Session; memory: Memory }
  | { kind: 'launch'; checkId: string; session: Session }

/**
 * The builtin's rules in order. A step whose turn differs from turnBase starts
 * a turn: turnBase = {turnId, messageCount}. The message index within the turn
 * is messageCount - turnBase.messageCount; the check fires when it is a
 * positive multiple of every. Backoff consumes one looksToSkip and returns the
 * memory to write. A launch does not stamp offeredTurn: a NONE result leaves
 * later cadence points of the turn free; `checking` alone stops overlap.
 */
export function decide(cfg: HeadsUpConfig, s: Session, m: Memory, e: StepFacts, nowMs: number): Decision {
  if (!cfg.enabled) return { kind: 'skip', why: 'disabled', session: s }
  const turnBase = s.turnBase?.turnId === e.turnId ? s.turnBase : { turnId: e.turnId, messageCount: e.messageCount }
  const session: Session = turnBase === s.turnBase ? s : { ...s, turnBase }
  const index = e.messageCount - turnBase.messageCount
  if (index <= 0 || index % cfg.every !== 0) return { kind: 'skip', why: 'off-cadence', session }
  if (session.phase.kind === 'showing') return { kind: 'skip', why: 'showing', session }
  if (session.phase.kind === 'checking') return { kind: 'skip', why: 'checking', session }
  if (session.offeredTurn === e.turnId) return { kind: 'skip', why: 'offered-this-turn', session }
  if (m.looksToSkip > 0) return { kind: 'skip', why: 'backoff', session, memory: { ...m, looksToSkip: m.looksToSkip - 1 } }
  return { kind: 'launch', checkId: `check-${nowMs}`, session }
}

export type SeatOutcome = {
  readonly seat: string
  readonly outcome: 'none' | 'note' | 'error' | 'timeout'
  readonly elapsedMs: number
  readonly detail?: string
}

/** result.json, read once at the boundary into this. */
export type RunResult =
  | { kind: 'note'; note: Note; seats: readonly SeatOutcome[] }
  | { kind: 'none'; payloadBytes: number; seats: readonly SeatOutcome[] }
  | { kind: 'failed'; payloadBytes: number; seats: readonly SeatOutcome[] }

/**
 * Wire shape: {kind, bytes, seat?, ms?, topic?, headline?, detail?, seats:[{seat,outcome,ms,detail?}]}.
 * A text that does not parse to it is `failed` naming the text, so a runner
 * change can never read as "no note". A headline is cut to HEADLINE_CHARS, one line.
 */
export function parseRunResult(checkId: string, text: string): RunResult {
  const unread: RunResult = {
    kind: 'failed', payloadBytes: 0,
    seats: [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail: `result.json does not read as a run result: ${JSON.stringify(cut(text, UNREAD_CHARS))}` }],
  }
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return unread
  }
  if (!isRecord(raw) || !isCount(raw.bytes) || !Array.isArray(raw.seats)) return unread
  const seats = raw.seats.map(seatOutcome)
  if (!seats.every((seat): seat is SeatOutcome => seat !== undefined)) return unread
  if (raw.kind === 'none') return { kind: 'none', payloadBytes: raw.bytes, seats }
  if (raw.kind === 'failed') {
    // A failure before any seat ran (no transcript, an empty digest) names its
    // reason at the top level; it is read as the runner's own outcome.
    const runner: SeatOutcome[] = typeof raw.detail === 'string' && raw.detail !== '' ? [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail: raw.detail }] : []
    return { kind: 'failed', payloadBytes: raw.bytes, seats: [...runner, ...seats] }
  }
  if (raw.kind !== 'note') return unread
  const { seat, ms, topic, headline, detail } = raw
  if (typeof seat !== 'string' || !isCount(ms) || typeof topic !== 'string' || typeof headline !== 'string' || typeof detail !== 'string') return unread
  const note: Note = {
    id: checkId, seat, payloadBytes: raw.bytes, elapsedMs: ms,
    topic: topic.trim().slice(0, TOPIC_CHARS),
    headline: cut(headline.replace(/\s+/g, ' ').trim(), HEADLINE_CHARS),
    detail: detail.trim().slice(0, DETAIL_CHARS),
  }
  if (note.topic === '' || note.headline === '') return unread
  return { kind: 'note', note, seats }
}

// How much of an unreadable result.json its failure quotes.
const UNREAD_CHARS = 200

// Cut to at most `chars`, the last one an ellipsis when anything was left out.
function cut(text: string, chars: number): string {
  return text.length <= chars ? text : `${text.slice(0, chars - 1)}…`
}

function isCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
}

const OUTCOMES: readonly SeatOutcome['outcome'][] = ['none', 'note', 'error', 'timeout']

function seatOutcome(raw: unknown): SeatOutcome | undefined {
  if (!isRecord(raw) || typeof raw.seat !== 'string' || !isCount(raw.ms)) return undefined
  const outcome = OUTCOMES.find(known => known === raw.outcome)
  if (!outcome) return undefined
  if (raw.detail === undefined) return { seat: raw.seat, outcome, elapsedMs: raw.ms }
  return typeof raw.detail === 'string' ? { seat: raw.seat, outcome, elapsedMs: raw.ms, detail: raw.detail } : undefined
}

/** A seat repeated a topic in seen or known anyway (case-folded, trimmed). */
export function isRepeat(m: Memory, topic: string): boolean {
  return [...m.seen, ...m.known].some(held => fold(held) === fold(topic))
}

/**
 * The poller's transition. A note stamps offeredTurn with the turn the check
 * was launched in, so one landing after its turn ended counts against the
 * right turn; a repeat, none or failed returns to idle. Not checking -> unchanged.
 */
export function settle(s: Session, m: Memory, r: RunResult): Session {
  if (s.phase.kind !== 'checking') return s
  if (r.kind === 'note' && !isRepeat(m, r.note.topic)) return { ...s, offeredTurn: s.phase.turnId, phase: { kind: 'showing', note: r.note, expanded: false } }
  return { ...s, phase: { kind: 'idle' } }
}

/** A person's own prompt while a note shows: the note goes; the caller records typed-past in memory. */
export function typedPast(s: Session): Session {
  return s.phase.kind === 'showing' ? { ...s, phase: { kind: 'idle' } } : s
}

/**
 * A press. learn: the band expands and stays; tell: the context is armed and
 * the band closes; knew, dismiss and a close from the expanded band: idle.
 */
export function pressed(s: Session, a: Exclude<Answer, 'typed-past'>): Session {
  if (s.phase.kind !== 'showing') return s
  if (a === 'learn') return { ...s, phase: { ...s.phase, expanded: true } }
  if (a === 'tell') return { ...s, phase: { kind: 'idle' }, pendingContext: learnMoreContext(s.phase.note) }
  return { ...s, phase: { kind: 'idle' } }
}

/** What the band draws; null yields to the next hook. */
export type BandView = {
  /** "✦ Heads up · <headline>" */
  readonly headline: string
  /** "codex · 12.4 KB · 27 s" */
  readonly meta: string
  /** Non-null once expanded; the band then offers tell Claude and close instead of the three choices. */
  readonly detail: string | null
}
export function bandView(p: Phase): BandView | null {
  if (p.kind !== 'showing') return null
  const { note } = p
  return {
    headline: `✦ Heads up · ${note.headline}`,
    meta: `${note.seat} · ${kilobytes(note.payloadBytes)} · ${seconds(note.elapsedMs)}`,
    detail: p.expanded ? note.detail : null,
  }
}

const seconds = (ms: number) => `${Math.round(ms / 1000)} s`

/** One line per finished check, drawn or not: "heads-up: codex · none · 12.4 KB · 27 s". */
export function checkLine(r: RunResult): string {
  if (r.kind === 'note') return `heads-up: ${r.note.seat} · note · ${kilobytes(r.note.payloadBytes)} · ${seconds(r.note.elapsedMs)}`
  if (r.kind === 'none') {
    const ms = r.seats.reduce((total, seat) => total + seat.elapsedMs, 0)
    return `heads-up: ${r.seats.map(seat => seat.seat).join(', ')} · none · ${kilobytes(r.payloadBytes)} · ${seconds(ms)}`
  }
  const reasons = r.seats.map(seat => `${seat.seat} ${seat.outcome} after ${seconds(seat.elapsedMs)}${seat.detail ? `: ${seat.detail}` : ''}`)
  return `heads-up: failed · ${kilobytes(r.payloadBytes)} · ${reasons.join('; ')}`
}

/** "The user opened a side-check note (from codex, not from you): <headline>\n<detail>" */
export function learnMoreContext(n: Note): string {
  const opened = `The user opened a side-check note (from ${n.seat}, not from you): ${n.headline}`
  return n.detail === '' ? opened : `${opened}\n${n.detail}`
}

/** "12.4 KB" style, one decimal. */
export function kilobytes(bytes: number): string {
  return `${(bytes / 1024).toFixed(1)} KB`
}
