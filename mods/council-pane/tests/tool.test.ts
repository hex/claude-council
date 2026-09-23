// ABOUTME: Tests for turning the council tool's input into run-council.sh arguments
// ABOUTME: The input comes from the model, so every field is validated before it reaches a command line
import { test, expect } from 'bun:test'
import { confirmOutcome, confirmQuestion, councilArgs, KEEP_LABEL, SEND_LABEL } from '../hooks/tool'

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

test('the confirmation names the providers and quotes the question', () => {
  expect(confirmQuestion({ question: 'postgres or sqlite?', providers: ['codex', 'openrouter-2'] })).toBe(
    'Send "postgres or sqlite?" to codex, openrouter-2?',
  )
  expect(confirmQuestion({ question: 'postgres or sqlite?' })).toBe('Send "postgres or sqlite?" to every configured provider?')
})

test('a long question is cut in the confirmation, never in what is sent', () => {
  const question = 'x'.repeat(500)
  expect(confirmQuestion({ question })).toBe(`Send "${'x'.repeat(300)}…" to every configured provider?`)
  expect(councilArgs({ question })).toEqual({ args: ['--', question] })
})

test('only the send label sends; anything else is a refusal the model can read', () => {
  expect(confirmOutcome(SEND_LABEL)).toEqual({ send: true })
  expect(confirmOutcome(KEEP_LABEL)).toEqual({ deny: 'The user chose not to send this to the council.' })
  expect(confirmOutcome(undefined)).toEqual({ deny: 'The user was not asked (dialog dismissed or no one to ask), so nothing was sent to the council.' })
  expect(confirmOutcome('only ask gemini')).toEqual({ deny: 'The user did not send this to the council and said: only ask gemini' })
})
