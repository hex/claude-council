// ABOUTME: Reads the retry offer a council run leaves in its watch dir and shapes the pane's countdown for it
// ABOUTME: The run waits on the offer; the pane accepts by renaming it to .retry or declines with .retry-declined

import { bar, BAND_CELLS } from './bar'

export type RetryOffer = { seconds: number; providers: string[] }

export type RetrySection = { kind: 'retry'; notice: string; remaining: number; bar: string }


export function parseRetryOffer(text: string): RetryOffer | undefined {
  const [window = '', ...rest] = text.split('\n').map(line => line.trim())
  const providers = rest.filter(Boolean)
  if (!/^[1-9]\d*$/.test(window) || providers.length === 0) return undefined
  return { seconds: Number(window), providers }
}

export function retrySection(offer: RetryOffer, seenAtMs: number, nowMs: number): RetrySection {
  const remaining = Math.max(0, offer.seconds - Math.floor((nowMs - seenAtMs) / 1000))
  const { providers } = offer
  // Rounded up, so the countdown empties only when no time is left.
  const filled = Math.ceil((remaining / offer.seconds) * BAND_CELLS)
  const notice = providers.length === 1 ? `${providers[0]} failed` : `${providers.length} providers failed: ${providers.join(', ')}`
  return { kind: 'retry', notice, remaining, bar: bar({ kind: 'share', filled, total: BAND_CELLS }, BAND_CELLS) }
}
