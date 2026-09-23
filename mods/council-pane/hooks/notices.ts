// ABOUTME: Words for a council run outside the pane: the finish notice, the wake prompt, the reopen reply
// ABOUTME: Pure functions over the run's provider states

import type { ProviderStatus } from './status'

type RunProgress = { providers: ProviderStatus[]; isDone: boolean }

const count = (providers: ProviderStatus[], ...states: string[]) =>
  providers.filter(provider => states.includes(provider.state)).length

export function finishNotice({ providers }: RunProgress, jobId = ''): string {
  const errors = count(providers, 'error')
  // The band draws a COUNCIL badge ahead of this, so the text does not repeat the name.
  const subject = jobId ? `job ${jobId} finished` : 'finished'
  const answered = `${count(providers, 'complete', 'cached')} of ${providers.length} answered`
  return `${subject}: ${answered}${errors > 0 ? `, ${errors} error` : ''}`
}

const PROGRESS_CELLS = 8
const NAMED_WAITING = 2

// The band above the prompt while a run is live. The bar fills by providers
// that are finished, an error included; the text counts answers and names who
// is still out, since that is what a wait is spent wondering. `startedAtMs` is
// when the pane picked the run up; before that there is no elapsed time.
export function progressBand(
  { providers, isDone }: RunProgress,
  startedAtMs: number | undefined,
  nowMs: number,
): { bar: string; text: string } | undefined {
  if (isDone || providers.length === 0) return undefined
  const finished = count(providers, 'complete', 'cached', 'error')
  const filled = Math.floor((finished / providers.length) * PROGRESS_CELLS)
  const bar = '\u2588'.repeat(filled) + '\u2591'.repeat(PROGRESS_CELLS - filled)
  const waiting = providers.filter(provider => !['complete', 'cached', 'error'].includes(provider.state)).map(provider => provider.name)
  const named = waiting.slice(0, NAMED_WAITING).join(', ') + (waiting.length > NAMED_WAITING ? ` +${waiting.length - NAMED_WAITING}` : '')
  const parts = [`${count(providers, 'complete', 'cached')} of ${providers.length} answered`]
  if (waiting.length > 0) parts.push(`waiting on ${named}`)
  if (startedAtMs !== undefined) parts.push(`${Math.max(0, Math.floor((nowMs - startedAtMs) / 1000))}s`)
  return { bar, text: parts.join(' \u00b7 ') }
}

// A run whose process died without writing .done: what the band says instead.
export function abandonedNotice({ providers }: RunProgress, jobId = ''): string {
  const subject = jobId ? `job ${jobId} stopped` : 'stopped'
  return `${subject} before it finished: ${count(providers, 'complete', 'cached')} of ${providers.length} answered`
}

// The pid a run left in its watch dir, fit to hand to kill -0: digits, not zero.
export function runPid(text: string): string | undefined {
  const pid = text.trim()
  return /^[1-9]\d*$/.test(pid) ? pid : undefined
}

export function wakePrompt(jobId: string): string | undefined {
  if (!jobId) return undefined
  return `The background council job ${jobId} has finished. Fetch it with /claude-council:result ${jobId} and summarise it.`
}

export function reopenReply(hasRun: boolean): string {
  return hasRun
    ? 'Council pane reopened with the last run.'
    : 'No council run in this session yet. Start one with /claude-council:ask.'
}

export type FinishNotice = { text: string; untilMs: number; isFailure?: boolean }

export const FINISH_NOTICE_MS = 20_000

export function noticeIsLive(notice: FinishNotice | undefined, nowMs: number): boolean {
  return notice !== undefined && nowMs < notice.untilMs
}

export type JobOutcome = 'completed' | 'failed' | 'running'

// Reads a job record as run-council.sh --result does: completed can be
// fetched, queued and running cannot yet, anything else never will. A record
// cut off mid-write is read again on the next poll; one that is gone or is
// not a record is over.
export function jobOutcome(record: string): JobOutcome {
  if (!record.trim()) return 'failed'
  let status: unknown
  try {
    status = (JSON.parse(record) as { status?: unknown }).status
  } catch {
    return 'running'
  }
  if (status === 'completed') return 'completed'
  return status === 'queued' || status === 'running' ? 'running' : 'failed'
}
