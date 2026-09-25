// ABOUTME: The chip's shimmer: a warm highlight that moves across the label's
// ABOUTME: letters while something runs; the chip's background never changes

import { COLOR, SHIMMER } from './theme'

export type ChipLetter = { text: string; color: string }

// Frames the chip holds still between two passes, after the highlight has
// slid off the last letter.
export const SHIMMER_PAUSE = 10

// Without a frame the label is plain white. Only the letters' colour moves, so
// the chip draws the same in every font and terminal.
export function shimmer(label: string, frame?: number): ChipLetter[] {
  const letters = [...label]
  const at = frame === undefined ? -2 : frame % (letters.length + 1 + SHIMMER_PAUSE)
  return letters.map((text, index) => {
    const distance = Math.abs(index - at)
    return { text, color: distance === 0 ? SHIMMER.peak : distance === 1 ? SHIMMER.near : COLOR.onFill }
  })
}
