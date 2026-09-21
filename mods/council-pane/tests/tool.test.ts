// ABOUTME: Tests for turning the council tool's input into run-council.sh arguments
// ABOUTME: The input comes from the model, so every field is validated before it reaches a command line
import { test, expect } from 'bun:test'
import { councilArgs } from '../hooks/tool'

test('a question alone runs with the defaults', () => {
  expect(councilArgs({ question: 'postgres or sqlite?' })).toEqual({ args: ['--', 'postgres or sqlite?'] })
})

test('providers and verbosity become flags ahead of the question', () => {
  expect(councilArgs({ question: 'q', providers: ['codex', 'openrouter-2'], verbosity: 'brief' })).toEqual({
    args: ['--providers=codex,openrouter-2', '--verbosity=brief', '--', 'q'],
  })
})

test('a question that looks like a flag still lands after the separator', () => {
  expect(councilArgs({ question: '--async' })).toEqual({ args: ['--', '--async'] })
})

test('bad input is refused with a reason, never passed on', () => {
  expect(councilArgs({})).toEqual({ deny: 'question must be a non-empty string' })
  expect(councilArgs({ question: '   ' })).toEqual({ deny: 'question must be a non-empty string' })
  expect(councilArgs({ question: 'q', providers: ['codex', '../evil'] })).toEqual({ deny: 'providers must be names like codex or openrouter-2' })
  expect(councilArgs({ question: 'q', providers: 'codex' })).toEqual({ deny: 'providers must be names like codex or openrouter-2' })
  expect(councilArgs({ question: 'q', verbosity: 'loud' })).toEqual({ deny: 'verbosity must be brief, standard or detailed' })
})
