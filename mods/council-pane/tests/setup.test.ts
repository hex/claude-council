// ABOUTME: Tests for the specialist setup screen's pure logic: catalog, validation, rows, drafts
// ABOUTME: The catalog fixture is real `codex debug models` output, trimmed with jq to the fields read
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseCatalog, rowText, checkSpecialist, freeSlot, type Fields } from '../hooks/setup'

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
