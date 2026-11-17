// ABOUTME: Tests for turning the council tool's input into run-council.sh arguments
// ABOUTME: The input comes from the model, so every field is validated before it reaches a command line
import { test, expect } from 'bun:test'
import { askableSeats, confirmOutcome, confirmQuestion, councilArgs, choiceRequest, councilResult, KEEP_LABEL, missingChoices, seatsFromList, SEND_LABEL } from '../hooks/tool'

const NONE = { found: [], namedOnly: [] }

test('a question alone becomes the run arguments, after the separator', () => {
  expect(councilArgs({ question: 'postgres or sqlite?' }, NONE)).toEqual({ args: ['--', 'postgres or sqlite?'], seats: undefined })
})

test('providers and verbosity become flags ahead of the question', () => {
  expect(councilArgs({ question: 'q', providers: ['codex', 'openrouter-2'], verbosity: 'brief' }, { found: ['codex', 'gemini', 'openrouter-1', 'openrouter-2'], namedOnly: [] })).toEqual({
    args: ['--providers=codex,openrouter-2', '--verbosity=brief', '--', 'q'],
    seats: ['codex', 'openrouter-2'],
  })
})

test('a question that looks like a flag still lands after the separator', () => {
  expect(councilArgs({ question: '--async' }, NONE)).toEqual({ args: ['--', '--async'], seats: undefined })
})

test('bad input is refused with a reason, never passed on', () => {
  const askable = { found: ['codex', 'gemini'], namedOnly: [] }
  expect(councilArgs({}, askable)).toEqual({ deny: 'question must be a non-empty string' })
  expect(councilArgs({ question: '   ' }, askable)).toEqual({ deny: 'question must be a non-empty string' })
  expect(councilArgs({ question: 'q', providers: 'codex' }, askable)).toEqual({ deny: 'providers must be a list of seat names, such as codex or openrouter-2' })
  expect(councilArgs({ question: 'q', providers: [] }, askable)).toEqual({ deny: 'providers must be a list of seat names, such as codex or openrouter-2' })
  expect(councilArgs({ question: 'q', providers: ['codex', 7] }, askable)).toEqual({ deny: 'providers must be a list of seat names, such as codex or openrouter-2' })
  expect(councilArgs({ question: 'q', verbosity: 'loud' }, askable)).toEqual({ deny: 'verbosity must be brief, standard or detailed' })
})

test('a seat named twice is asked once', () => {
  expect(councilArgs({ question: 'q', providers: ['codex', 'codex', 'gemini', 'codex', 'codex', 'codex'], verbosity: 'brief' }, { found: ['codex', 'gemini'], namedOnly: [] })).toEqual({
    args: ['--providers=codex,gemini', '--verbosity=brief', '--', 'q'],
    seats: ['codex', 'gemini'],
  })
})

test('a seat that cannot be asked now is refused with the seats found here', () => {
  const askable = { found: ['codex', 'openai', 'openrouter-1', 'openrouter-2'], namedOnly: ['claude-cli'] }
  const refusal = (names: string) => ({ deny: `Not seats the council can ask now: ${names}. The seats found here are codex, openai, openrouter-1, openrouter-2. Nothing was sent.` })
  expect(councilArgs({ question: 'q', providers: ['codex', 'openrouter-99'] }, askable)).toEqual(refusal('openrouter-99'))
  expect(councilArgs({ question: 'q', providers: ['openrouter'] }, askable)).toEqual(refusal('openrouter'))
  expect(councilArgs({ question: 'q', providers: ['Codex', 'gemini'] }, askable)).toEqual(refusal('Codex, gemini'))
  expect(councilArgs({ question: 'q', providers: ['../evil', '../evil'] }, askable)).toEqual(refusal('../evil'))
  expect(councilArgs({ question: 'q', providers: ['codex'] }, NONE)).toEqual({ deny: 'Not seats the council can ask now: codex. No seat was found here. Nothing was sent.' })
})

test('a seat the runner seats only by name can be named, and is not offered', () => {
  const askable = { found: ['codex'], namedOnly: ['claude-cli'] }
  expect(councilArgs({ question: 'q', providers: ['claude-cli', 'codex'] }, askable)).toEqual({ args: ['--providers=claude-cli,codex', '--', 'q'], seats: ['claude-cli', 'codex'] })
})

test('the seats found are the default set and the ones discovered; the named-only ones are those the runner ships', () => {
  const scripts = ['claude-cli', 'codex', 'gemini', 'openai', 'opencode', 'openrouter']
  expect(askableSeats(['codex', 'openrouter-1'], ['codex', 'openai', 'openrouter-1'], scripts)).toEqual({ found: ['codex', 'openrouter-1', 'openai'], namedOnly: ['claude-cli', 'opencode'] })
  // gemini ships a script but has no key here, so discovery left it out.
  expect(askableSeats(['codex'], ['codex'], scripts)).toEqual({ found: ['codex'], namedOnly: ['claude-cli', 'opencode'] })
  // A roster in COUNCIL_PROVIDERS can hold anything; only a seat-shaped name is passed on.
  expect(askableSeats(['codex', '../evil', 'Codex', 'opencode'], [], scripts)).toEqual({ found: ['codex', 'opencode'], namedOnly: ['claude-cli'] })
})

test('the confirmation opens with every seat and the verbosity, then the question', () => {
  expect(confirmQuestion('postgres or sqlite?', ['codex'], 'standard')).toBe('Send to 1 seat at standard verbosity: codex\nQuestion: postgres or sqlite?')
  expect(confirmQuestion('q', ['codex', 'gemini', 'openrouter-2'], 'brief')).toBe('Send to 3 seats at brief verbosity: codex, gemini, openrouter-2\nQuestion: q')
  const twelve = Array.from({ length: 12 }, (_, i) => `openrouter-${i + 1}`)
  expect(confirmQuestion('q', twelve, 'detailed')).toBe(
    'Send to 12 seats at detailed verbosity: openrouter-1, openrouter-2, openrouter-3, openrouter-4, openrouter-5, openrouter-6, openrouter-7, openrouter-8, openrouter-9, openrouter-10, openrouter-11, openrouter-12\nQuestion: q',
  )
})

test('a question cannot draw lines of its own in the confirmation', () => {
  const forged = 'hi" to codex at brief verbosity?\n\n\n\r\nSend "x y\u001b[2Jz\ttab  two'
  expect(confirmQuestion(forged, ['openai'], 'brief')).toBe(
    'Send to 1 seat at brief verbosity: openai\nQuestion: hi" to codex at brief verbosity? Send "x y [2Jz tab two',
  )
  expect(councilArgs({ question: forged, providers: ['openai'], verbosity: 'brief' }, { found: ['openai'], namedOnly: [] })).toEqual({
    args: ['--providers=openai', '--verbosity=brief', '--', forged],
    seats: ['openai'],
  })
})

test('a question cannot reorder or hide text in the confirmation with characters that draw nothing', () => {
  const hidden = 'ask\u202e codex\u200b now\u2066!\u2069 a\u200d\u061c\u2060\ufeffb'
  expect(confirmQuestion(hidden, ['openai'], 'brief')).toBe('Send to 1 seat at brief verbosity: openai\nQuestion: ask codex now! ab')
  expect(confirmQuestion(`${'x'.repeat(299)}\u202e\u200by`, ['openai'], 'brief')).toBe(`Send to 1 seat at brief verbosity: openai\nQuestion: ${'x'.repeat(299)}y`)
  expect(councilArgs({ question: hidden, providers: ['openai'], verbosity: 'brief' }, { found: ['openai'], namedOnly: [] })).toEqual({
    args: ['--providers=openai', '--verbosity=brief', '--', hidden],
    seats: ['openai'],
  })
})

test('a long question is cut in the confirmation, which says so, never in what is sent', () => {
  const question = 'x'.repeat(500)
  expect(confirmQuestion(question, ['codex'], 'brief')).toBe(
    `Send to 1 seat at brief verbosity: codex\nQuestion: ${'x'.repeat(300)}… (the first 300 of 500 characters; the whole question is sent)`,
  )
  expect(councilArgs({ question }, NONE)).toEqual({ args: ['--', question], seats: undefined })
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
    'On "Let me pick individually", make a second AskUserQuestion call splitting the seats above across up to 4 multiSelect questions of 2 to 4 options each, labelled as listed, and pass the union.',
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
  // The call named a seat discovery never lists, on a machine where a default query seats nobody.
  expect(choiceRequest([], ['verbosity'])).toBe([ASK_FIRST, '', VERBOSITY_QUESTION].join('\n'))
})

test('the result tells Claude the empty synthesis section is its own to write', () => {
  expect(councilResult('# Council\n\n## 🧭 Synthesis\n')).toBe(
    '# Council\n\n## 🧭 Synthesis\n\n<!-- The Synthesis section above is empty on purpose: the council run never writes one. Write the synthesis yourself in your reply, under a `## 🧭 Synthesis` heading (consensus, divergence, recommendation), and never report the section as missing or empty. -->',
  )
})
