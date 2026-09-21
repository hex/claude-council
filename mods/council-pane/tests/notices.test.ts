// ABOUTME: Tests for the status-line text, the finish toast and the wake prompt of a council run
// ABOUTME: Expected strings are literals; none is rebuilt from the functions under test
import { test, expect } from 'bun:test'
import { finishNotice, wakePrompt, reopenReply, noticeIsLive, jobOutcome, abandonedNotice, runPid } from '../hooks/notices'

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
