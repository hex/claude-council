// ABOUTME: Tests for the status-line text, the finish toast and the wake prompt of a council run
// ABOUTME: Expected strings are literals; none is rebuilt from the functions under test
import { test, expect } from 'bun:test'
import { finishNotice, wakePrompt, reopenReply, noticeIsLive, jobOutcome, abandonedNotice, runPid, progressBand } from '../hooks/notices'

const providers = [
  { name: 'gemini', state: 'complete', ms: 4210 },
  { name: 'codex', state: 'cached' },
  { name: 'grok', state: 'error' },
  { name: 'kimi', state: 'querying' },
]

test('finishNotice reports answers and errors, and names a background job', () => {
  expect(finishNotice({ providers, isDone: true })).toBe('finished: 2 of 4 answered, 1 error')
  expect(finishNotice({ providers: providers.slice(0, 2), isDone: true }, 'job-abc')).toBe(
    'job job-abc finished: 2 of 2 answered',
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

test('noticeIsLive keeps a finish notice up for its window only', () => {
  expect(noticeIsLive({ text: 'x', untilMs: 5000 }, 4999)).toBe(true)
  expect(noticeIsLive({ text: 'x', untilMs: 5000 }, 5000)).toBe(false)
  expect(noticeIsLive(undefined, 0)).toBe(false)
})

test('jobOutcome reads a job record the way run-council --result does', () => {
  expect(jobOutcome('{"id":"job-abc","status":"completed","outfile":".claude/council-cache/job-abc.md"}')).toBe('completed')
  expect(jobOutcome('{"id":"job-abc","status":"running","pid":"4242"}')).toBe('running')
  expect(jobOutcome('{"id":"job-abc","status":"queued"}')).toBe('running')
  expect(jobOutcome('{"id":"job-abc","status":"failed"}')).toBe('failed')
  expect(jobOutcome('{"id":"job-abc","status":"cancelled"}')).toBe('failed')
})

test('jobOutcome waits on a record caught mid-write and gives up on one that is gone', () => {
  expect(jobOutcome('{"id":"job-abc","sta')).toBe('running')
  expect(jobOutcome('[]')).toBe('failed')
  expect(jobOutcome('')).toBe('failed')
})

test('abandonedNotice says the run stopped short and how far it got', () => {
  expect(abandonedNotice({ providers, isDone: false })).toBe('stopped before it finished: 2 of 4 answered')
  expect(abandonedNotice({ providers, isDone: false }, 'job-abc')).toBe('job job-abc stopped before it finished: 2 of 4 answered')
})

test('runPid accepts a process id and nothing else', () => {
  expect(runPid('4242')).toBe('4242')
  expect(runPid(' 4242\n')).toBe('4242')
  expect(runPid('')).toBeUndefined()
  expect(runPid('0')).toBeUndefined()
  expect(runPid('-1')).toBeUndefined()
  expect(runPid('42; rm -rf /')).toBeUndefined()
})

test('progressBand fills by finished providers and names who is still out', () => {
  // gemini + codex answered, grok errored, kimi querying: 3 of 4 finished = 6 of 8 cells.
  expect(progressBand({ providers, isDone: false }, 10_000, 34_900)).toEqual({
    bar: '\u2588\u2588\u2588\u2588\u2588\u2588\u2591\u2591',
    text: '2 of 4 answered \u00b7 waiting on kimi \u00b7 24s',
  })
})

test('progressBand names two providers still out, then a count', () => {
  const out = ['a', 'b', 'c', 'd', 'e'].map(name => ({ name, state: 'querying' }))
  expect(progressBand({ providers: [{ name: 'gemini', state: 'complete' }, ...out], isDone: false }, 0, 0)).toEqual({
    bar: '\u2588\u2591\u2591\u2591\u2591\u2591\u2591\u2591',
    text: '1 of 6 answered \u00b7 waiting on a, b +3 \u00b7 0s',
  })
})

test('progressBand starts empty and leaves the elapsed time out until a run is picked up', () => {
  const waiting = [{ name: 'gemini', state: 'pending' }, { name: 'openai', state: 'querying' }]
  expect(progressBand({ providers: waiting, isDone: false }, undefined, 5_000)).toEqual({
    bar: '\u2591'.repeat(8),
    text: '0 of 2 answered \u00b7 waiting on gemini, openai',
  })
})

test('progressBand shows nothing once the run is done or before any provider is listed', () => {
  expect(progressBand({ providers, isDone: true }, 0, 1_000)).toBeUndefined()
  expect(progressBand({ providers: [], isDone: false }, 0, 1_000)).toBeUndefined()
})

test('progressBand never shows a negative time when the clock it is given lags the pickup', () => {
  expect(progressBand({ providers, isDone: false }, 10_000, 9_000)?.text).toBe('2 of 4 answered · waiting on kimi · 0s')
})
