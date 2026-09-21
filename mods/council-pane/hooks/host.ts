// ABOUTME: Where a council run's pane is drawn: inside Claude Code by this mod, or in tmux
// ABOUTME: The pane_host setting decides; on ask the answer is asked once, kept in the plugin store, and forgotten with /council-pane ask

export type PaneHost = 'mod' | 'tmux'

export const HOST_STORE_KEY = 'pane_host'

export const HOST_QUESTION = 'Where should the council pane open?'

export const HOST_LABELS: Record<PaneHost, string> = {
  mod: 'Inside Claude Code',
  tmux: 'tmux pane',
}

// A query starts a pane; fetching, cancelling or listing jobs, listing models
// and asking for help do not, and neither does a command that only names the
// script (a grep, a cat): the script has to be what bash is given to run.
export function isCouncilRun(command: string): boolean {
  return /\bbash\s+["']?[^\s"']*run-council\.sh\b/.test(command) && !/--(result|cancel|jobs|help|list-[a-z-]+)(=|\s|$)/.test(command)
}

export function hostFrom(value: unknown): PaneHost | undefined {
  if (value === 'mod' || value === HOST_LABELS.mod) return 'mod'
  if (value === 'tmux' || value === HOST_LABELS.tmux) return 'tmux'
  return undefined
}

export type HostSetting = 'ask' | 'claude-code' | 'tmux'

export function hostSetting(value: unknown): HostSetting {
  return value === 'claude-code' || value === 'tmux' ? value : 'ask'
}

// The settings row decides outright unless it says ask; then the remembered
// answer does, and with none the person is asked. Outside tmux the pane in
// Claude Code is the only one there is, so nothing is asked there.
export function decideHost(facts: { setting: HostSetting; remembered: PaneHost | undefined; isInTmux: boolean }): PaneHost | 'ask' {
  if (facts.setting === 'claude-code') return 'mod'
  if (facts.setting === 'tmux') return 'tmux'
  if (!facts.isInTmux) return 'mod'
  return facts.remembered ?? 'ask'
}

export function hostRowLabel(label: string, setting: HostSetting, remembered: PaneHost | undefined): string {
  if (setting !== 'ask' || !remembered) return label
  return `${label} \u2192 ${remembered === 'mod' ? 'Claude' : 'tmux'}`
}

export type PaneCommand = { action: 'reopen' } | { action: 'forget' } | { action: 'unknown' }

export function paneCommand(args: string): PaneCommand {
  const word = args.trim().toLowerCase()
  if (word === '') return { action: 'reopen' }
  return word === 'ask' ? { action: 'forget' } : { action: 'unknown' }
}
