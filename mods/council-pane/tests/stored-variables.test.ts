// ABOUTME: Tests for the plugin config options the mod sets as environment variables, and the variable each becomes
// ABOUTME: Covers parsing the options register receives and agreement with plugin.json and pane.tsx
import { test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { STORED_VARIABLES, storedValues } from '../hooks/stored-variables'

const ROOT = join(import.meta.dir, '..', '..', '..')

test('no stored keys: nothing to hand on', () => {
  expect(storedValues({})).toEqual([])
})

test('each stored key becomes its provider variable, in table order', () => {
  expect(storedValues({
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

test('a key pasted with surrounding whitespace is handed on without it', () => {
  expect(storedValues({ openai_api_key: '  example-openai\n' })).toEqual([{ variable: 'OPENAI_API_KEY', value: 'example-openai' }])
})

test('an empty, blank or non-string value is not a key, and other options are ignored', () => {
  expect(storedValues({ gemini_api_key: '', openai_api_key: '   ', xai_api_key: true, kimi_api_key: 42, pane_host: 'tmux', heads_up: true })).toEqual([])
})

test('a stored roster is set as OPENROUTER_MODELS, trimmed; a blank one sets nothing', () => {
  expect(storedValues({ openrouter_models: '  deepseek/deepseek-v3.2, z-ai/glm-5.3\n' })).toEqual([{ variable: 'OPENROUTER_MODELS', value: 'deepseek/deepseek-v3.2, z-ai/glm-5.3' }])
  expect(storedValues({ openrouter_models: ' \t\n' })).toEqual([])
})

test('plugin.json declares exactly the table and every sensitive field in it, each an optional string titled alike', () => {
  const manifest = JSON.parse(readFileSync(join(ROOT, '.claude-plugin', 'plugin.json'), 'utf8')) as { userConfig: Record<string, Record<string, unknown>> }
  const declared = Object.entries(manifest.userConfig).filter(([option, field]) => field.sensitive === true || STORED_VARIABLES.some(row => row.option === option))
  expect(declared.map(([option, field]) => ({ option, title: field.title, type: field.type, sensitive: field.sensitive === true, required: field.required, default: field.default }))).toEqual(
    STORED_VARIABLES.map(({ option, title, sensitive }) => ({ option, title, type: 'string', sensitive, required: undefined, default: undefined })),
  )
})

test('pane.tsx spells a $.env.set for every variable, the only way the engine lets it write one', () => {
  const source = readFileSync(join(ROOT, 'mods', 'council-pane', 'hooks', 'pane.tsx'), 'utf8')
  const written = [...source.matchAll(/\$\.env\.set\('([A-Z_]+)'/g)].map(match => match[1])
  expect(STORED_VARIABLES.filter(({ variable }) => !written.includes(variable))).toEqual([])
})
