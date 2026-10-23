// ABOUTME: Tests for the slim line bar: the sweep's position frame by frame,
// ABOUTME: a share's fill, the failed stub and the empty track, at any width
import { test, expect } from 'bun:test'
import { bar } from '../hooks/bar'

test('the sweep enters at the left edge on frame 0 and moves one cell a frame', () => {
  expect(bar({ kind: 'sweep', frame: 0 })).toBe('━·············')
  expect(bar({ kind: 'sweep', frame: 3 })).toBe('━━━━··········')
  expect(bar({ kind: 'sweep', frame: 7 })).toBe('····━━━━······')
})

test('the sweep leaves at the right edge, then enters again at the left', () => {
  expect(bar({ kind: 'sweep', frame: 13 })).toBe('··········━━━━')
  expect(bar({ kind: 'sweep', frame: 16 })).toBe('·············━')
  expect(bar({ kind: 'sweep', frame: 17 })).toBe('━·············')
  expect(bar({ kind: 'sweep', frame: 20 })).toBe('━━━━··········')
})

test('a share fills its whole cells and reads full only when every part is done', () => {
  expect(bar({ kind: 'share', filled: 0, total: 4 })).toBe('··············')
  expect(bar({ kind: 'share', filled: 2, total: 4 })).toBe('━━━━━━━·······')
  expect(bar({ kind: 'share', filled: 3, total: 4 })).toBe('━━━━━━━━━━····')
  expect(bar({ kind: 'share', filled: 4, total: 4 })).toBe('━━━━━━━━━━━━━━')
})

test('a share of nothing is the empty track', () => {
  expect(bar({ kind: 'share', filled: 0, total: 0 })).toBe('··············')
})

test('the stub is a short line at the left, and empty is the bare track', () => {
  expect(bar({ kind: 'stub' })).toBe('━━············')
  expect(bar({ kind: 'empty' })).toBe('··············')
})

test('a narrow bar keeps its own width for every fill', () => {
  expect(bar({ kind: 'sweep', frame: 4 }, 5)).toBe('·━━━━')
  expect(bar({ kind: 'sweep', frame: 6 }, 5)).toBe('···━━')
  expect(bar({ kind: 'sweep', frame: 9 }, 5)).toBe('━━···')
  expect(bar({ kind: 'sweep', frame: 2 }, 3)).toBe('━━━')
  expect(bar({ kind: 'share', filled: 1, total: 3 }, 5)).toBe('━····')
  expect(bar({ kind: 'stub' }, 5)).toBe('━━···')
  expect(bar({ kind: 'empty' }, 5)).toBe('·····')
})
