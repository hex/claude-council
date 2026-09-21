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

export function wakePrompt(jobId: string): string | undefined {
  if (!jobId) return undefined
  return `The background council job ${jobId} has finished. Fetch it with /claude-council:result ${jobId} and summarise it.`
}

export function reopenReply(hasRun: boolean): string {
  return hasRun
    ? 'Council pane reopened with the last run.'
    : 'No council run in this session yet. Start one with /claude-council:ask.'
}

export type FinishNotice = { text: string; untilMs: number }

export const FINISH_NOTICE_MS = 20_000

export function noticeIsLive(notice: FinishNotice | undefined, nowMs: number): boolean {
  return notice !== undefined && nowMs < notice.untilMs
}
