// ABOUTME: Tests for lifting the council synthesis out of the assistant's reply
// ABOUTME: Fixtures follow the reply shape the council-execution skill prescribes
import { test, expect } from 'bun:test'
import { extractSynthesis } from '../hooks/synthesis'

const REPLY = [
  '---',
  '## ● Kimi-cli - moonshot-ai/kimi-k3',
  'Use SQLite.',
  '',
  '---',
  '## Synthesis',
  '',
  '**Consensus.** All five seats pick SQLite.',
  '',
  '**Recommendation.** SQLite with WAL.',
  '',
  '---',
  '💾 Full output saved to `.claude/council-cache/council-1.md`',
  '',
  'Next: nothing owed.',
].join('\n')

test('extractSynthesis returns the text between the Synthesis heading and the saved-output line', () => {
  expect(extractSynthesis(REPLY)).toBe('**Consensus.** All five seats pick SQLite.\n\n**Recommendation.** SQLite with WAL.')
})

test('extractSynthesis runs to the end when no saved-output line follows', () => {
  expect(extractSynthesis('## Synthesis\n\nOnly this.\n')).toBe('Only this.')
})

test('a reply with no Synthesis heading, or an empty one, yields nothing', () => {
  expect(extractSynthesis('Just an answer about synthesis in general.')).toBeUndefined()
  expect(extractSynthesis('## Synthesis\n\n---\nFull output saved to x')).toBeUndefined()
})
