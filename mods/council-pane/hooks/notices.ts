// ABOUTME: Words for a council run outside the pane: the status-line slot, the finish toast, the wake prompt
// ABOUTME: Pure functions over the run's provider states

import type { ProviderStatus } from './status'

type RunProgress = { providers: ProviderStatus[]; isDone: boolean }

const count = (providers: ProviderStatus[], ...states: string[]) =>
  providers.filter(provider => states.includes(provider.state)).length

export function statusLine({ providers, isDone }: RunProgress): string | undefined {
  if (isDone) return undefined
  if (providers.length === 0) return 'council starting'
  return `council ${count(providers, 'complete', 'cached', 'error')}/${providers.length}`
}

export function finishToast({ providers }: RunProgress, jobId = ''): string {
  const errors = count(providers, 'error')
  const subject = jobId ? `Council job ${jobId} finished` : 'Council finished'
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
