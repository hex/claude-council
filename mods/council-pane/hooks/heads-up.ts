// ABOUTME: Pure policy for the heads-up side-check: cadence, backoff, memory, the runner's result and the band's words
// ABOUTME: No engine calls, so every rule runs under bun test; pane.tsx is the shell that feeds events in

import type { Note, Phase, Session, Tag } from '../types'
import { isRecord } from './json'

/** Fire when the message index within the turn is a positive multiple of this; the builtin's number. */
export const DEFAULT_EVERY = 3
/** seen and known each keep this many topics, newest last; the builtin's cap. */
export const TOPIC_CAP = 50
export const TOPIC_CHARS = 140
export const TITLE_CHARS = 80
export const POINT_CHARS = 200
export const MAX_POINTS = 6
export const HEADLINE_CHARS = 200
/** A seat name becomes a script path in the runner, so it is only ever a plain word here. */
const SEAT_SHAPE = /^[a-z][a-z0-9-]+$/

export const CONFIG_FILE = '.claude/council-heads-up.json'
export const STORE_KEY = 'heads-up'
export const COUNTS_KEY = 'heads-up-counts'
export const INTRO_KEY = 'heads-up-intro-shown'
export const COMMAND = 'heads-up'

/** The seat's picks: the model goes to its *_MODEL variable, the effort to codex's -c flag; other seats ignore it. */
export type SeatPick = { readonly model?: string; readonly effort?: string }

/** The effective setting. Only parseConfig builds one; `seat` is a shape-checked word, the runner owns the allowlist. */
export type HeadsUpConfig =
  | { enabled: true; seat: string; every: number; model?: SeatPick }
  | { enabled: false; problem?: string }

const DEFAULT_SEAT = 'codex'
const EFFORT_SHAPE = /^[a-z]+$/

/**
 * Two switches, the /config row and the project file: on when the file says
 * `enabled: true`, or when the row is on and the file does not say
 * `enabled: false`. The file's seat, model and every apply either way. Malformed
 * JSON, a non-object, an `enabled` that is not a boolean, a seat that is not a
 * plain word, a `seats` or `models` key, or an `every` below 2 -> off with a
 * problem the shell logs once, whatever the row says: a side-agent that never
 * fires should say why. An empty `model` reads as no pick.
 */
export function parseConfig(text: string | undefined, rowOn: boolean): HeadsUpConfig {
  if (text === undefined) return rowOn ? { enabled: true, seat: DEFAULT_SEAT, every: DEFAULT_EVERY } : { enabled: false }
  const off = (why: string): HeadsUpConfig => ({ enabled: false, problem: `${CONFIG_FILE}${why}; heads-up is off` })
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return off(' is not valid JSON')
  }
  if (!isRecord(raw)) return off(' must hold a JSON object')
  if (raw.enabled !== undefined && typeof raw.enabled !== 'boolean') return off(': enabled must be true or false')
  if (raw.seats !== undefined) return off(': seats is not a key; one seat goes under "seat"')
  if (raw.models !== undefined) return off(': models is not a key; the seat\'s pick goes under "model"')
  const seat = raw.seat ?? DEFAULT_SEAT
  if (typeof seat !== 'string' || !SEAT_SHAPE.test(seat)) return off(`: seat ${JSON.stringify(seat)} is not a plain lowercase word`)
  const every = raw.every ?? DEFAULT_EVERY
  if (typeof every !== 'number' || !Number.isInteger(every) || every < 2) return off(`: every must be a whole number of at least 2, got ${JSON.stringify(every)}`)
  let model: SeatPick | undefined
  if (raw.model !== undefined) {
    const pick = raw.model
    if (!isRecord(pick)) return off(': model must be an object of {model, effort}')
    if (pick.model !== undefined && typeof pick.model !== 'string') return off(`: model for ${seat} must be a string, got ${JSON.stringify(pick.model)}`)
    if (pick.effort !== undefined && (typeof pick.effort !== 'string' || !EFFORT_SHAPE.test(pick.effort))) return off(`: effort for ${seat} must be lowercase letters, got ${JSON.stringify(pick.effort)}`)
    if (pick.model !== undefined || pick.effort !== undefined) model = { ...(pick.model === undefined ? {} : { model: pick.model }), ...(pick.effort === undefined ? {} : { effort: pick.effort }) }
  }
  if (raw.enabled === false || (raw.enabled === undefined && !rowOn)) return { enabled: false }
  return { enabled: true, seat, every, ...(model === undefined ? {} : { model }) }
}

/**
 * Usage on this machine, in $.store under COUNTS_KEY, shared by every
 * session. Each bump reads, adds one and writes, so two sessions bumping at
 * once can lose one; the numbers guide a decision, they are not billing.
 */
export type Counts = {
  readonly none: number
  readonly notes: number
  /** A seat's note on a topic already seen or known: nothing drawn. */
  readonly repeats: number
  readonly failed: number
  readonly learn: number
  readonly tell: number
  readonly knew: number
  readonly understood: number
  readonly dismiss: number
  readonly turnOff: number
  readonly typedPast: number
}
export const COUNT_KEYS = ['none', 'notes', 'repeats', 'failed', 'learn', 'tell', 'knew', 'understood', 'dismiss', 'turnOff', 'typedPast'] as const
export const EMPTY_COUNTS: Counts = { none: 0, notes: 0, repeats: 0, failed: 0, learn: 0, tell: 0, knew: 0, understood: 0, dismiss: 0, turnOff: 0, typedPast: 0 }

export function parseCounts(raw: unknown): Counts {
  if (!isRecord(raw)) return EMPTY_COUNTS
  return Object.fromEntries(COUNT_KEYS.map(key => [key, countOr0(raw[key])])) as Record<keyof Counts, number>
}

export function bumped(c: Counts, ...keys: (keyof Counts)[]): Counts {
  return keys.reduce((counts, key) => ({ ...counts, [key]: counts[key] + 1 }), c)
}

/** "checks 12 · none 8 · notes 2 · repeats 1 · failed 1": checks is the outcomes added up, so it cannot drift from them. */
export function countsLine(c: Counts): string {
  return `checks ${c.none + c.notes + c.repeats + c.failed} · none ${c.none} · notes ${c.notes} · repeats ${c.repeats} · failed ${c.failed}`
}

/** "learn 2 · tell 1 · knew 0 · understood 1 · dismiss 1 · turned off 0 · typed past 3" */
export function pressesLine(c: Counts): string {
  return `learn ${c.learn} · tell ${c.tell} · knew ${c.knew} · understood ${c.understood} · dismiss ${c.dismiss} · turned off ${c.turnOff} · typed past ${c.typedPast}`
}

export type HeadsUpCommand =
  | { action: 'status' }
  | { action: 'on'; seat?: string }
  | { action: 'off' }
  | { action: 'setup' }
  | { action: 'unknown'; why: string }

/**
 * The /heads-up argument: nothing or status shows the state; on, with the
 * one seat to ask or none to keep the file's, and off write the project file.
 * The seat is checked here as the file's is; two seats are refused.
 */
export function headsUpCommand(args: string): HeadsUpCommand {
  const [word = '', ...rest] = args.trim().toLowerCase().split(/[\s,]+/).filter(part => part !== '')
  if (word === '' || word === 'status') return { action: 'status' }
  if (word === 'off') return rest.length === 0 ? { action: 'off' } : { action: 'unknown', why: 'off takes no words' }
  if (word === 'setup') return rest.length === 0 ? { action: 'setup' } : { action: 'unknown', why: 'setup takes no words' }
  if (word !== 'on') return { action: 'unknown', why: `unknown word ${JSON.stringify(word)}` }
  if (rest.length > 1) return { action: 'unknown', why: `on takes one seat, got ${rest.length}: ${rest.join(', ')}` }
  const [seat] = rest
  if (seat === undefined) return { action: 'on' }
  if (!SEAT_SHAPE.test(seat)) return { action: 'unknown', why: `seat ${JSON.stringify(seat)} is not a plain lowercase word` }
  return { action: 'on', seat }
}

/**
 * The project file with `enabled` set (or dropped, so the row decides) and,
 * when given, the seat, cadence and pick; its other fields kept. A pick
 * belongs to its seat, so a different seat drops the file's `model`; an empty
 * `model` is never written. A missing or unreadable file starts over. One
 * line of JSON, as the docs show it.
 */
export function withEnabled(text: string | undefined, on: boolean | undefined, seat?: string, every?: number, model?: SeatPick): string {
  let kept: Record<string, unknown> = {}
  if (text !== undefined) {
    try {
      const raw: unknown = JSON.parse(text)
      if (isRecord(raw)) kept = raw
    } catch {
      kept = {}
    }
  }
  // The keys parseConfig refuses go too, so a write always leaves a file that reads.
  const { enabled: _dropped, seats: _seats, models: _models, ...rest } = kept
  if (seat !== undefined) {
    if (seat !== (rest.seat ?? DEFAULT_SEAT)) delete rest.model
    rest.seat = seat
  }
  if (every !== undefined) rest.every = every
  if (model !== undefined) rest.model = model
  if (isRecord(rest.model) && Object.keys(rest.model).length === 0) delete rest.model
  const json = (value: unknown): string => {
    if (Array.isArray(value)) return `[${value.map(item => JSON.stringify(item)).join(', ')}]`
    if (isRecord(value)) return `{${Object.entries(value).map(([key, item]) => `${JSON.stringify(key)}: ${json(item)}`).join(', ')}}`
    return JSON.stringify(value)
  }
  const entries = Object.entries(on === undefined ? rest : { enabled: on, ...rest }).map(([key, value]) => `${JSON.stringify(key)}: ${json(value)}`)
  return `{${entries.join(', ')}}\n`
}

/**
 * What /heads-up status prints: a headline with the effective state, then one
 * aligned row per fact: which switch set it, the seat and cadence, the counts
 * kept on this machine.
 */
export function statusText(config: HeadsUpConfig, rowOn: boolean, fileText: string | undefined, counts: Counts): string {
  const row = rowOn ? 'on' : 'off'
  const file = fileText === undefined ? undefined : fileEnabled(fileText)
  const fileNote = fileText === undefined ? `no ${CONFIG_FILE} here` : `${CONFIG_FILE} leaves it to the row`
  const rows: [string, string][] = []
  let state: string
  if (!config.enabled && config.problem !== undefined) {
    state = 'off'
    rows.push(['problem', config.problem])
  } else if (config.enabled) {
    state = file === true ? 'on for this project' : 'on for every project'
    rows.push(['by', file === true ? `${CONFIG_FILE} (the /config row is ${row})` : `the /config row (${fileNote})`])
    rows.push(['seat', seatLabel(config.seat, config.model)], ['every', `${config.every} requests`])
  } else if (file === false) {
    state = 'off for this project'
    rows.push(['by', `${CONFIG_FILE} (the /config row is ${row})`], ['turn on', `/${COMMAND} on [seat] turns it on here`])
  } else {
    state = 'off'
    rows.push(['by', `the /config row is off, ${fileNote}`], ['turn on', `/${COMMAND} on [seat] for this project, the /config row "Heads-up side-check" for every project`])
  }
  rows.push(['checks', countsLine(counts)], ['presses', pressesLine(counts)])
  const width = Math.max(...rows.map(([label]) => label.length))
  return [`Heads-up side-check: ${state}`, ...rows.map(([label, value]) => `  ${label.padEnd(width)}  ${value}`)].join('\n')
}

/**
 * The status on one line for a toast: its first line, then the seat, cadence
 * and checks rows joined with dots; the presses and the switch stay out. A
 * command typed while a turn runs gets its reply drawn only when the turn
 * ends, so the toast is what the person sees at once.
 */
export function toastLine(status: string): string {
  const [head = '', ...rows] = status.split('\n')
  const kept = new Set(['seat', 'every', 'checks'])
  const parts = rows
    .map(row => row.trim().split(/\s{2,}/, 2))
    .flatMap(([label, value]) => label !== undefined && value !== undefined && kept.has(label) ? [label === 'every' ? `every ${value}` : value] : [])
  return [head, ...parts].join(' · ')
}

/** The /heads-up setup dialogs: scope, seat, cadence. */
export const SCOPE = { project: 'This project', all: 'Every project', off: 'Off for this project' } as const
export const SCOPE_QUESTION = 'Where should the heads-up side-check run?'
export const SEAT_QUESTION = 'Which seat should reread the turn?'
export const EVERY_QUESTION = 'How often should a long turn be checked?'
export const EVERY_LABELS = ['Every 3 requests', 'Every 6 requests', 'Every 9 requests'] as const

/**
 * The seats discover_providers printed, the council's own test for what is set
 * up here: codex first, and the router's numbered seats as the one seat they
 * share a script with.
 */
export function seatsFromDiscovery(stdout: string): string[] {
  const seats = [...new Set(stdout.split(/\s+/).filter(name => name !== '').map(name => (/^openrouter-\d+$/.test(name) ? 'openrouter' : name)))]
  return seats.includes(DEFAULT_SEAT) ? [DEFAULT_SEAT, ...seats.filter(seat => seat !== DEFAULT_SEAT)] : seats
}

/** The dialog takes two to four options; the person types any other seat under Other. */
export function seatOptions(available: readonly string[]): string[] {
  const picks = available.slice(0, 4)
  return picks.length >= 2 ? picks : ['codex', 'gemini']
}

/** The dialog's answer: one label, or a typed seat name. */
export function seatFromAnswer(answer: string): { seat: string } | { why: string } {
  const words = answer.toLowerCase().split(/[\s,]+/).filter(part => part !== '')
  const [seat] = words
  if (seat === undefined) return { why: 'no seat named' }
  if (words.length > 1) return { why: `one seat, got ${words.length}: ${words.join(', ')}` }
  return SEAT_SHAPE.test(seat) ? { seat } : { why: `seat ${JSON.stringify(seat)} is not a plain lowercase word` }
}

export function everyFromAnswer(answer: string): { every: number } | { why: string } {
  const digits = /^(?:every\s+)?(\d+)(?:\s+requests?)?$/i.exec(answer.trim())
  const every = digits === null ? NaN : Number(digits[1])
  return Number.isInteger(every) && every >= 2 ? { every } : { why: `every must be a whole number of at least 2, got ${JSON.stringify(answer.trim())}` }
}

export const MODEL_QUESTION = (seat: string) => `Which model should ${seat} use?`
export const EFFORT_QUESTION = 'How hard should codex think?'
const KEEP = 'Keep '
const TYPE_ONE = 'Type a model id under Other'

/** The current model first; then the catalog's others, four in all; or a prompt to type one. */
export function modelOptions(current: string, catalog: readonly string[] | undefined): string[] {
  const keep = `${KEEP}${current}`
  if (catalog === undefined || catalog.length === 0) return [keep, TYPE_ONE]
  return [keep, ...catalog.filter(slug => slug !== current)].slice(0, 4)
}

/** The chosen model, or undefined to keep the provider's own. */
export function modelFromAnswer(answer: string): string | undefined {
  const text = answer.trim()
  return text === '' || text.startsWith(KEEP) || text === TYPE_ONE ? undefined : text
}

export function effortOptions(efforts: readonly string[], defaultEffort: string): string[] {
  const others = efforts.filter(effort => effort !== defaultEffort)
  if (defaultEffort === '') return (others.length > 0 ? others : ['low', 'medium', 'high', 'xhigh']).slice(0, 4)
  return [`${defaultEffort} (default)`, ...others].slice(0, 4)
}

/** The chosen effort, {} to keep codex's default, or why the answer is unusable. */
export function effortFromAnswer(answer: string): { effort?: string } | { why: string } {
  const text = answer.trim()
  if (text.endsWith(' (default)')) return {}
  return EFFORT_SHAPE.test(text) ? { effort: text } : { why: `effort must be lowercase letters, got ${JSON.stringify(text)}` }
}

/** What a check that found nothing leaves on the prompt hint: "heads-up: gemini read 8.5 KB in 11 s, nothing to flag". */
export function receiptLine(r: Extract<RunResult, { kind: 'none' }>): string {
  const ms = r.seats.reduce((total, seat) => total + seat.elapsedMs, 0)
  return `heads-up: ${r.seats.map(seat => seat.seat).join(', ')} read ${kilobytes(r.payloadBytes)} in ${seconds(ms)}, nothing to flag`
}

/** "codex (gpt-6.1-sol, high)", "gemini (gemini-2.5-pro)", or the bare name. */
export function seatLabel(seat: string, pick: SeatPick | undefined): string {
  const parts = [pick?.model, pick?.effort].filter((part): part is string => part !== undefined && part !== '')
  return parts.length === 0 ? seat : `${seat} (${parts.join(', ')})`
}

/** The runner's --model file: the seat's pick, '' when there is none. */
export function modelFile(config: Extract<HeadsUpConfig, { enabled: true }>): string {
  return config.model === undefined ? '' : JSON.stringify(config.model)
}

// The file's own `enabled`, when it parses; undefined when absent or not a boolean.
function fileEnabled(text: string): boolean | undefined {
  try {
    const raw: unknown = JSON.parse(text)
    return isRecord(raw) && typeof raw.enabled === 'boolean' ? raw.enabled : undefined
  } catch {
    return undefined
  }
}

/**
 * The once-per-install introduction: a dim tail on the prompt's hint line
 * while the prompt is empty, only while the check is off; marked shown either
 * way so it never repeats on this machine.
 */
export function introTail(p: { shown: boolean; enabled: boolean }): { tail?: string; markShown: boolean } {
  if (p.shown) return { markShown: false }
  if (p.enabled) return { markShown: true }
  return { tail: `Tip: /${COMMAND} on lets another model watch long turns and flag what Claude missed`, markShown: true }
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
  return { seen: topics(raw.seen), known: topics(raw.known), typedPastInARow: countOr0(raw.typedPastInARow), looksToSkip: countOr0(raw.looksToSkip) }
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

export type Answer = 'learn' | 'tell' | 'knew' | 'understood' | 'dismiss' | 'turn-off' | 'typed-past'

/**
 * The builtin's transitions:
 * - any press: typedPastInARow = 0, looksToSkip = 0; the topic joins seen (and known on 'knew' or 'understood')
 * - typed-past: typedPastInARow += 1, looksToSkip = typedPastInARow; the topic joins seen
 * 'learn' and 'tell' are one note's two presses; the lists take the topic once.
 * 'turn-off' (the second press of the band's Turn off) is a dismiss here; the shell writes the file off.
 * Idempotent on the lists (dedupe by case-folded topic); the shell applies it once per note id.
 */
export function applyAnswer(m: Memory, topic: string, a: Answer): Memory {
  const seen = withTopic(m.seen, topic)
  if (a === 'typed-past') return { ...m, seen, typedPastInARow: m.typedPastInARow + 1, looksToSkip: m.typedPastInARow + 1 }
  return { seen, known: a === 'knew' || a === 'understood' ? withTopic(m.known, topic) : m.known, typedPastInARow: 0, looksToSkip: 0 }
}

/** The runner's `avoid.txt`: seen and known, one per line, for the prompt's AVOID slot. */
export function avoidList(m: Memory): string {
  const topics = [...m.seen, ...m.known].filter((topic, at, all) => all.findIndex(other => fold(other) === fold(topic)) === at)
  return topics.map(topic => `${topic}\n`).join('')
}

export const FRESH_SESSION: Session = { offeredTurn: null, phase: { kind: 'idle' } }

/** What turn.step carries that the rules read: the turn, and this request's position in it, from 0. */
export type StepFacts = { turnId: string; index: number }

/** The request's index in its turn is a positive multiple of every. */
export function onCadence(every: number, index: number): boolean {
  return index > 0 && index % every === 0
}

export type Decision =
  | { kind: 'skip'; why: 'disabled' | 'off-cadence' | 'showing' | 'checking' | 'offered-this-turn' }
  | { kind: 'skip'; why: 'backoff'; memory: Memory }
  | { kind: 'launch'; checkId: string }

/**
 * The builtin's rules in order. The check fires when the request's index in
 * its turn is a positive multiple of every (the engine's own count; the
 * conversation's messageCount is not a per-step fact, it grows by whatever the
 * request carries). Backoff consumes one looksToSkip and returns the memory to
 * write. A launch does not stamp offeredTurn: a NONE result leaves later
 * cadence points of the turn free; `checking` alone stops overlap.
 */
export function decide(cfg: HeadsUpConfig, s: Session, m: Memory, e: StepFacts, nowMs: number): Decision {
  if (!cfg.enabled) return { kind: 'skip', why: 'disabled' }
  if (!onCadence(cfg.every, e.index)) return { kind: 'skip', why: 'off-cadence' }
  if (s.phase.kind === 'showing') return { kind: 'skip', why: 'showing' }
  if (s.phase.kind === 'checking') return { kind: 'skip', why: 'checking' }
  if (s.offeredTurn === e.turnId) return { kind: 'skip', why: 'offered-this-turn' }
  if (m.looksToSkip > 0) return { kind: 'skip', why: 'backoff', memory: { ...m, looksToSkip: m.looksToSkip - 1 } }
  return { kind: 'launch', checkId: `check-${nowMs}` }
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
  /** The runner found nobody to warn (a transcript holding no prompt) and asked no seat. */
  | { kind: 'skipped'; detail: string }
  | { kind: 'failed'; payloadBytes: number; seats: readonly SeatOutcome[] }

/**
 * Wire shape: {kind, bytes, seat?, model?, ms?, tag?, topic?, headline?, title?, points?, detail?, seats:[{seat,outcome,ms,detail?}]}.
 * A skipped check carries only its detail: no seat ran and nothing left the machine.
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
  // A failure or skip before any seat ran names its reason at the top level.
  const detail = typeof raw.detail === 'string' && raw.detail !== '' ? raw.detail : undefined
  if (raw.kind === 'skipped') return detail === undefined ? unread : { kind: 'skipped', detail }
  if (raw.kind === 'failed') {
    // A failure before any seat ran (no transcript) is read as the runner's own outcome.
    const runner: SeatOutcome[] = detail === undefined ? [] : [{ seat: 'runner', outcome: 'error', elapsedMs: 0, detail }]
    return { kind: 'failed', payloadBytes: raw.bytes, seats: [...runner, ...seats] }
  }
  if (raw.kind !== 'note') return unread
  const { seat, ms, topic, headline, title, points } = raw
  if (typeof seat !== 'string' || !isCount(ms) || typeof topic !== 'string' || typeof headline !== 'string' || typeof title !== 'string') return unread
  if (!Array.isArray(points) || !points.every((point): point is string => typeof point === 'string')) return unread
  const note: Note = {
    id: checkId, tag: tagOf(raw.tag), seat, model: typeof raw.model === 'string' ? raw.model.trim() : '', payloadBytes: raw.bytes, elapsedMs: ms,
    topic: topic.trim().slice(0, TOPIC_CHARS),
    headline: cut(headline.replace(/\s+/g, ' ').trim(), HEADLINE_CHARS),
    title: plainLinks(title).trim().slice(0, TITLE_CHARS),
    points: points.map(point => plainLinks(point).trim().slice(0, POINT_CHARS)).filter(point => point !== '').slice(0, MAX_POINTS),
  }
  if (note.topic === '' || note.headline === '') return unread
  return { kind: 'note', note, seats }
}

// The band draws plain text, so a markdown link a seat wrote anyway becomes "text (address)".
const plainLinks = (text: string) => text.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '$1 ($2)')

// A seat's tag, case-folded; anything but the builtin's two reads as Heads up,
// the tag for this session's own work, which is what the check is asked for.
function tagOf(raw: unknown): Tag {
  return typeof raw === 'string' && raw.trim().toLowerCase() === 'you should know' ? 'You should know' : 'Heads up'
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

// A stored counter off its shape reads as 0.
const countOr0 = (value: unknown): number => (isCount(value) ? value : 0)

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
 * A press. learn: the band expands and stays; tell, knew, understood, dismiss and a close
 * from the expanded band: idle. The shell puts tell's draft in the prompt box.
 */
export function pressed(s: Session, a: Exclude<Answer, 'typed-past'>): Session {
  if (s.phase.kind !== 'showing') return s
  if (a === 'learn') return { ...s, phase: { ...s.phase, expanded: true } }
  return { ...s, phase: { kind: 'idle' } }
}

/** What the band draws; null yields to the next hook. */
export type BandView = {
  /** Drawn bold after the mark: "Heads up" or "You should know". */
  readonly tag: Tag
  /** The seat's sentence, after the tag and a dot. */
  readonly headline: string
  /** "codex · gpt-6.1-sol · 12.4 KB · 27 s"; the model is left out when the runner named none. */
  readonly meta: string
  /** Non-null once expanded: the bold title and the bullets, the last one the action; the band then offers Understood, Tell Claude and Close instead of the three choices. */
  readonly more: { readonly title: string; readonly points: readonly string[] } | null
  /** The note's id, so the shell knows whether its armed Turn off belongs to this note. */
  readonly id: string
}
/** The band's mark for a tag: a badge of one ASCII letter on Claude's orange, drawn on every terminal. */
export function tagMark(tag: Tag): '!' | '?' {
  return tag === 'Heads up' ? '!' : '?'
}

export function bandView(p: Phase): BandView | null {
  if (p.kind !== 'showing') return null
  const { note } = p
  return {
    tag: note.tag,
    headline: note.headline,
    meta: [note.seat, note.model, kilobytes(note.payloadBytes), seconds(note.elapsedMs)].filter(part => part !== '').join(' · '),
    more: p.expanded ? { title: note.title, points: note.points } : null,
    id: note.id,
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
  if (r.kind === 'skipped') return `heads-up: skipped · ${r.detail}`
  const reasons = r.seats.map(seat => `${seat.seat} ${seat.outcome} after ${seconds(seat.elapsedMs)}${seat.detail ? `: ${seat.detail}` : ''}`)
  return `heads-up: failed · ${kilobytes(r.payloadBytes)} · ${reasons.join('; ')}`
}

/**
 * The draft tell Claude puts in the prompt box, for the person to send or
 * edit: the main agent learns of a note only through the person's own prompt.
 * The headline opens, the title and bullets follow as a list, and the close
 * asks for a check before any action: a Heads up is a claim to verify, a
 * You should know is a fact to weigh against the plan.
 */
export function tellClaudeDraft(n: Note): string {
  const raised = `A side check by ${n.seat} (not you) flagged this: ${n.headline}`
  const more = [n.title, ...n.points.map(point => `- ${point}`)].filter(part => part !== '').join('\n')
  const close = n.tag === 'Heads up'
    ? `Treat this as a claim, not a conclusion. Before continuing: verify it against the evidence, report what you find, and only then act on ${n.points.length === 0 ? 'it' : 'the last bullet'}.`
    : 'Take this into account before continuing and say whether it changes your plan.'
  return [raised, more, close].filter(part => part !== '').join('\n\n')
}

/** "12.4 KB" style, one decimal. */
export function kilobytes(bytes: number): string {
  return `${(bytes / 1024).toFixed(1)} KB`
}
