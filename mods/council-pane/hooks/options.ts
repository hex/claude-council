// ABOUTME: Reads the pane's settings from the options the engine passes to register
// ABOUTME: Field names match plugin.json's userConfig; a missing or mistyped value takes the default

import { hostSetting, type HostSetting } from './host'

export type PaneOptions = {
  host: HostSetting
  collapsesWhenDone: boolean
  wakesOnAsyncDone: boolean
  offersTool: boolean
  // How long a specialist round may run, in whole seconds; 0 means no limit.
  roundLimitSeconds: number
}

// The setting is in minutes and may be fractional; the round takes whole
// seconds, and a positive limit never rounds down to 0, which means none.
function limitSeconds(minutes: unknown, fallback: number): number {
  if (typeof minutes !== 'number' || !Number.isFinite(minutes) || minutes < 0) return fallback
  return minutes === 0 ? 0 : Math.max(1, Math.round(minutes * 60))
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
    roundLimitSeconds: limitSeconds(options.specialist_round_limit, 3600),
  }
}
