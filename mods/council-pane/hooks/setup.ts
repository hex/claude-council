// ABOUTME: Pure decisions for the specialist setup screen: Codex's model catalog, one validator, rows and drafts
// ABOUTME: No engine calls here, so every rule runs under bun test
import { CUSTOM, nameProblem, parseSpecialist, WHEN_MAX, type Roles } from './specialist'

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

// focus is written into the row only for the custom perspective.
export type Fields = { name: string; model: string; perspective: string; effort: string; focus: string; when: string }

export function rowText(f: Fields): string {
  const focus = f.perspective === CUSTOM ? `focus: ${f.focus}, ` : ''
  return `${f.name} = ${f.model} as ${f.perspective}, ${f.effort ? `effort: ${f.effort}, ` : ''}${focus}when: ${f.when}`
}

// The fields a user types are checked here first, so each error names its field;
// the row then goes through parseSpecialist, the same reader session start uses.
export function checkSpecialist(f: Fields, index: number, context: { roles: Roles; models: CatalogModel[]; rows: string[] }): { row: string } | { error: string } {
  if (f.name.trim() === '') return { error: 'name is empty' }
  const badName = nameProblem(f.name)
  if (badName) return { error: badName }
  if (f.when.trim() === '') return { error: 'use-when is empty' }
  if (/[\r\n]/.test(f.when)) return { error: 'use-when must be one line' }
  if (f.perspective === CUSTOM) {
    if (f.focus.trim() === '') return { error: 'focus is empty: write what this specialist should look for' }
    if (/[\r\n]/.test(f.focus)) return { error: 'focus must be one line' }
    if (f.focus.includes('when:')) return { error: "focus cannot contain 'when:'" }
  }
  const model = context.models.find(m => m.slug === f.model)
  if (!model) return { error: `model '${f.model}' is not in Codex's catalog: ${context.models.filter(m => m.listed).map(m => m.slug).join(', ')}` }
  if (f.effort && !model.efforts.includes(f.effort)) return { error: `effort '${f.effort}' is not offered by ${model.slug}: ${model.efforts.join(', ')}` }
  const row = rowText(f)
  const parsed = parseSpecialist(row, context.roles)
  if (parsed === undefined) return { error: 'the row is empty' }
  if ('error' in parsed) return parsed
  const taken = context.rows.findIndex((other, at) => {
    if (at === index) return false
    const theirs = parseSpecialist(other, context.roles)
    return theirs !== undefined && !('error' in theirs) && theirs.name === parsed.name
  })
  if (taken !== -1) return { error: `name '${parsed.name}' is already used by specialist ${taken + 1}` }
  return { row }
}

// A save puts the row at its index, which one past the end appends; a remove drops it.
export function putRow(rows: string[], index: number, row: string): string[] {
  return index >= rows.length ? [...rows, row] : rows.map((existing, at) => (at === index ? row : existing))
}

export function dropRow(rows: string[], index: number): string[] {
  return rows.filter((_, at) => at !== index)
}

// index: the row's place in the list, or the list's length for a new one.
// baseline: the row's text when editing started, to spot a change made meanwhile.
export type Draft = Fields & { index: number; baseline: string }
export type Status = { kind: 'saved' | 'error' | 'note'; text: string }
// A question the screen asks inline before an action it cannot undo.
export type Confirm = { kind: 'remove' } | { kind: 'switch'; target: number | 'new' }
export type SetupState = { draft?: Draft; catalog: CatalogState; status?: Status; confirm?: Confirm }

// A row that does not parse opens as a blank draft on the first listed model,
// so the model the screen shows is the one a Save writes.
export function draftFor(index: number, rows: string[], roles: Roles, models: CatalogModel[]): Draft {
  const baseline = rows[index] ?? ''
  const parsed = parseSpecialist(baseline, roles)
  if (!parsed || 'error' in parsed) return { ...blankDraft(index, models, roles), baseline }
  return { index, baseline, name: parsed.name, model: parsed.model, perspective: parsed.perspective, effort: parsed.effort ?? '', focus: parsed.focus ?? '', when: parsed.when }
}

export function blankDraft(index: number, models: CatalogModel[], roles: Roles, prefill: Partial<Fields> = {}): Draft {
  const model = models.find(m => m.listed)?.slug ?? ''
  return { index, baseline: '', name: '', model, perspective: Object.keys(roles)[0] ?? '', effort: '', focus: '', when: '', ...prefill }
}

export function withModel(draft: Draft, slug: string, models: CatalogModel[]): { draft: Draft; message: string } {
  const offered = models.find(m => m.slug === slug)?.efforts ?? []
  if (draft.effort === '' || offered.includes(draft.effort)) return { draft: { ...draft, model: slug }, message: '' }
  return { draft: { ...draft, model: slug, effort: '' }, message: `${slug} does not offer effort '${draft.effort}'; effort is back to your Codex default` }
}

export function staleMessage(draft: Draft, rows: string[]): string | undefined {
  return (rows[draft.index] ?? '') === draft.baseline ? undefined : 'The specialists changed while you edited; your draft was set aside.'
}


export type Option = { value: string; label: string }
export type RosterEntry = { index: number; name: string; model: string; detail: string; when: string; problem?: string; editing: boolean }
export type EditorView = {
  title: string; unsaved: boolean; removable: boolean; discardLabel: string
  models: 'loading' | 'failed' | 'ready'
  modelOptions: Option[]; effortOptions: Option[]; perspectiveOptions: Option[]
  showFocus: boolean
  perspectiveHelp: string; effortHelp: string; whenCount: string
}
export type SetupView = {
  header: string
  roster: RosterEntry[]
  empty?: string
  editor?: EditorView
  confirm?: { text: string; yes: string; no: string }
  status?: Status
}

const option = (value: string, label = value): Option => ({ value, label })

// The perspective's own prompt says what it looks for; its first sentence is
// only "You are ...", so the second one is shown when there is one.
function perspectiveHelp(roles: Roles, perspective: string): string {
  if (perspective === CUSTOM) return 'Your own instructions, written below, open every task.'
  const prompt = Object.hasOwn(roles, perspective) ? roles[perspective]?.prompt ?? '' : ''
  const sentences = prompt.split(/(?<=\.)\s+/).filter(Boolean)
  return sentences[1] ?? sentences[0] ?? ''
}

function savedName(rows: string[], index: number, roles: Roles): string | undefined {
  const parsed = parseSpecialist(rows[index], roles)
  return parsed && !('error' in parsed) ? parsed.name : undefined
}

export function isDirty(draft: Draft, roles: Roles): boolean {
  const saved = parseSpecialist(draft.baseline, roles)
  if (!saved || 'error' in saved) return draft.name.trim() !== '' || draft.when.trim() !== ''
  return saved.name !== draft.name || saved.model !== draft.model || saved.perspective !== draft.perspective ||
    (saved.effort ?? '') !== draft.effort || (saved.focus ?? '') !== draft.focus || saved.when !== draft.when
}

function editorView(draft: Draft, catalog: CatalogState, roles: Roles, rows: string[]): EditorView {
  const models = 'models' in catalog ? catalog.models : []
  const model = models.find(m => m.slug === draft.model)
  const listed = [...models.filter(m => m.listed), ...models.filter(m => !m.listed)]
  const removable = draft.baseline.trim() !== ''
  const name = savedName(rows, draft.index, roles)
  let effortHelp = ''
  if (model) effortHelp = draft.effort ? model.effortHelp[draft.effort] ?? '' : `Your Codex config decides; this model's own default is ${model.defaultEffort}`
  return {
    title: removable ? `EDIT ${name ?? `specialist ${draft.index + 1}`}` : 'NEW specialist',
    unsaved: isDirty(draft, roles),
    removable,
    discardLabel: removable ? 'Discard changes' : 'Cancel adding',
    models: 'loading' in catalog ? 'loading' : 'error' in catalog ? 'failed' : 'ready',
    modelOptions: 'models' in catalog ? listed.map(m => option(m.slug, m.listed ? m.slug : `${m.slug} (hidden)`)) : [option(draft.model)],
    perspectiveOptions: [...Object.keys(roles), CUSTOM].map(p => option(p)),
    showFocus: draft.perspective === CUSTOM,
    effortOptions: [option('default'), ...(model ? model.efforts : draft.effort ? [draft.effort] : []).map(e => option(e))],
    perspectiveHelp: perspectiveHelp(roles, draft.perspective),
    effortHelp,
    whenCount: `${draft.when.length}/${WHEN_MAX}`,
  }
}

function confirmView(setup: SetupState, rows: string[], roles: Roles): SetupView['confirm'] {
  const { confirm, draft } = setup
  if (!confirm || !draft) return undefined
  const current = savedName(rows, draft.index, roles) ?? (draft.name || 'this draft')
  if (confirm.kind === 'remove') return { text: `Remove ${current}? Claude can no longer offer it.`, yes: `Remove ${current}`, no: 'Keep it' }
  const target = confirm.target === 'new' ? 'add new' : `open ${savedName(rows, confirm.target, roles) ?? `specialist ${confirm.target + 1}`}`
  return { text: `${current} has unsaved changes.`, yes: `Discard and ${target}`, no: 'Keep editing' }
}

export function setupView(setup: SetupState, rows: string[], roles: Roles): SetupView {
  const roster: RosterEntry[] = []
  rows.forEach((row, index) => {
    const parsed = parseSpecialist(row, roles)
    if (parsed === undefined) return
    const editing = setup.draft?.index === index
    if ('error' in parsed) { roster.push({ index, name: `specialist ${index + 1}`, model: '', detail: row, when: '', problem: parsed.error, editing }); return }
    roster.push({ index, name: parsed.name, model: parsed.model, detail: `${parsed.perspective} · effort ${parsed.effort ?? 'default'}`, when: parsed.when, editing })
  })
  return {
    header: `SPECIALISTS ${roster.length}`,
    roster,
    ...(roster.length === 0 ? { empty: 'No specialists yet. Add one, and Claude offers it when a task matches its use-when.' } : {}),
    ...(setup.draft ? { editor: editorView(setup.draft, setup.catalog, roles, rows) } : {}),
    ...(setup.confirm ? { confirm: confirmView(setup, rows, roles) } : {}),
    ...(setup.status ? { status: setup.status } : {}),
  }
}

const SET_ASIDE: Status = { kind: 'note', text: 'An earlier draft could not be read and was set aside.' }
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const DRAFT_TEXT = ['baseline', 'name', 'model', 'perspective', 'effort', 'focus', 'when'] as const

function readCatalogState(v: unknown): CatalogState | undefined {
  if (!isRecord(v)) return undefined
  if (v.loading === true) return { loading: true }
  if (typeof v.error === 'string') return { error: v.error }
  if (Array.isArray(v.models)) return { models: v.models as CatalogModel[] }
  return undefined
}

function readDraft(v: unknown): Draft | undefined {
  if (!isRecord(v) || typeof v.index !== 'number' || !Number.isInteger(v.index) || v.index < 0) return undefined
  if (DRAFT_TEXT.some(field => typeof v[field] !== 'string')) return undefined
  return v as unknown as Draft
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
export function restoreSetup(value: unknown, rows: string[]): SetupState | undefined {
  if (value === undefined || value === null) return undefined
  if (!isRecord(value)) return { catalog: { loading: true }, status: SET_ASIDE }
  const catalog = readCatalogState(value.catalog)
  const draft = value.draft === undefined ? undefined : readDraft(value.draft)
  if (!catalog || (value.draft !== undefined && !draft)) return { catalog: { loading: true }, status: SET_ASIDE }
  if (draft) {
    const stale = staleMessage(draft, rows)
    if (stale) return { catalog, status: { kind: 'note', text: stale } }
  }
  const status = readStatus(value.status)
  const confirm = readConfirm(value.confirm)
  return { catalog, ...(draft ? { draft } : {}), ...(status ? { status } : {}), ...(confirm ? { confirm } : {}) }
}
