// ABOUTME: Reads the pane's settings from the options the engine passes to register
// ABOUTME: Field names match plugin.json's userConfig; a missing or mistyped value takes the default

export type PaneOptions = {
  isEnabled: boolean
  collapsesWhenDone: boolean
  wakesOnAsyncDone: boolean
  offersTool: boolean
}

function flag(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback
}

export function paneOptions(options: Record<string, unknown>): PaneOptions {
  return {
    isEnabled: flag(options.pane, true),
    collapsesWhenDone: flag(options.collapse_when_done, true),
    wakesOnAsyncDone: flag(options.wake_on_async_done, false),
    offersTool: flag(options.council_tool, false),
  }
}
