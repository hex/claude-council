// ABOUTME: Tests for the specialist setup screen's pure logic: catalog, validation, rows, drafts
// ABOUTME: The catalog fixture is real `codex debug models` output, trimmed with jq to the fields read
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseCatalog, rowText, checkSpecialist, freeSlot, draftFor, blankDraft, withModel, staleMessage, listEntries, type Fields } from '../hooks/setup'

const catalogText = readFileSync(`${import.meta.dir}/fixtures/codex-models.json`, 'utf8')
const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '' })

test('the catalog lists each model with whether Codex lists it and the efforts it offers', () => {
  const catalog = parseCatalog(ok(catalogText))
  if ('error' in catalog) throw new Error(catalog.error)
  expect(catalog.models.length).toBe(9)
  expect(catalog.models[0]).toEqual({ slug: 'gpt-6-sol', listed: true, efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'] })
  expect(catalog.models.find(m => m.slug === 'gpt-reserve')).toEqual({ slug: 'gpt-reserve', listed: false, efforts: ['low', 'medium', 'high', 'xhigh', 'max'] })
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
  expect(checkSpecialist({ ...fields, when }, 'specialist_1', context)).toEqual({ row: `sec = gpt-6-sol as security, effort: high, when: ${when}` })
})

test('every field is checked, and the error names the field and what is allowed', () => {
  const check = (f: Partial<Fields>) => checkSpecialist({ ...fields, ...f }, 'specialist_1', context)
  expect(check({ name: '' })).toEqual({ error: 'name is empty' })
  expect(check({ name: 'Sec' })).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(check({ name: 'my spec' })).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
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

test('editing a row starts from its fields; a row that does not parse starts blank but keeps its slot', () => {
  const options = { specialist_1: 'sec = gpt-6-sol as security, effort: high, when: auth', specialist_2: 'broken row' }
  expect(draftFor('specialist_1', options, roles)).toEqual({ slot: 'specialist_1', baseline: options.specialist_1, name: 'sec', model: 'gpt-6-sol', perspective: 'security', effort: 'high', when: 'auth' })
  expect(draftFor('specialist_2', options, roles)).toEqual({ slot: 'specialist_2', baseline: 'broken row', name: '', model: '', perspective: 'security', effort: '', when: '' })
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
  const draft = draftFor('specialist_1', { specialist_1: 'a = gpt-6-sol as security, when: w' }, roles)
  expect(staleMessage(draft, { specialist_1: 'a = gpt-6-sol as security, when: w' })).toBeUndefined()
  expect(staleMessage(draft, { specialist_1: 'b = gpt-6-sol as security, when: w' })).toBe('specialist_1 changed while you edited; reloaded it')
})

test('the list shows every non-empty row, a broken one with its problem', () => {
  expect(listEntries({ specialist_1: 'sec = gpt-6-sol as security, effort: high, when: auth', specialist_3: 'broken row' }, roles)).toEqual([
    { slot: 'specialist_1', label: 'sec  gpt-6-sol  security  high  auth' },
    { slot: 'specialist_3', label: 'specialist_3: broken row', problem: 'expected: name = model as perspective, when: use-when' },
  ])
})
