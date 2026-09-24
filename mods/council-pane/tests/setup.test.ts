// ABOUTME: Tests for the specialist setup screen's pure logic: catalog, validation, rows, drafts
// ABOUTME: The catalog fixture is real `codex debug models` output, trimmed with jq to the fields read
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseSpecialist } from '../hooks/specialist'
import { parseCatalog, rowText, checkSpecialist, freeSlot, draftFor, blankDraft, withModel, staleMessage, setupView, isDirty, type Fields, type SetupState } from '../hooks/setup'

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

const roles = {
  security: { name: 'Security Auditor', prompt: 'p' },
  performance: { name: 'Performance Optimizer', prompt: 'p' },
}
const catalog = parseCatalog(ok(catalogText))
const models = 'models' in catalog ? catalog.models : []
const fields: Fields = { name: 'sec', model: 'gpt-6-sol', perspective: 'security', effort: 'high', when: 'auth, crypto' }
const context = { roles, models, options: {} }

test('the row is written in the one shape parseSpecialist reads', () => {
  expect(rowText(fields)).toBe('sec = gpt-6-sol as security, effort: high, when: auth, crypto')
  expect(rowText({ ...fields, effort: '' })).toBe('sec = gpt-6-sol as security, when: auth, crypto')
})

test('a use-when holding commas, colons or when: itself round-trips', () => {
  const when = 'auth, crypto: tokens, when: parsing untrusted input'
  const checked = checkSpecialist({ ...fields, when }, 'specialist_1', context)
  expect(checked).toEqual({ row: `sec = gpt-6-sol as security, effort: high, when: ${when}` })
  expect(parseSpecialist('row' in checked ? checked.row : '', roles)).toEqual({ ...fields, when })
})

test('every field is checked, and the error names the field and what is allowed', () => {
  const check = (f: Partial<Fields>) => checkSpecialist({ ...fields, ...f }, 'specialist_1', context)
  expect(check({ name: '' })).toEqual({ error: 'name is empty' })
  expect(check({ name: 'Sec' })).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(check({ name: 'my spec' })).toEqual({ error: "name 'my spec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(check({ model: 'gpt-6-soll' })).toEqual({ error: "model 'gpt-6-soll' is not in Codex's catalog: gpt-6-sol, gpt-6-astra, gpt-6-luna, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5" })
  expect(check({ perspective: 'secrity' })).toEqual({ error: "unknown perspective 'secrity'" })
  expect(check({ model: 'gpt-6-luna', effort: 'ultra' })).toEqual({ error: "effort 'ultra' is not offered by gpt-6-luna: low, medium, high, xhigh, max" })
  expect(check({ when: '' })).toEqual({ error: 'use-when is empty' })
  expect(check({ when: 'two\nlines' })).toEqual({ error: 'use-when must be one line' })
  expect(check({ when: 'x'.repeat(201) })).toEqual({ error: 'use-when is longer than 200 characters' })
})

test('a hidden catalog model is accepted', () => {
  expect(checkSpecialist({ ...fields, model: 'gpt-reserve', effort: 'max' }, 'specialist_1', context)).toEqual({ row: 'sec = gpt-reserve as security, effort: max, when: auth, crypto' })
})

test('a name another slot uses is refused; the slot being edited may keep its own', () => {
  const options = { specialist_2: 'sec = gpt-6-astra as performance, when: loops' }
  expect(checkSpecialist(fields, 'specialist_1', { ...context, options })).toEqual({ error: "name 'sec' is already used by specialist_2" })
  expect(checkSpecialist(fields, 'specialist_2', { ...context, options })).toEqual({ row: 'sec = gpt-6-sol as security, effort: high, when: auth, crypto' })
})

test('adding takes the lowest empty slot, none when all four are used', () => {
  expect(freeSlot({})).toBe('specialist_1')
  expect(freeSlot({ specialist_1: 'a = m as security, when: w', specialist_2: '  ' })).toBe('specialist_2')
  const full = { specialist_1: 'x', specialist_2: 'x', specialist_3: 'x', specialist_4: 'x' }
  expect(freeSlot(full)).toBeUndefined()
})

test('editing a row starts from its fields; a row that does not parse starts blank on the first listed model but keeps its slot', () => {
  const options = { specialist_1: 'sec = gpt-6-sol as security, effort: high, when: auth', specialist_2: 'broken row' }
  expect(draftFor('specialist_1', options, roles, models)).toEqual({ slot: 'specialist_1', baseline: options.specialist_1, name: 'sec', model: 'gpt-6-sol', perspective: 'security', effort: 'high', when: 'auth' })
  expect(draftFor('specialist_2', options, roles, models)).toEqual({ slot: 'specialist_2', baseline: 'broken row', name: '', model: 'gpt-6-sol', perspective: 'security', effort: '', when: '' })
})

test('a blank draft picks the first listed model and the first perspective, and takes a prefill', () => {
  expect(blankDraft('specialist_3', models, roles)).toEqual({ slot: 'specialist_3', baseline: '', name: '', model: 'gpt-6-sol', perspective: 'security', effort: '', when: '' })
  expect(blankDraft('specialist_3', models, roles, { name: 'perf', perspective: 'performance', when: 'hot loops' }).name).toBe('perf')
})

test('switching to a model that lacks the chosen effort resets it and says so', () => {
  const draft = { ...blankDraft('specialist_1', models, roles), effort: 'ultra' }
  expect(withModel(draft, 'gpt-6-luna', models)).toEqual({ draft: { ...draft, model: 'gpt-6-luna', effort: '' }, message: "gpt-6-luna does not offer effort 'ultra'; effort is back to your Codex default" })
  expect(withModel({ ...draft, effort: 'high' }, 'gpt-6-luna', models)).toEqual({ draft: { ...draft, model: 'gpt-6-luna', effort: 'high' }, message: '' })
})

test('a draft whose slot changed meanwhile is flagged', () => {
  const draft = draftFor('specialist_1', { specialist_1: 'a = gpt-6-sol as security, when: w' }, roles, models)
  expect(staleMessage(draft, { specialist_1: 'a = gpt-6-sol as security, when: w' })).toBeUndefined()
  expect(staleMessage(draft, { specialist_1: 'b = gpt-6-sol as security, when: w' })).toBe('specialist_1 changed while you edited; reloaded it')
})


const allRoles = {
  security: { name: 'Security Auditor', prompt: 'You are a security-focused code reviewer. Prioritize identifying vulnerabilities, injection attacks, and auth flaws.' },
  performance: { name: 'Performance Optimizer', prompt: 'You are a performance-focused engineer.' },
}
const two = { specialist_1: 'sec = gpt-6-sol as security, effort: high, when: auth, crypto', specialist_2: 'perf = gpt-6-luna as performance, when: hot loops' }
const ready: SetupState = { catalog: { models } }

test('the roster shows each specialist on two lines and counts the slots', () => {
  const view = setupView(ready, two, allRoles)
  expect(view.header).toBe('SPECIALISTS 2 of 4')
  expect(view.roster).toEqual([
    { slot: 'specialist_1', name: 'sec', model: 'gpt-6-sol', detail: 'security · effort high', when: 'auth, crypto', editing: false },
    { slot: 'specialist_2', name: 'perf', model: 'gpt-6-luna', detail: 'performance · effort default', when: 'hot loops', editing: false },
  ])
  expect(view.add).toEqual({ kind: 'add' })
  expect(view.editor).toBeUndefined()
})

test('a row that does not parse stays in the roster with its problem', () => {
  const view = setupView(ready, { specialist_3: 'broken row' }, allRoles)
  expect(view.roster).toEqual([{ slot: 'specialist_3', name: 'specialist_3', model: '', detail: 'broken row', when: '', problem: 'expected: name = model as perspective, when: use-when', editing: false }])
})

test('with no specialists the roster says what to do; with four the add action says why it is gone', () => {
  expect(setupView(ready, {}, allRoles).empty).toBe('No specialists yet. Add one, and Claude offers it when a task matches its use-when.')
  const four = { ...two, specialist_3: 'c = gpt-6-sol as security, when: w', specialist_4: 'd = gpt-6-sol as security, when: w' }
  expect(setupView(ready, four, allRoles).add).toEqual({ kind: 'full', text: 'All 4 slots are in use. Edit or remove one to add another.' })
})

test('the editor explains the chosen perspective and effort and counts the use-when', () => {
  const draft = draftFor('specialist_1', two, allRoles, models)
  const view = setupView({ ...ready, draft }, two, allRoles)
  expect(view.roster[0]?.editing).toBe(true)
  expect(view.editor).toMatchObject({
    title: 'EDIT sec', unsaved: false, removable: true, discardLabel: 'Discard changes', models: 'ready',
    perspectiveHelp: 'Prioritize identifying vulnerabilities, injection attacks, and auth flaws.',
    effortHelp: 'Greater reasoning depth for complex problems', whenCount: '12/200',
  })
  expect(view.editor?.effortOptions[0]).toEqual({ value: 'default', label: 'default' })
  expect(view.editor?.effortOptions.map(o => o.value)).toEqual(['default', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'])
  const byDefault = setupView({ ...ready, draft: { ...draft, effort: '' } }, two, allRoles)
  expect(byDefault.editor?.effortHelp).toBe("Your Codex config decides; this model's own default is medium")
})

test('listed models come first and hidden ones say so', () => {
  const draft = draftFor('specialist_1', two, allRoles, models)
  const options = setupView({ ...ready, draft }, two, allRoles).editor?.modelOptions ?? []
  expect(options.slice(0, 2)).toEqual([{ value: 'gpt-6-sol', label: 'gpt-6-sol' }, { value: 'gpt-6-astra', label: 'gpt-6-astra' }])
  expect(options.at(-1)).toEqual({ value: 'codex-auto-review', label: 'codex-auto-review (hidden)' })
})

test('a new draft is titled by its slot and offers to cancel rather than discard', () => {
  const view = setupView({ ...ready, draft: blankDraft('specialist_3', models, allRoles) }, two, allRoles)
  expect(view.editor).toMatchObject({ title: 'NEW specialist', removable: false, discardLabel: 'Cancel adding', unsaved: false })
})

test('an edited field marks the draft unsaved', () => {
  const draft = draftFor('specialist_1', two, allRoles, models)
  expect(isDirty(draft, allRoles)).toBe(false)
  expect(isDirty({ ...draft, when: 'auth' }, allRoles)).toBe(true)
  expect(isDirty(blankDraft('specialist_3', models, allRoles), allRoles)).toBe(false)
  expect(isDirty({ ...blankDraft('specialist_3', models, allRoles), name: 'x' }, allRoles)).toBe(true)
  expect(setupView({ ...ready, draft: { ...draft, when: 'auth' } }, two, allRoles).editor?.unsaved).toBe(true)
})

test('while the catalog loads or after it failed, the model list holds only the current model', () => {
  const draft = draftFor('specialist_1', two, allRoles, models)
  const loading = setupView({ catalog: { loading: true }, draft }, two, allRoles).editor
  expect(loading?.models).toBe('loading')
  expect(loading?.modelOptions).toEqual([{ value: 'gpt-6-sol', label: 'gpt-6-sol' }])
  expect(loading?.effortOptions.map(o => o.value)).toEqual(['default', 'high'])
  const failed = setupView({ catalog: { error: 'Not logged in' }, draft }, two, allRoles).editor
  expect(failed?.models).toBe('failed')
  expect(failed?.effortHelp).toBe('')
})

test('confirmations ask in words that name the specialist', () => {
  const draft = draftFor('specialist_1', two, allRoles, models)
  expect(setupView({ ...ready, draft, confirm: { kind: 'remove' } }, two, allRoles).confirm).toEqual({ text: 'Remove sec? Claude can no longer offer it.', yes: 'Remove sec', no: 'Keep it' })
  expect(setupView({ ...ready, draft, confirm: { kind: 'switch', slot: 'specialist_2' } }, two, allRoles).confirm).toEqual({ text: 'sec has unsaved changes.', yes: 'Discard and open perf', no: 'Keep editing' })
  expect(setupView({ ...ready, draft, confirm: { kind: 'switch', slot: 'new' } }, two, allRoles).confirm).toEqual({ text: 'sec has unsaved changes.', yes: 'Discard and add new', no: 'Keep editing' })
})
