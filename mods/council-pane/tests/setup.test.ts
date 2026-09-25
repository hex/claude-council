// ABOUTME: Tests for the specialist setup screen's pure logic: catalog, validation, entries, drafts
// ABOUTME: The catalog fixture is real `codex debug models` output, trimmed with jq to the fields read
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseSpecialist } from '../hooks/specialist'
import { parseCatalog, checkSpecialist, putEntry, dropEntry, draftFor, blankDraft, withModel, staleMessage, restoreSetup, ruleLine, saveIndex, setupView, isDirty, type Fields, type SetupState } from '../hooks/setup'

const catalogText = readFileSync(`${import.meta.dir}/fixtures/codex-models.json`, 'utf8')
const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '' })

test('the catalog lists each model with whether Codex lists it and the efforts it offers', () => {
  const catalog = parseCatalog(ok(catalogText))
  if ('error' in catalog) throw new Error(catalog.error)
  expect(catalog.models.length).toBe(9)
  expect(catalog.models[0]).toEqual({
    slug: 'gpt-6-sol', listed: true, efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'], defaultEffort: 'medium',
    effortHelp: {
      low: 'Fast responses with lighter reasoning', medium: 'Balances speed and reasoning depth for everyday tasks',
      high: 'Greater reasoning depth for complex problems', xhigh: 'Extra high reasoning depth for complex problems',
      max: 'Maximum reasoning depth for the hardest problems', ultra: 'Maximum reasoning with automatic task delegation',
    },
  })
  expect(catalog.models.find(m => m.slug === 'gpt-reserve')?.listed).toBe(false)
  expect(catalog.models.find(m => m.slug === 'gpt-5.5')?.defaultEffort).toBe('xhigh')
})

test('a failed codex run is an error carrying its first stderr line', () => {
  expect(parseCatalog({ exitCode: 1, stdout: '', stderr: 'Not logged in. Run codex login.\nmore' })).toEqual({ error: 'Not logged in. Run codex login.' })
  expect(parseCatalog({ exitCode: 127, stdout: '', stderr: '' })).toEqual({ error: 'codex debug models exited 127' })
})

test('output that is not a catalog is an error, never an empty list', () => {
  expect(parseCatalog(ok('not json'))).toEqual({ error: 'codex debug models printed something that is not JSON' })
  expect(parseCatalog(ok('{"models": 3}'))).toEqual({ error: 'codex debug models printed no models list' })
  expect(parseCatalog(ok('{"models": []}'))).toEqual({ error: 'codex debug models printed no models list' })
  expect(parseCatalog(ok('{"models": [{"slug": "x", "visibility": "list"}]}'))).toEqual({ error: "codex debug models: model 'x' has no supported_reasoning_levels" })
  expect(parseCatalog(ok('{"models": [{"visibility": "list", "supported_reasoning_levels": []}]}'))).toEqual({ error: 'codex debug models: a model has no slug' })
})

const catalog = parseCatalog(ok(catalogText))
const models = 'models' in catalog ? catalog.models : []
const fields: Fields = { name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth, crypto', instructions: '' }
const context = { models, entries: [] as unknown[] }

test('a save writes the entry parseSpecialist reads, leaving blank optional fields out', () => {
  expect(checkSpecialist(fields, 0, context)).toEqual({ entry: { name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth, crypto' } })
  expect(checkSpecialist({ ...fields, effort: '', instructions: 'Review migrations for locks.' }, 0, context)).toEqual({ entry: { name: 'sec', model: 'gpt-6-sol', when: 'auth, crypto', instructions: 'Review migrations for locks.' } })
})

test('free text holding quotes, commas, colons and when: round-trips through the stored JSON', () => {
  const when = 'auth, crypto: tokens, when: parsing "untrusted" input'
  const instructions = 'Check it, when: always; say "no" to eval.'
  const checked = checkSpecialist({ ...fields, when, instructions }, 0, context)
  if (!('entry' in checked)) throw new Error(checked.error)
  expect(parseSpecialist(JSON.parse(JSON.stringify(checked.entry)))).toEqual({ name: 'sec', model: 'gpt-6-sol', effort: 'high', when, instructions })
})

test('every field is checked, and the error names the field and what is allowed', () => {
  const check = (f: Partial<Fields>) => checkSpecialist({ ...fields, ...f }, 0, context)
  expect(check({ name: '' })).toEqual({ error: 'name is empty' })
  expect(check({ name: 'Sec' })).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(check({ name: 'my spec' })).toEqual({ error: "name 'my spec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(check({ model: 'gpt-6-soll' })).toEqual({ error: "model 'gpt-6-soll' is not in Codex's catalog: gpt-6-sol, gpt-6-astra, gpt-6-luna, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5" })
  expect(check({ model: 'gpt-6-luna', effort: 'ultra' })).toEqual({ error: "effort 'ultra' is not offered by gpt-6-luna: low, medium, high, xhigh, max" })
  expect(check({ when: '' })).toEqual({ error: 'use-when is empty' })
  expect(check({ when: 'two\nlines' })).toEqual({ error: 'use-when must be one line' })
  expect(check({ when: 'x'.repeat(201) })).toEqual({ error: 'use-when is longer than 200 characters' })
  expect(check({ instructions: 'two\nlines' })).toEqual({ error: 'instructions must be one line' })
  expect(check({ instructions: 'x'.repeat(401) })).toEqual({ error: 'instructions are longer than 400 characters' })
})

test('a hidden catalog model is accepted', () => {
  expect(checkSpecialist({ ...fields, model: 'gpt-reserve', effort: 'max' }, 0, context)).toEqual({ entry: { name: 'sec', model: 'gpt-reserve', effort: 'max', when: 'auth, crypto' } })
})

test('a name another specialist uses is refused; the one being edited may keep its own', () => {
  const entries = [{ name: 'a', model: 'gpt-6-sol', when: 'w' }, { name: 'sec', model: 'gpt-6-astra', when: 'loops' }]
  expect(checkSpecialist(fields, 0, { ...context, entries })).toEqual({ error: "name 'sec' is already used by specialist 2" })
  expect(checkSpecialist(fields, 2, { ...context, entries })).toEqual({ error: "name 'sec' is already used by specialist 2" })
  expect(checkSpecialist(fields, 1, { ...context, entries })).toEqual({ entry: { name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth, crypto' } })
})

test('a save replaces the entry it edits or appends a new one; a remove drops it; there is no limit', () => {
  const entries = ['a', 'b', 'c', 'd']
  expect(putEntry(entries, 1, 'B')).toEqual(['a', 'B', 'c', 'd'])
  expect(putEntry(entries, 4, 'e')).toEqual(['a', 'b', 'c', 'd', 'e'])
  expect(dropEntry(entries, 0)).toEqual(['b', 'c', 'd'])
  expect(entries).toEqual(['a', 'b', 'c', 'd'])
})

const secEntry = { name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth' }

test('editing an entry starts from its fields; one that does not parse starts blank on the first listed model but keeps its place', () => {
  const entries = [secEntry, { name: 'old', model: 'gpt-6-sol', perspective: 'security', when: 'w' }]
  expect(draftFor(0, entries, models)).toEqual({ index: 0, baseline: JSON.stringify(secEntry), name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth', instructions: '' })
  expect(draftFor(1, entries, models)).toEqual({ index: 1, baseline: JSON.stringify(entries[1]), name: '', model: 'gpt-6-sol', effort: '', when: '', instructions: '' })
})

test('a blank draft picks the first listed model and takes a prefill', () => {
  expect(blankDraft(2, models)).toEqual({ index: 2, baseline: '', name: '', model: 'gpt-6-sol', effort: '', when: '', instructions: '' })
  expect(blankDraft(2, models, { name: 'perf', when: 'hot loops', instructions: 'Measure first.' })).toMatchObject({ name: 'perf', when: 'hot loops', instructions: 'Measure first.' })
})

test('switching to a model that lacks the chosen effort resets it and says so', () => {
  const draft = { ...blankDraft(0, models), effort: 'ultra' }
  expect(withModel(draft, 'gpt-6-luna', models)).toEqual({ draft: { ...draft, model: 'gpt-6-luna', effort: '' }, message: "gpt-6-luna does not offer effort 'ultra'; effort is back to your Codex default" })
  expect(withModel({ ...draft, effort: 'high' }, 'gpt-6-luna', models)).toEqual({ draft: { ...draft, model: 'gpt-6-luna', effort: 'high' }, message: '' })
})

test('a draft whose entry changed meanwhile is flagged', () => {
  const draft = draftFor(0, [secEntry], models)
  expect(staleMessage(draft, [{ ...secEntry }])).toBeUndefined()
  expect(staleMessage(draft, [{ ...secEntry, when: 'crypto' }])).toBe('The specialists changed while you edited; your draft was set aside.')
  expect(staleMessage(blankDraft(1, models), [secEntry])).toBeUndefined()
})

const two = [
  { name: 'sec', model: 'gpt-6-sol', effort: 'high', when: 'auth, crypto' },
  { name: 'mig', model: 'gpt-6-luna', when: 'schema changes', instructions: 'Review migrations for locks and rollbacks.' },
]
const ready: SetupState = { catalog: { models } }

test('the roster is a table: a row per specialist, zebra on every other one, its own colour and its effort coloured', () => {
  const view = setupView(ready, two)
  expect(view.header).toBe('SPECIALISTS (2)')
  expect(view.roster).toEqual([
    { kind: 'ok', index: 0, name: 'sec', color: 'rgb(70,130,180)', zebra: false, editing: false, model: 'gpt-6-sol', effort: 'high', effortStyle: { color: 'warning' }, when: 'auth, crypto' },
    { kind: 'ok', index: 1, name: 'mig', color: 'rgb(150,90,170)', zebra: true, editing: false, model: 'gpt-6-luna', effort: 'default', when: 'schema changes', instructions: 'Review migrations for locks and rollbacks.' },
  ])
  expect(view.editor).toBeUndefined()
})

test('the columns are as wide as their widest cell, header included', () => {
  expect(setupView(ready, two).columns).toEqual({ name: 4, model: 10, effort: 7 })
  expect(setupView(ready, [{ name: 'a', model: 'm', when: 'w' }]).columns).toEqual({ name: 4, model: 5, effort: 7 })
  expect(setupView(ready, [{ name: 'a', model: 'm', when: 'w' }, 'broken']).columns).toEqual({ name: 12, model: 5, effort: 7 })
})

test('each effort has its own style, rising with the effort; the Codex default has none', () => {
  const effortOf = (effort?: string) => {
    const [row] = setupView(ready, [{ name: 'a', model: 'm', when: 'w', ...(effort ? { effort } : {}) }]).roster
    return row?.kind === 'ok' ? row.effortStyle : 'broken'
  }
  expect(['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].map(effortOf)).toEqual([
    { color: 'inactive' }, { color: 'suggestion' }, { color: 'warning' }, { color: 'error' }, { color: 'error', bold: true }, { color: 'merged', bold: true },
  ])
  expect(effortOf(undefined)).toBeUndefined()
  expect(effortOf('turbo')).toBeUndefined()
})

test('specialist colours follow the list order and wrap after six', () => {
  const seven = Array.from({ length: 7 }, (_, i) => ({ name: `s${i}`, model: 'm', when: 'w' }))
  expect(setupView(ready, seven).roster.map(row => row.color)).toEqual([
    'rgb(70,130,180)', 'rgb(150,90,170)', 'rgb(60,140,90)', 'rgb(200,80,110)', 'rgb(160,120,20)', 'rgb(40,140,140)', 'rgb(70,130,180)',
  ])
})

test('an entry that does not parse stays in the roster with its problem and what was stored', () => {
  const old = { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth' }
  const view = setupView(ready, [old, 'sec = gpt-6-sol as security, when: auth'])
  expect(view.roster).toEqual([
    { kind: 'broken', index: 0, name: 'specialist 1', color: 'rgb(70,130,180)', zebra: false, editing: false, problem: "unknown field 'perspective'", stored: '{"name":"sec","model":"gpt-6-sol","perspective":"security","when":"auth"}' },
    { kind: 'broken', index: 1, name: 'specialist 2', color: 'rgb(150,90,170)', zebra: true, editing: false, problem: 'a specialist must be a JSON object with name, model and when', stored: '"sec = gpt-6-sol as security, when: auth"' },
  ])
})

test('with no specialists the roster says what to do', () => {
  expect(setupView(ready, []).empty).toBe('No specialists yet. Add one, and Claude offers it when a task matches its use-when.')
  expect(setupView(ready, []).header).toBe('SPECIALISTS (0)')
})

test('the editor explains effort, use-when and instructions and counts the use-when', () => {
  const draft = draftFor(0, two, models)
  const view = setupView({ ...ready, draft }, two)
  expect(view.roster[0]?.editing).toBe(true)
  expect(view.editor).toMatchObject({
    title: 'EDIT sec', unsaved: false, removable: true, discardLabel: 'Discard changes', models: 'ready',
    effortHelp: 'Greater reasoning depth for complex problems',
    whenHelp: '12/200 · Claude reads this to decide when to offer this specialist.',
    instructionsHelp: 'Sent to the specialist before each new task. Blank means it just follows the task.',
  })
  expect(view.editor?.effortOptions[0]).toEqual({ value: 'default', label: 'default' })
  expect(view.editor?.effortOptions.map(o => o.value)).toEqual(['default', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'])
  const byDefault = setupView({ ...ready, draft: { ...draft, effort: '' } }, two)
  expect(byDefault.editor?.effortHelp).toBe("Your Codex config decides; this model's own default is medium")
})

test('listed models come first and hidden ones say so', () => {
  const draft = draftFor(0, two, models)
  const options = setupView({ ...ready, draft }, two).editor?.modelOptions ?? []
  expect(options.slice(0, 2)).toEqual([{ value: 'gpt-6-sol', label: 'gpt-6-sol' }, { value: 'gpt-6-astra', label: 'gpt-6-astra' }])
  expect(options.at(-1)).toEqual({ value: 'codex-auto-review', label: 'codex-auto-review (hidden)' })
})

test('a new draft is titled new and offers to cancel rather than discard', () => {
  const view = setupView({ ...ready, draft: blankDraft(2, models) }, two)
  expect(view.editor).toMatchObject({ title: 'NEW specialist', removable: false, discardLabel: 'Cancel adding', unsaved: false })
})

test('an edited field marks the draft unsaved, and a stored entry with its keys in another order is not a change', () => {
  const draft = draftFor(0, two, models)
  expect(isDirty(draft)).toBe(false)
  expect(isDirty({ ...draft, when: 'auth' })).toBe(true)
  expect(isDirty({ ...draft, instructions: 'Be careful.' })).toBe(true)
  const reordered = [{ when: 'schema changes', instructions: 'Review migrations for locks and rollbacks.', model: 'gpt-6-luna', name: 'mig' }]
  expect(isDirty(draftFor(0, reordered, models))).toBe(false)
  expect(isDirty(blankDraft(2, models))).toBe(false)
  expect(isDirty({ ...blankDraft(2, models), name: 'x' })).toBe(true)
  expect(isDirty({ ...blankDraft(2, models), instructions: 'x' })).toBe(true)
  expect(setupView({ ...ready, draft: { ...draft, when: 'auth' } }, two).editor?.unsaved).toBe(true)
})

test('while the catalog loads or after it failed, the model list holds only the current model', () => {
  const draft = draftFor(0, two, models)
  const loading = setupView({ catalog: { loading: true }, draft }, two).editor
  expect(loading?.models).toBe('loading')
  expect(loading?.modelOptions).toEqual([{ value: 'gpt-6-sol', label: 'gpt-6-sol' }])
  expect(loading?.effortOptions.map(o => o.value)).toEqual(['default', 'high'])
  const failed = setupView({ catalog: { error: 'Not logged in' }, draft }, two).editor
  expect(failed?.models).toBe('failed')
  expect(failed?.effortHelp).toBe('')
})

test('confirmations ask in words that name the specialist', () => {
  const draft = draftFor(0, two, models)
  expect(setupView({ ...ready, draft, confirm: { kind: 'remove' } }, two).confirm).toEqual({ text: 'Remove sec? Claude can no longer offer it.', yes: 'Remove sec', no: 'Keep it' })
  expect(setupView({ ...ready, draft, confirm: { kind: 'switch', target: 1 } }, two).confirm).toEqual({ text: 'sec has unsaved changes.', yes: 'Discard and open mig', no: 'Keep editing' })
  expect(setupView({ ...ready, draft, confirm: { kind: 'switch', target: 'new' } }, two).confirm).toEqual({ text: 'sec has unsaved changes.', yes: 'Discard and add new', no: 'Keep editing' })
})

test('a saved screen is read back only when its shape is right; an older or broken one is set aside with a note', () => {
  const draft = draftFor(0, two, models)
  const setAside = { catalog: { loading: true }, status: { kind: 'note', text: 'An earlier draft could not be read and was set aside.' } }
  expect(restoreSetup({ draft, catalog: { models } }, two)).toEqual({ draft, catalog: { models } })
  expect(restoreSetup(undefined, two)).toBeUndefined()
  const perspectiveDraft = { draft: { index: 0, baseline: '', name: 'sec', model: 'gpt-6-luna', perspective: 'custom', effort: '', focus: 'locks', when: '' }, catalog: { models } }
  expect(restoreSetup(perspectiveDraft, two)).toEqual(setAside)
  expect(restoreSetup('junk', two)).toEqual(setAside)
  expect(restoreSetup({ draft, catalog: { models } }, [{ name: 'changed', model: 'gpt-6-sol', when: 'w' }])).toEqual({ catalog: { models }, status: { kind: 'note', text: 'The specialists changed while you edited; your draft was set aside.' } })
})

test('a rule between rows crosses each column bar and runs to the given width', () => {
  // swatch 2 + name 4+1, bar, model 10+1, bar, effort 7+1, bar, the rest
  expect(ruleLine({ name: 4, model: 10, effort: 7 }, 40)).toBe('─'.repeat(7) + '┼─' + '─'.repeat(11) + '┼─' + '─'.repeat(8) + '┼─' + '─'.repeat(8))
  expect(ruleLine({ name: 4, model: 10, effort: 7 }, 40)).toHaveLength(40)
  expect(ruleLine({ name: 4, model: 10, effort: 7 }, 10)).toBe('─'.repeat(7) + '┼──')
})

test('a stored list that cannot be read is shown as a problem, not as an empty roster', () => {
  const view = setupView(ready, [], 'the specialists setting is not JSON: nope')
  expect(view.problem).toBe('the specialists setting is not JSON: nope')
  expect(view.empty).toBeUndefined()
  expect(setupView(ready, []).problem).toBeUndefined()
})

test('a restored screen keeps only the fields it knows, and a catalog of another shape is set aside', () => {
  const draft = draftFor(0, two, models)
  const setAside = { catalog: { loading: true }, status: { kind: 'note', text: 'An earlier draft could not be read and was set aside.' } }
  expect(restoreSetup({ draft: { ...draft, perspective: 'x' }, catalog: { models } }, two)).toEqual({ draft, catalog: { models } })
  const oldModel = { slug: 'gpt-6-sol', listed: true, efforts: ['high'] }
  expect(restoreSetup({ draft, catalog: { models: [oldModel] } }, two)).toEqual(setAside)
  expect(restoreSetup({ draft, catalog: { models: 'many' } }, two)).toEqual(setAside)
})

test('a new specialist lands at the end of the newest list; an edited one keeps its place', () => {
  expect(saveIndex(blankDraft(1, models), [secEntry, secEntry, secEntry])).toBe(3)
  expect(saveIndex(draftFor(0, [secEntry], models), [secEntry, secEntry])).toBe(0)
})
