// ABOUTME: Where a council run's pane is drawn: inside Claude Code by this mod, or in tmux
// ABOUTME: The choice is asked once, kept in the plugin store, and changed with /council-pane mod|tmux|ask

export type PaneHost = 'mod' | 'tmux'

export const HOST_STORE_KEY = 'pane_host'

export const HOST_QUESTION = 'Where should the council pane open?'

export const HOST_LABELS: Record<PaneHost, string> = {
  mod: 'Inside Claude Code',
  tmux: 'tmux pane',
}

// A query starts a pane; fetching or cancelling a job, and listing models, do not.
export function isCouncilRun(command: string): boolean {
  return /run-council\.sh/.test(command) && !/--(result|cancel)[=\s]/.test(command)
}

export function hostFrom(value: unknown): PaneHost | undefined {
  if (value === 'mod' || value === HOST_LABELS.mod) return 'mod'
  if (value === 'tmux' || value === HOST_LABELS.tmux) return 'tmux'
  return undefined
}

export type PaneCommand = { action: 'reopen' } | { action: 'choose'; host: PaneHost } | { action: 'forget' } | { action: 'unknown' }

export function paneCommand(args: string): PaneCommand {
  const word = args.trim().toLowerCase()
  if (word === '') return { action: 'reopen' }
  if (word === 'ask') return { action: 'forget' }
  const host = hostFrom(word)
  return host ? { action: 'choose', host } : { action: 'unknown' }
}
