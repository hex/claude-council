// ABOUTME: Tests for reading Codex's model catalog
// ABOUTME: The catalog fixture is real `codex debug models` output, trimmed with jq to the fields read
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseCatalog } from '../hooks/catalog'

const catalogText = readFileSync(`${import.meta.dir}/fixtures/codex-models.json`, 'utf8')
const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '' })

test('the catalog lists each model with whether Codex lists it and the efforts it offers', () => {
  const catalog = parseCatalog(ok(catalogText))
  if ('error' in catalog) throw new Error(catalog.error)
  expect(catalog.models.length).toBe(9)
  expect(catalog.models[0]).toEqual({
    slug: 'gpt-6-sol', listed: true, efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'], defaultEffort: 'medium',
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
