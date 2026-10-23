// ABOUTME: The slim line bar the pane and the band draw: a block that sweeps a dotted track
// ABOUTME: while a seat has no share to show, or a fill of the share that is done

export const BAR_CELLS = 14

export type BarFill = { kind: 'sweep'; frame: number } | { kind: 'share'; filled: number; total: number } | { kind: 'stub' } | { kind: 'empty' }

const TRACK = '\u00b7'
const SWEEP = '\u2501\u2501\u2501\u2501'
const STUB = '\u2501\u2501'
const FILLED = '\u2501'

// Draws `block` with its first cell at `start`, clipped to the track.
function placed(block: string, start: number, cells: number): string {
  return Array.from({ length: cells }, (_, cell) => block[cell - start] ?? TRACK).join('')
}

// The sweep slides fully off the right edge before it enters again at the
// left, so one cell of it always shows and it never sits at both ends at once.
export function bar(fill: BarFill, cells = BAR_CELLS): string {
  switch (fill.kind) {
    case 'sweep': {
      const trim = Math.max(0, Math.floor((SWEEP.length - cells) / 2))
      const block = SWEEP.slice(trim, trim + Math.min(cells, SWEEP.length))
      const period = cells + block.length - 1
      return placed(block, (fill.frame % period) - (block.length - 1), cells)
    }
    case 'share': {
      const filled = fill.total > 0 ? Math.floor((Math.min(fill.filled, fill.total) / fill.total) * cells) : 0
      return FILLED.repeat(filled) + TRACK.repeat(cells - filled)
    }
    case 'stub':
      return placed(STUB.slice(0, cells), 0, cells)
    case 'empty':
      return TRACK.repeat(cells)
  }
}
