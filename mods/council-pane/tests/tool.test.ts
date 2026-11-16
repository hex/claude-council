// ABOUTME: Tests for turning the council tool's input into run-council.sh arguments
// ABOUTME: The input comes from the model, so every field is validated before it reaches a command line
import { test, expect } from 'bun:test'
import { confirmOutcome, confirmQuestion, councilArgs, choiceRequest, KEEP_LABEL, missingChoices, seatsFromList, unknownSeats, SEND_LABEL } from '../hooks/tool'

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

test('the confirmation names the seats, or counts them when many, and the verbosity', () => {
  expect(confirmQuestion({ question: 'postgres or sqlite?', providers: ['codex'], verbosity: 'standard' })).toBe(
    'Send "postgres or sqlite?" to codex at standard verbosity?',
  )
  expect(confirmQuestion({ question: 'q', providers: ['codex', 'gemini', 'openrouter-2'], verbosity: 'brief' })).toBe(
    'Send "q" to codex, gemini, openrouter-2 at brief verbosity?',
  )
  const twelve = Array.from({ length: 12 }, (_, i) => `openrouter-${i + 1}`)
  expect(confirmQuestion({ question: 'q', providers: twelve, verbosity: 'detailed' })).toBe('Send "q" to 12 seats at detailed verbosity?')
})

test('a long question is cut in the confirmation, never in what is sent', () => {
  const question = 'x'.repeat(500)
  expect(confirmQuestion({ question, providers: ['codex'], verbosity: 'brief' })).toBe(`Send "${'x'.repeat(300)}…" to codex at brief verbosity?`)
  expect(councilArgs({ question })).toEqual({ args: ['--', question] })
})

test('only the send label sends; anything else is a refusal the model can read', () => {
  expect(confirmOutcome(SEND_LABEL)).toEqual({ send: true })
  expect(confirmOutcome(KEEP_LABEL)).toEqual({ deny: 'The user chose not to send this to the council.' })
  expect(confirmOutcome(undefined)).toEqual({ deny: 'The user was not asked (dialog dismissed or no one to ask), so nothing was sent to the council.' })
  expect(confirmOutcome('only ask gemini')).toEqual({ reply: 'The user did not send this to the council and said: only ask gemini' })
})

test('a call sends only once it names both the seats and the verbosity', () => {
  expect(missingChoices({ question: 'q' })).toEqual(['seats', 'verbosity'])
  expect(missingChoices({ question: 'q', providers: ['codex'] })).toEqual(['verbosity'])
  expect(missingChoices({ question: 'q', verbosity: 'brief' })).toEqual(['seats'])
  expect(missingChoices({ question: 'q', providers: ['codex'], verbosity: 'brief' })).toEqual([])
})

test('the seat list keeps a model name with spaces whole', () => {
  expect(seatsFromList('antigravity\tGemini 3.8 Flash (High)\ncodex\tgpt-6.1-sol\n\n')).toEqual([
    { name: 'antigravity', model: 'Gemini 3.8 Flash (High)' },
    { name: 'codex', model: 'gpt-6.1-sol' },
  ])
  expect(seatsFromList('')).toEqual([])
})

const VERBOSITY_QUESTION = [
  'Question "How verbose should the answers be?", header "Verbosity", multiSelect false, options:',
  '- "Standard (Recommended)": balanced thoroughness',
  '- "Brief": 3-5 sentences, bullets only, no code unless asked',
  '- "Detailed": thorough analysis with code examples and trade-offs',
  'Pass verbosity "standard", "brief" or "detailed" to match.',
].join('\n')

const ASK_FIRST =
  'Nothing was sent to the council. Ask the user first, in one AskUserQuestion call holding the questions below, ' +
  'then call ask again with the same question, passing both providers and verbosity. ' +
  "Skip the asking when the user's own message already named the seats or said to ask every seat: " +
  'pass those names, and verbosity "standard" unless the user asked for brief or detailed.'

test('up to three seats are offered one by one, All first, beside the verbosity question', () => {
  const seats = [{ name: 'codex', model: 'gpt-6.1-sol' }, { name: 'gemini', model: 'gemini-3-pro' }]
  expect(choiceRequest(seats, ['seats', 'verbosity'])).toBe([
    ASK_FIRST,
    '',
    'Seats available now:',
    '- codex (gpt-6.1-sol)',
    '- gemini (gemini-3-pro)',
    '',
    'Question "Which council seats should I ask?", header "Seats", multiSelect true, options:',
    '- "All 2 seats (Recommended)": every seat above',
    '- "codex (gpt-6.1-sol)"',
    '- "gemini (gemini-3-pro)"',
    'Pass the chosen seat names as providers; for All, pass every name above.',
    '',
    VERBOSITY_QUESTION,
  ].join('\n'))
})

test('four or more seats are grouped, and the router seats split from the direct ones', () => {
  const seats = [
    { name: 'codex', model: 'gpt-6.1-sol' },
    { name: 'gemini', model: 'gemini-3-pro' },
    { name: 'grok-cli', model: 'grok-4.7' },
    { name: 'openrouter-1', model: 'qwen/qwen4' },
    { name: 'openrouter-2', model: 'deepseek/deepseek-v4' },
  ]
  expect(choiceRequest(seats, ['seats'])).toBe([
    ASK_FIRST,
    '',
    'Seats available now:',
    '- codex (gpt-6.1-sol)',
    '- gemini (gemini-3-pro)',
    '- grok-cli (grok-4.7)',
    '- openrouter-1 (qwen/qwen4)',
    '- openrouter-2 (deepseek/deepseek-v4)',
    '',
    'Question "Which council seats should I ask?", header "Seats", multiSelect false, options:',
    '- "All 5 seats (Recommended)": every seat above',
    '- "Direct seats only": codex, gemini, grok-cli',
    '- "Routed models only": openrouter-1, openrouter-2',
    '- "Let me pick individually": choose exact seats',
    'On "Let me pick individually", make a second AskUserQuestion call splitting the seats above across up to 4 multiSelect questions of at most 4 options each, labelled as listed, and pass the union.',
    'Pass the chosen seat names as providers; for All, pass every name above.',
  ].join('\n'))
})

test('with one group of seats present the split is left out', () => {
  const names = ['antigravity', 'codex', 'cursor-cli', 'grok-cli']
  const text = choiceRequest(names.map(name => ({ name, model: 'm' })), ['seats'])
  expect(text).toContain('- "All 4 seats (Recommended)": every seat above\n- "Let me pick individually": choose exact seats\n')
})

test('a lone seat is passed without a seat question', () => {
  expect(choiceRequest([{ name: 'codex', model: 'gpt-6.1-sol' }], ['seats', 'verbosity'])).toBe([
    ASK_FIRST,
    '',
    'Only one seat is available, codex (gpt-6.1-sol): pass providers ["codex"] without asking.',
    '',
    VERBOSITY_QUESTION,
  ].join('\n'))
  expect(choiceRequest([{ name: 'codex', model: 'gpt-6.1-sol' }], ['seats'])).toBe(
    'Nothing was sent to the council. Only one seat is available, codex (gpt-6.1-sol): call ask again with the same question, passing providers ["codex"] and the same verbosity.',
  )
})

test('a call missing only the verbosity is asked only that', () => {
  expect(choiceRequest([{ name: 'codex', model: 'gpt-6.1-sol' }, { name: 'gemini', model: 'g' }], ['verbosity'])).toBe(
    [ASK_FIRST, '', VERBOSITY_QUESTION].join('\n'),
  )
})

test('a named seat must be one the runner knows; the refusal lists the seats available now', () => {
  const available = ['antigravity', 'codex']
  const scripts = ['antigravity', 'claude-cli', 'codex', 'openai', 'openrouter']
  expect(unknownSeats(['codex', 'openai', 'claude-cli', 'openrouter-2'], available, scripts)).toBeUndefined()
  expect(unknownSeats(['codex', 'gpt', 'openrouter-0'], available, scripts)).toBe(
    'Not council seats: gpt, openrouter-0. The seats available now are antigravity, codex. Nothing was sent.',
  )
  expect(unknownSeats(['gpt'], [], scripts)).toBe('Not council seats: gpt. No seat is available now. Nothing was sent.')
})
