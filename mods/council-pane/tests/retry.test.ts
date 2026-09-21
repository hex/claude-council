// ABOUTME: Tests for reading the run's retry offer and the countdown the pane shows for it
// ABOUTME: The offer file is a seconds line followed by one failed provider per line
import { test, expect } from 'bun:test'
import { parseRetryOffer, retrySection } from '../hooks/retry'

test('parseRetryOffer reads the window and the failed providers', () => {
  expect(parseRetryOffer('45\ncursor-cli\ngrok\n')).toEqual({ seconds: 45, providers: ['cursor-cli', 'grok'] })
})

test('parseRetryOffer refuses a file with no usable window or no providers', () => {
  expect(parseRetryOffer('')).toBeUndefined()
  expect(parseRetryOffer('soon\ngrok\n')).toBeUndefined()
  expect(parseRetryOffer('45\n\n')).toBeUndefined()
})

test('retrySection names a single failed provider in the singular', () => {
  expect(retrySection({ seconds: 45, providers: ['cursor-cli'] }, 0, 0).notice).toBe('cursor-cli failed')
})

test('retrySection counts the window down from when the offer was first seen', () => {
  const offer = { seconds: 45, providers: ['cursor-cli', 'grok'] }
  expect(retrySection(offer, 10_000, 17_400)).toEqual({
    kind: 'retry',
    badge: 'COUNCIL',
    notice: '2 providers failed: cursor-cli, grok',
    label: 'r \u00b7 retry',
    skipLabel: 's \u00b7 skip',
    remaining: 38,
    bar: '\u25b0\u25b0\u25b0\u25b0\u25b0\u25b0\u25b0\u25b1',
  })
  expect(retrySection(offer, 10_000, 99_000)).toEqual(expect.objectContaining({ remaining: 0 }))
})

test('the countdown bar empties as the window runs out', () => {
  const offer = { seconds: 40, providers: ['grok'] }
  expect(retrySection(offer, 0, 0).bar).toBe('\u25b0\u25b0\u25b0\u25b0\u25b0\u25b0\u25b0\u25b0')
  expect(retrySection(offer, 0, 20_000).bar).toBe('\u25b0\u25b0\u25b0\u25b0\u25b1\u25b1\u25b1\u25b1')
  expect(retrySection(offer, 0, 39_000).bar).toBe('\u25b0\u25b1\u25b1\u25b1\u25b1\u25b1\u25b1\u25b1')
  expect(retrySection(offer, 0, 40_000).bar).toBe('\u25b1\u25b1\u25b1\u25b1\u25b1\u25b1\u25b1\u25b1')
})
