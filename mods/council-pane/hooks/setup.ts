// ABOUTME: Pure decisions for the specialist setup screen: Codex's model catalog, one validator, entries and drafts
// ABOUTME: No engine calls here, so every rule runs under bun test
import { nameProblem, parseSpecialist, WHEN_MAX, type Specialist } from './specialist'
import { EFFORT_STYLE, SWATCHES, type Style } from './theme'

// effortHelp is Codex's own one-line description of each effort; defaultEffort
// is what the model uses when nothing sets one.
export type CatalogModel = { slug: string; listed: boolean; efforts: string[]; effortHelp: Record<string, string>; defaultEffort: string }
export type Catalog = { models: CatalogModel[] } | { error: string }
// The screen opens before the catalog arrives, so loading is a state of its own.
export type CatalogState = Catalog | { loading: true }

const CATALOG = 'codex debug models'

export function parseCatalog(run: { exitCode: number; stdout: string; stderr: string }): Catalog {
  if (run.exitCode !== 0) return { error: run.stderr.split('\n')[0]?.trim() || `${CATALOG} exited ${run.exitCode}` }
  let data: unknown
  try { data = JSON.parse(run.stdout) } catch { return { error: `${CATALOG} printed something that is not JSON` } }
  const list = (data as { models?: unknown }).models
  if (!Array.isArray(list) || list.length === 0) return { error: `${CATALOG} printed no models list` }
  const models: CatalogModel[] = []
  for (const entry of list as Record<string, unknown>[]) {
    if (typeof entry.slug !== 'string' || entry.slug === '') return { error: `${CATALOG}: a model has no slug` }
    const levels = entry.supported_reasoning_levels
    if (!Array.isArray(levels)) return { error: `${CATALOG}: model '${entry.slug}' has no supported_reasoning_levels` }
    const efforts: string[] = []
    const effortHelp: Record<string, string> = {}
    for (const level of levels as { effort?: unknown; description?: unknown }[]) {
      if (typeof level.effort !== 'string') continue
      efforts.push(level.effort)
      if (typeof level.description === 'string') effortHelp[level.effort] = level.description
    }
    const defaultEffort = typeof entry.default_reasoning_level === 'string' ? entry.default_reasoning_level : ''
    models.push({ slug: entry.slug, listed: entry.visibility === 'list', efforts, effortHelp, defaultEffort })
  }
  return { models }
}

// The form's fields as typed; a blank effort or instructions is left out of the entry.
export type Fields = { name: string; model: string; effort: string; when: string; instructions: string }

function entryOf(f: Fields): Specialist {
  return { name: f.name, model: f.model, ...(f.effort ? { effort: f.effort } : {}), when: f.when, ...(f.instructions.trim() ? { instructions: f.instructions } : {}) }
}

// The stored entry as text, so a draft can tell whether it changed meanwhile.
function entryKey(entry: unknown): string {
  return entry === undefined ? '' : JSON.stringify(entry)
}

// The fields a user types are checked here first, so each error names its field;
// the entry then goes through parseSpecialist, the same reader session start uses.
export function checkSpecialist(f: Fields, index: number, context: { models: CatalogModel[]; entries: unknown[] }): { entry: Specialist } | { error: string } {
  if (f.name.trim() === '') return { error: 'name is empty' }
  const badName = nameProblem(f.name)
  if (badName) return { error: badName }
  if (f.when.trim() === '') return { error: 'use-when is empty' }
  const model = context.models.find(m => m.slug === f.model)
  if (!model) return { error: `model '${f.model}' is not in Codex's catalog: ${context.models.filter(m => m.listed).map(m => m.slug).join(', ')}` }
  if (f.effort && !model.efforts.includes(f.effort)) return { error: `effort '${f.effort}' is not offered by ${model.slug}: ${model.efforts.join(', ')}` }
  const parsed = parseSpecialist(entryOf(f))
  if ('error' in parsed) return parsed
  const taken = context.entries.findIndex((other, at) => {
    if (at === index) return false
    const theirs = parseSpecialist(other)
    return !('error' in theirs) && theirs.name === parsed.name
  })
  if (taken !== -1) return { error: `name '${parsed.name}' is already used by specialist ${taken + 1}` }
  return { entry: parsed }
}

// A save puts the entry at its index, which one past the end appends; a remove drops it.
export function putEntry<T>(entries: T[], index: number, entry: T): T[] {
  return index >= entries.length ? [...entries, entry] : entries.map((existing, at) => (at === index ? entry : existing))
}

// A new specialist goes after whatever the newest list holds; an edited one
// keeps its place, which the stale check has already vouched for.
export function saveIndex(draft: Draft, entries: unknown[]): number {
  return draft.baseline === '' ? entries.length : draft.index
}

export function dropEntry<T>(entries: T[], index: number): T[] {
  return entries.filter((_, at) => at !== index)
}

// index: the entry's place in the list, or the list's length for a new one.
// baseline: the stored entry as JSON when editing started, to spot a change made meanwhile.
export type Draft = Fields & { index: number; baseline: string }
export type Status = { kind: 'saved' | 'error' | 'note'; text: string }
// A question the screen asks inline before an action it cannot undo.
export type Confirm = { kind: 'remove' } | { kind: 'switch'; target: number | 'new' }
export type SetupState = { draft?: Draft; catalog: CatalogState; status?: Status; confirm?: Confirm }

const fieldsOf = (s: Specialist): Fields => ({ name: s.name, model: s.model, effort: s.effort ?? '', when: s.when, instructions: s.instructions ?? '' })

// An entry that does not parse opens as a blank draft on the first listed model,
// so the model the screen shows is the one a Save writes.
export function draftFor(index: number, entries: unknown[], models: CatalogModel[]): Draft {
  const baseline = entryKey(entries[index])
  const parsed = parseSpecialist(entries[index])
  if ('error' in parsed) return { ...blankDraft(index, models), baseline }
  return { index, baseline, ...fieldsOf(parsed) }
}

export function blankDraft(index: number, models: CatalogModel[], prefill: Partial<Fields> = {}): Draft {
  const model = models.find(m => m.listed)?.slug ?? ''
  return { index, baseline: '', name: '', model, effort: '', when: '', instructions: '', ...prefill }
}

export function withModel(draft: Draft, slug: string, models: CatalogModel[]): { draft: Draft; message: string } {
  const offered = models.find(m => m.slug === slug)?.efforts ?? []
  if (draft.effort === '' || offered.includes(draft.effort)) return { draft: { ...draft, model: slug }, message: '' }
  return { draft: { ...draft, model: slug, effort: '' }, message: `${slug} does not offer effort '${draft.effort}'; effort is back to your Codex default` }
}

export function staleMessage(draft: Draft, entries: unknown[]): string | undefined {
  return entryKey(entries[draft.index]) === draft.baseline ? undefined : 'The specialists changed while you edited; your draft was set aside.'
}


export type Option = { value: string; label: string }
// One table row: zebra shades every other one, color marks the specialist.
type RowBase = { index: number; name: string; color: string; zebra: boolean; editing: boolean }
export type RosterEntry =
  | RowBase & { kind: 'ok'; model: string; effort: string; effortStyle?: Style; when: string; instructions?: string }
  | RowBase & { kind: 'broken'; problem: string; stored: string }
// Character widths of the name, model and effort columns, headers included.
export type Columns = { name: number; model: number; effort: number }
export type EditorView = {
  title: string; unsaved: boolean; removable: boolean; discardLabel: string
  models: 'loading' | 'failed' | 'ready'
  modelOptions: Option[]; effortOptions: Option[]
  effortHelp: string; whenHelp: string; instructionsHelp: string
}
export type SetupView = {
  header: string
  roster: RosterEntry[]
  columns: Columns
  empty?: string
  // Why the stored list could not be read; Save and Remove refuse while it stands.
  problem?: string
  editor?: EditorView
  confirm?: { text: string; yes: string; no: string }
  status?: Status
}

const option = (value: string, label = value): Option => ({ value, label })

function savedName(entries: unknown[], index: number): string | undefined {
  const parsed = parseSpecialist(entries[index])
  return 'error' in parsed ? undefined : parsed.name
}

// The saved side of a draft, read back from its baseline; undefined for a new
// draft or one whose entry did not parse.
function savedFields(draft: Draft): Fields | undefined {
  if (draft.baseline === '') return undefined
  let entry: unknown
  try { entry = JSON.parse(draft.baseline) } catch { return undefined }
  const parsed = parseSpecialist(entry)
  return 'error' in parsed ? undefined : fieldsOf(parsed)
}

export function isDirty(draft: Draft): boolean {
  const saved = savedFields(draft)
  if (!saved) return draft.name.trim() !== '' || draft.when.trim() !== '' || draft.instructions.trim() !== ''
  return saved.name !== draft.name || saved.model !== draft.model || saved.effort !== draft.effort ||
    saved.when !== draft.when || saved.instructions !== draft.instructions
}

function editorView(draft: Draft, catalog: CatalogState, entries: unknown[]): EditorView {
  const models = 'models' in catalog ? catalog.models : []
  const model = models.find(m => m.slug === draft.model)
  const listed = [...models.filter(m => m.listed), ...models.filter(m => !m.listed)]
  const removable = draft.baseline.trim() !== ''
  const name = savedName(entries, draft.index)
  let effortHelp = ''
  if (model) effortHelp = draft.effort ? model.effortHelp[draft.effort] ?? '' : `Your Codex config decides; this model's own default is ${model.defaultEffort}`
  return {
    title: removable ? `EDIT ${name ?? `specialist ${draft.index + 1}`}` : 'NEW specialist',
    unsaved: isDirty(draft),
    removable,
    discardLabel: removable ? 'Discard changes' : 'Cancel adding',
    models: 'loading' in catalog ? 'loading' : 'error' in catalog ? 'failed' : 'ready',
    modelOptions: 'models' in catalog ? listed.map(m => option(m.slug, m.listed ? m.slug : `${m.slug} (hidden)`)) : [option(draft.model)],
    effortOptions: [option('default'), ...(model ? model.efforts : draft.effort ? [draft.effort] : []).map(e => option(e))],
    effortHelp,
    whenHelp: `${draft.when.length}/${WHEN_MAX} · Claude reads this to decide when to offer this specialist.`,
    instructionsHelp: 'Sent to the specialist before each new task. Blank means it just follows the task.',
  }
}

function confirmView(setup: SetupState, entries: unknown[]): SetupView['confirm'] {
  const { confirm, draft } = setup
  if (!confirm || !draft) return undefined
  const current = savedName(entries, draft.index) ?? (draft.name || 'this draft')
  if (confirm.kind === 'remove') return { text: `Remove ${current}? Claude can no longer offer it.`, yes: `Remove ${current}`, no: 'Keep it' }
  const target = confirm.target === 'new' ? 'add new' : `open ${savedName(entries, confirm.target) ?? `specialist ${confirm.target + 1}`}`
  return { text: `${current} has unsaved changes.`, yes: `Discard and ${target}`, no: 'Keep editing' }
}

export const HEADERS = { name: 'NAME', model: 'MODEL', effort: 'EFFORT', when: 'USE WHEN' }
// The table's geometry: a swatch, then each column's widest text plus PAD,
// then a bar before the next column.
export const SWATCH_WIDTH = 2
export const PAD = 1
export const SEPARATOR = '│ '

// The rule drawn between rows, crossing each bar where it stands; cut or
// filled to the given width.
export function ruleLine(columns: Columns, width: number): string {
  const cross = '┼' + '─'.repeat(SEPARATOR.length - 1)
  const line = '─'.repeat(SWATCH_WIDTH + columns.name + PAD) + cross +
    '─'.repeat(columns.model + PAD) + cross + '─'.repeat(columns.effort + PAD) + cross
  return line.length >= width ? line.slice(0, width) : line + '─'.repeat(width - line.length)
}

function rosterRow(entry: unknown, index: number, editing: boolean): RosterEntry {
  const base = { index, color: SWATCHES[index % SWATCHES.length] ?? '', zebra: index % 2 === 1, editing }
  const parsed = parseSpecialist(entry)
  if ('error' in parsed) return { ...base, kind: 'broken', name: `specialist ${index + 1}`, problem: parsed.error, stored: entryKey(entry) }
  const effortStyle = parsed.effort && Object.hasOwn(EFFORT_STYLE, parsed.effort) ? EFFORT_STYLE[parsed.effort] : undefined
  return {
    ...base, kind: 'ok', name: parsed.name, model: parsed.model, effort: parsed.effort ?? 'default',
    ...(effortStyle ? { effortStyle } : {}), when: parsed.when, ...(parsed.instructions ? { instructions: parsed.instructions } : {}),
  }
}

function columnsOf(roster: RosterEntry[]): Columns {
  const widest = (header: string, cells: string[]) => Math.max(header.length, ...cells.map(cell => cell.length))
  const ok = roster.flatMap(row => (row.kind === 'ok' ? [row] : []))
  return {
    name: widest(HEADERS.name, roster.map(row => row.name)),
    model: widest(HEADERS.model, ok.map(row => row.model)),
    effort: widest(HEADERS.effort, ok.map(row => row.effort)),
  }
}

export function setupView(setup: SetupState, entries: unknown[], problem?: string): SetupView {
  const roster = entries.map((entry, index) => rosterRow(entry, index, setup.draft?.index === index))
  return {
    header: `SPECIALISTS (${roster.length})`,
    roster,
    columns: columnsOf(roster),
    ...(problem ? { problem } : {}),
    ...(roster.length === 0 && !problem ? { empty: 'No specialists yet. Add one, and Claude offers it when a task matches its use-when.' } : {}),
    ...(setup.draft ? { editor: editorView(setup.draft, setup.catalog, entries) } : {}),
    ...(setup.confirm ? { confirm: confirmView(setup, entries) } : {}),
    ...(setup.status ? { status: setup.status } : {}),
  }
}

const SET_ASIDE: Status = { kind: 'note', text: 'An earlier draft could not be read and was set aside.' }
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const DRAFT_TEXT = ['baseline', 'name', 'model', 'effort', 'when', 'instructions'] as const

const isStrings = (v: unknown): v is string[] => Array.isArray(v) && v.every(item => typeof item === 'string')

function readModel(v: unknown): CatalogModel | undefined {
  if (!isRecord(v) || typeof v.slug !== 'string' || typeof v.listed !== 'boolean' || !isStrings(v.efforts) || typeof v.defaultEffort !== 'string') return undefined
  if (!isRecord(v.effortHelp)) return undefined
  const effortHelp: Record<string, string> = {}
  for (const [effort, text] of Object.entries(v.effortHelp)) {
    if (typeof text !== 'string') return undefined
    effortHelp[effort] = text
  }
  return { slug: v.slug, listed: v.listed, efforts: v.efforts, effortHelp, defaultEffort: v.defaultEffort }
}

function readCatalogState(v: unknown): CatalogState | undefined {
  if (!isRecord(v)) return undefined
  if (v.loading === true) return { loading: true }
  if (typeof v.error === 'string') return { error: v.error }
  if (!Array.isArray(v.models)) return undefined
  const models: CatalogModel[] = []
  for (const item of v.models) {
    const model = readModel(item)
    if (!model) return undefined
    models.push(model)
  }
  return { models }
}

// Rebuilt from its own fields, so a key another version added does not ride along.
function readDraft(v: unknown): Draft | undefined {
  if (!isRecord(v) || typeof v.index !== 'number' || !Number.isInteger(v.index) || v.index < 0) return undefined
  const text: Record<string, string> = {}
  for (const field of DRAFT_TEXT) {
    const value = v[field]
    if (typeof value !== 'string') return undefined
    text[field] = value
  }
  const { baseline = '', name = '', model = '', effort = '', when = '', instructions = '' } = text
  return { index: v.index, baseline, name, model, effort, when, instructions }
}

function readStatus(v: unknown): Status | undefined {
  if (!isRecord(v) || typeof v.text !== 'string' || !['saved', 'error', 'note'].includes(v.kind as string)) return undefined
  return { kind: v.kind as Status['kind'], text: v.text }
}

function readConfirm(v: unknown): Confirm | undefined {
  if (!isRecord(v)) return undefined
  if (v.kind === 'remove') return { kind: 'remove' }
  if (v.kind === 'switch' && (v.target === 'new' || (typeof v.target === 'number' && Number.isInteger(v.target)))) return { kind: 'switch', target: v.target }
  return undefined
}

// The screen's state comes back from the plugin store after every reload. It
// crosses a boundary there (another version of the plugin may have written it),
// so it is read field by field; what does not fit is set aside with a note.
export function restoreSetup(value: unknown, entries: unknown[]): SetupState | undefined {
  if (value === undefined || value === null) return undefined
  if (!isRecord(value)) return { catalog: { loading: true }, status: SET_ASIDE }
  const catalog = readCatalogState(value.catalog)
  const draft = value.draft === undefined ? undefined : readDraft(value.draft)
  if (!catalog || (value.draft !== undefined && !draft)) return { catalog: { loading: true }, status: SET_ASIDE }
  if (draft) {
    const stale = staleMessage(draft, entries)
    if (stale) return { catalog, status: { kind: 'note', text: stale } }
  }
  const status = readStatus(value.status)
  const confirm = readConfirm(value.confirm)
  return { catalog, ...(draft ? { draft } : {}), ...(status ? { status } : {}), ...(confirm ? { confirm } : {}) }
}
