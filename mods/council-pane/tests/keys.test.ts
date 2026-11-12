// ABOUTME: Tests for the provider keys stored in plugin config and the variable each becomes
// ABOUTME: Covers parsing the options register receives and agreement with plugin.json and pane.tsx
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { PROVIDER_KEYS, storedKeys } from '../hooks/keys'

const ROOT = join(import.meta.dir, '..', '..', '..')

test('no stored keys: nothing to hand on', () => {
  expect(storedKeys({})).toEqual([])
})

test('each stored key becomes its provider variable, in table order', () => {
  expect(storedKeys({
    openrouter_api_key: 'example-openrouter',
    gemini_api_key: 'example-gemini',
    openai_api_key: 'example-openai',
    xai_api_key: 'example-xai',
    perplexity_api_key: 'example-perplexity',
    kimi_api_key: 'example-kimi',
  })).toEqual([
    { variable: 'GEMINI_API_KEY', value: 'example-gemini' },
    { variable: 'OPENAI_API_KEY', value: 'example-openai' },
    { variable: 'XAI_API_KEY', value: 'example-xai' },
    { variable: 'PERPLEXITY_API_KEY', value: 'example-perplexity' },
    { variable: 'KIMI_API_KEY', value: 'example-kimi' },
    { variable: 'OPENROUTER_API_KEY', value: 'example-openrouter' },
  ])
})

test('an empty, blank or non-string value is not a key, and other options are ignored', () => {
  expect(storedKeys({ gemini_api_key: '', openai_api_key: '   ', xai_api_key: true, kimi_api_key: 42, pane_host: 'tmux', heads_up: true })).toEqual([])
})

test('plugin.json declares exactly the table, each one optional, sensitive and titled alike', () => {
  const manifest = JSON.parse(readFileSync(join(ROOT, '.claude-plugin', 'plugin.json'), 'utf8')) as { userConfig: Record<string, Record<string, unknown>> }
  const sensitive = Object.entries(manifest.userConfig).filter(([, field]) => field.sensitive === true)
  expect(sensitive.map(([option, field]) => ({ option, title: field.title, type: field.type, required: field.required, default: field.default }))).toEqual(
    PROVIDER_KEYS.map(({ option, title }) => ({ option, title, type: 'string', required: undefined, default: undefined })),
  )
})

test('pane.tsx spells a $.env.set for every variable, the only way the engine lets it write one', () => {
  const source = readFileSync(join(ROOT, 'mods', 'council-pane', 'hooks', 'pane.tsx'), 'utf8')
  const written = [...source.matchAll(/\$\.env\.set\('([A-Z_]+)'/g)].map(match => match[1])
  expect(PROVIDER_KEYS.filter(({ variable }) => !written.includes(variable))).toEqual([])
})
