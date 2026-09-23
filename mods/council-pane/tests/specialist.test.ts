// ABOUTME: Tests for reading specialist rows out of the options register receives
// ABOUTME: Expected values are literals; bad rows must produce a named problem, never vanish
import { test, expect } from 'bun:test'
import { parseSpecialist, specialistRoster, specialistDescription, specialistSchema } from '../hooks/specialist'

const roles = {
  security: { name: 'Security Auditor', prompt: 'You are a security-focused code reviewer.' },
  performance: { name: 'Performance Optimizer', prompt: 'You are a performance-focused engineer.' },
}

test('a well-formed row parses into its four parts', () => {
  expect(parseSpecialist('sec = gpt-6-sol as security, when: auth, crypto, untrusted input', roles)).toEqual({
    name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth, crypto, untrusted input',
  })
})

test('spacing around the separators is tolerated', () => {
  expect(parseSpecialist('  perf=gpt-6-astra  as performance ,when:hot loops ', roles)).toEqual({
    name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'hot loops',
  })
})

test('an empty or absent row is unused, not a problem', () => {
  expect(parseSpecialist('', roles)).toBeUndefined()
  expect(parseSpecialist('   ', roles)).toBeUndefined()
  expect(parseSpecialist(undefined, roles)).toBeUndefined()
})

test('a bad row names what is wrong', () => {
  expect(parseSpecialist('sec = gpt-6-sol as secrity, when: auth', roles)).toEqual({ error: "unknown perspective 'secrity'" })
  expect(parseSpecialist('Sec = gpt-6-sol as security, when: auth', roles)).toEqual({ error: "name 'Sec' must be lowercase letters, digits and dashes, starting with a letter" })
  expect(parseSpecialist('sec = as security, when: auth', roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
  expect(parseSpecialist('sec = gpt-6-sol as security', roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
  expect(parseSpecialist(`sec = gpt-6-sol as security, when: ${'x'.repeat(201)}`, roles)).toEqual({ error: 'use-when is longer than 200 characters' })
  expect(parseSpecialist(42, roles)).toEqual({ error: 'expected: name = model as perspective, when: use-when' })
})

test('the roster keeps valid rows in slot order and reports the rest', () => {
  expect(specialistRoster({
    specialist_1: 'sec = gpt-6-sol as security, when: auth',
    specialist_2: 'sec = gpt-6-astra as performance, when: loops',
    specialist_3: 'perf = gpt-6-astra as secrity, when: loops',
    specialist_4: 'perf = gpt-6-astra as performance, when: loops',
  }, roles)).toEqual({
    specialists: [
      { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth' },
      { name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'loops' },
    ],
    problems: [
      "specialist_2 ignored: the name 'sec' is already used by specialist_1",
      "specialist_3 ignored: unknown perspective 'secrity'",
    ],
  })
  expect(specialistRoster({}, roles)).toEqual({ specialists: [], problems: [] })
})

test('the description lists every specialist and the confirmation rule', () => {
  const list = [
    { name: 'sec', model: 'gpt-6-sol', perspective: 'security', when: 'auth, crypto' },
    { name: 'perf', model: 'gpt-6-astra', perspective: 'performance', when: 'hot loops' },
  ]
  expect(specialistDescription(list)).toBe(
    'Hand a coding task to a specialist that works in its own git worktree with its own model. ' +
    'Specialists: sec (security, gpt-6-sol), use when: auth, crypto; perf (performance, gpt-6-astra), use when: hot loops. ' +
    'Suggest one when a task matches its use-when. Start with {specialist, task}; send review feedback with {run, message}; ' +
    'close a run with {run, finish: "merge"|"discard"} only after the user chose. ' +
    'The user confirms before anything starts or is sent. A refusal comes back as the result; do not retry unless the reply asks for a change.',
  )
})

test('the schema limits specialist to the configured names', () => {
  const schema = specialistSchema([{ name: 'sec', model: 'm', perspective: 'security', when: 'w' }]) as any
  expect(schema.properties.specialist).toEqual({ type: 'string', enum: ['sec'] })
  expect(schema.properties.finish).toEqual({ type: 'string', enum: ['merge', 'discard'] })
  expect(schema.additionalProperties).toBe(false)
})
