// ABOUTME: Tests for the status-line text, the finish toast and the wake prompt of a council run
// ABOUTME: Expected strings are literals; none is rebuilt from the functions under test
import { test, expect } from 'bun:test'
import { statusLine, finishToast, wakePrompt, reopenReply } from '../hooks/notices'

const providers = [
  { name: 'gemini', state: 'complete', ms: 4210 },
  { name: 'codex', state: 'cached' },
  { name: 'grok', state: 'error' },
  { name: 'kimi', state: 'querying' },
]

test('statusLine counts settled providers while a run is live and clears once it is done', () => {
  expect(statusLine({ providers, isDone: false })).toBe('council 3/4')
  expect(statusLine({ providers, isDone: true })).toBeUndefined()
  expect(statusLine({ providers: [], isDone: false })).toBe('council starting')
})

test('finishToast reports answers and errors, and names a background job', () => {
  expect(finishToast({ providers, isDone: true })).toBe('Council finished: 2 of 4 answered, 1 error')
  expect(finishToast({ providers: providers.slice(0, 2), isDone: true }, 'job-abc')).toBe(
    'Council job job-abc finished: 2 of 2 answered',
  )
})

test('wakePrompt asks for the result of a background job only', () => {
  expect(wakePrompt('job-abc')).toBe('The background council job job-abc has finished. Fetch it with /claude-council:result job-abc and summarise it.')
  expect(wakePrompt('')).toBeUndefined()
})

test('reopenReply says whether there is a run to show', () => {
  expect(reopenReply(true)).toBe('Council pane reopened with the last run.')
  expect(reopenReply(false)).toBe('No council run in this session yet. Start one with /claude-council:ask.')
})
