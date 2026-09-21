// ABOUTME: Reads the retry offer a council run leaves in its watch dir and shapes the pane's countdown for it
// ABOUTME: The run waits on the offer; the pane accepts by renaming it to .retry or declines with .retry-declined

export type RetryOffer = { seconds: number; providers: string[] }

export type RetrySection = { kind: 'retry'; badge: string; notice: string; label: string; skipLabel: string; remaining: number }

export function parseRetryOffer(text: string): RetryOffer | undefined {
  const [window = '', ...rest] = text.split('\n').map(line => line.trim())
  const providers = rest.filter(Boolean)
  if (!/^[1-9]\d*$/.test(window) || providers.length === 0) return undefined
  return { seconds: Number(window), providers }
}

export function retrySection(offer: RetryOffer, seenAtMs: number, nowMs: number): RetrySection {
  const remaining = Math.max(0, offer.seconds - Math.floor((nowMs - seenAtMs) / 1000))
  const { providers } = offer
  const notice = providers.length === 1 ? `${providers[0]} failed` : `${providers.length} providers failed: ${providers.join(', ')}`
  // The labels name their hotkeys: a terminal Button draws as `[ label ]` and shows no key of its own.
  return { kind: 'retry', badge: 'COUNCIL', notice, label: 'r \u00b7 retry', skipLabel: 's \u00b7 skip', remaining }
}
