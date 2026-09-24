// ABOUTME: Pure decisions for the specialist setup screen: Codex's model catalog, one validator, rows and drafts
// ABOUTME: No engine calls here, so every rule runs under bun test
import { CUSTOM, nameProblem, parseSpecialist, SLOTS, WHEN_MAX, type Roles } from './specialist'

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
export function checkSpecialist(f: Fields, slot: string, context: { roles: Roles; models: CatalogModel[]; options: Record<string, unknown> }): { row: string } | { error: string } {
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
  for (const other of SLOTS) {
    if (other === slot) continue
    const theirs = parseSpecialist(context.options[other], context.roles)
    if (theirs && !('error' in theirs) && theirs.name === parsed.name) return { error: `name '${parsed.name}' is already used by ${other}` }
  }
  return { row }
}

export function freeSlot(options: Record<string, unknown>): string | undefined {
  return SLOTS.find(slot => typeof options[slot] !== 'string' || (options[slot] as string).trim() === '')
}

// baseline: the slot's row text when editing started, to spot a change made meanwhile.
export type Draft = Fields & { slot: string; baseline: string }
export type Status = { kind: 'saved' | 'error' | 'note'; text: string }
// A question the screen asks inline before an action it cannot undo.
export type Confirm = { kind: 'remove' } | { kind: 'switch'; slot: string | 'new' }
export type SetupState = { draft?: Draft; catalog: CatalogState; status?: Status; confirm?: Confirm }

const rowOf = (options: Record<string, unknown>, slot: string) => (typeof options[slot] === 'string' ? (options[slot] as string) : '')

// A row that does not parse opens as a blank draft on the first listed model,
// so the model the screen shows is the one a Save writes.
export function draftFor(slot: string, options: Record<string, unknown>, roles: Roles, models: CatalogModel[]): Draft {
  const baseline = rowOf(options, slot)
  const parsed = parseSpecialist(baseline, roles)
  if (!parsed || 'error' in parsed) return { ...blankDraft(slot, models, roles), baseline }
  return { slot, baseline, name: parsed.name, model: parsed.model, perspective: parsed.perspective, effort: parsed.effort ?? '', focus: parsed.focus ?? '', when: parsed.when }
}

export function blankDraft(slot: string, models: CatalogModel[], roles: Roles, prefill: Partial<Fields> = {}): Draft {
  const model = models.find(m => m.listed)?.slug ?? ''
  return { slot, baseline: '', name: '', model, perspective: Object.keys(roles)[0] ?? '', effort: '', focus: '', when: '', ...prefill }
}

export function withModel(draft: Draft, slug: string, models: CatalogModel[]): { draft: Draft; message: string } {
  const offered = models.find(m => m.slug === slug)?.efforts ?? []
  if (draft.effort === '' || offered.includes(draft.effort)) return { draft: { ...draft, model: slug }, message: '' }
  return { draft: { ...draft, model: slug, effort: '' }, message: `${slug} does not offer effort '${draft.effort}'; effort is back to your Codex default` }
}

export function staleMessage(draft: Draft, options: Record<string, unknown>): string | undefined {
  return rowOf(options, draft.slot) === draft.baseline ? undefined : `${draft.slot} changed while you edited; reloaded it`
}


export type Option = { value: string; label: string }
export type RosterEntry = { slot: string; name: string; model: string; detail: string; when: string; problem?: string; editing: boolean }
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
  add: { kind: 'add' } | { kind: 'full'; text: string }
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

function savedName(options: Record<string, unknown>, slot: string, roles: Roles): string | undefined {
  const parsed = parseSpecialist(options[slot], roles)
  return parsed && !('error' in parsed) ? parsed.name : undefined
}

export function isDirty(draft: Draft, roles: Roles): boolean {
  const saved = parseSpecialist(draft.baseline, roles)
  if (!saved || 'error' in saved) return draft.name.trim() !== '' || draft.when.trim() !== ''
  return saved.name !== draft.name || saved.model !== draft.model || saved.perspective !== draft.perspective ||
    (saved.effort ?? '') !== draft.effort || (saved.focus ?? '') !== draft.focus || saved.when !== draft.when
}

function editorView(draft: Draft, catalog: CatalogState, roles: Roles, options: Record<string, unknown>): EditorView {
  const models = 'models' in catalog ? catalog.models : []
  const model = models.find(m => m.slug === draft.model)
  const listed = [...models.filter(m => m.listed), ...models.filter(m => !m.listed)]
  const removable = draft.baseline.trim() !== ''
  const name = savedName(options, draft.slot, roles)
  let effortHelp = ''
  if (model) effortHelp = draft.effort ? model.effortHelp[draft.effort] ?? '' : `Your Codex config decides; this model's own default is ${model.defaultEffort}`
  return {
    title: removable ? `EDIT ${name ?? draft.slot}` : 'NEW specialist',
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

function confirmView(setup: SetupState, options: Record<string, unknown>, roles: Roles): SetupView['confirm'] {
  const { confirm, draft } = setup
  if (!confirm || !draft) return undefined
  const current = savedName(options, draft.slot, roles) ?? (draft.name || 'this draft')
  if (confirm.kind === 'remove') return { text: `Remove ${current}? Claude can no longer offer it.`, yes: `Remove ${current}`, no: 'Keep it' }
  const target = confirm.slot === 'new' ? 'add new' : `open ${savedName(options, confirm.slot, roles) ?? confirm.slot}`
  return { text: `${current} has unsaved changes.`, yes: `Discard and ${target}`, no: 'Keep editing' }
}

export function setupView(setup: SetupState, options: Record<string, unknown>, roles: Roles): SetupView {
  const roster: RosterEntry[] = []
  for (const slot of SLOTS) {
    const parsed = parseSpecialist(options[slot], roles)
    if (parsed === undefined) continue
    const editing = setup.draft?.slot === slot
    if ('error' in parsed) { roster.push({ slot, name: slot, model: '', detail: rowOf(options, slot), when: '', problem: parsed.error, editing }); continue }
    roster.push({ slot, name: parsed.name, model: parsed.model, detail: `${parsed.perspective} · effort ${parsed.effort ?? 'default'}`, when: parsed.when, editing })
  }
  return {
    header: `SPECIALISTS ${roster.length} of ${SLOTS.length}`,
    roster,
    ...(roster.length === 0 ? { empty: 'No specialists yet. Add one, and Claude offers it when a task matches its use-when.' } : {}),
    add: freeSlot(options) ? { kind: 'add' } : { kind: 'full', text: `All ${SLOTS.length} slots are in use. Edit or remove one to add another.` },
    ...(setup.draft ? { editor: editorView(setup.draft, setup.catalog, roles, options) } : {}),
    ...(setup.confirm ? { confirm: confirmView(setup, options, roles) } : {}),
    ...(setup.status ? { status: setup.status } : {}),
  }
}
