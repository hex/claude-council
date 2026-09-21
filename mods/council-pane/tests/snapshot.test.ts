// ABOUTME: Tests that a snapshot marked done holds the run's final files, even when the run ends mid-read
// ABOUTME: A scripted file system finishes the run partway through the read sequence
import { test, expect } from 'bun:test'
import { readView } from '../hooks/snapshot'

const RUN = '/tmp/run'

// The run finishes after `callsBeforeFinish` file-system calls: from then on
// the status says complete, the answer exists and .done is there.
function runEndingAfter(callsBeforeFinish: number) {
  let calls = 0
  const isFinished = () => calls++ >= callsBeforeFinish
  return {
    exists: async (path: string) => {
      const finished = isFinished()
      if (path === `${RUN}/status`) return true
      if (path === `${RUN}/responses` || path === `${RUN}/.done`) return finished
      return false
    },
    read: async (path: string) => {
      const finished = isFinished()
      if (path === `${RUN}/status`) return finished ? 'gemini\tquerying\t\t\ngemini\tcomplete\t4210\tgemini-3-pro\n' : 'gemini\tquerying\t\t\n'
      if (path === `${RUN}/responses/gemini.md`) return 'the answer'
      return ''
    },
    list: async (dir: string) => {
      const finished = isFinished()
      return finished && dir === `${RUN}/responses` ? [{ kind: 'file', name: 'gemini.md' }] : []
    },
  }
}

test('a run that ends in the middle of a read is not reported done with a provider still querying', async () => {
  for (let callsBeforeFinish = 0; callsBeforeFinish < 8; callsBeforeFinish++) {
    const view = await readView(runEndingAfter(callsBeforeFinish), RUN)
    if (!view.isDone) continue
    expect(view.providers).toEqual([{ name: 'gemini', state: 'complete', ms: 4210, model: 'gemini-3-pro' }])
    expect(view.responses).toEqual({ gemini: 'the answer' })
  }
})

test('a finished run reads as done with its answer', async () => {
  const view = await readView(runEndingAfter(0), RUN)
  expect(view.isDone).toBe(true)
  expect(view.responses).toEqual({ gemini: 'the answer' })
})

test('a run still going reads as not done', async () => {
  const view = await readView(runEndingAfter(1000), RUN)
  expect(view.isDone).toBe(false)
  expect(view.providers).toEqual([{ name: 'gemini', state: 'querying' }])
})
