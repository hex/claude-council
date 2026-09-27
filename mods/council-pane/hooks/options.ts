// ABOUTME: Reads the pane's settings from the options the engine passes to register
// ABOUTME: Field names match plugin.json's userConfig; a missing or mistyped value takes the default

import { hostSetting, type HostSetting } from './host'

export type PaneOptions = {
  host: HostSetting
  collapsesWhenDone: boolean
  wakesOnAsyncDone: boolean
  offersTool: boolean
  // How long a specialist round may run, in whole minutes; 0 means no limit.
  roundLimitMinutes: number
}

function wholeMinutes(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : fallback
}

function flag(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback
}

export function paneOptions(options: Record<string, unknown>): PaneOptions {
  return {
    host: hostSetting(options.pane_host),
    collapsesWhenDone: flag(options.collapse_when_done, true),
    wakesOnAsyncDone: flag(options.wake_on_async_done, false),
    offersTool: flag(options.council_tool, true),
    roundLimitMinutes: wholeMinutes(options.specialist_round_limit, 60),
  }
}
