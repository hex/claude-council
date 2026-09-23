// ABOUTME: Tests for the band and pane chip: a label on a cell-by-cell gradient
// ABOUTME: with a light band that sweeps across it while something runs
import { test, expect } from 'bun:test'
import { chipCells } from '../hooks/chip'

const STOPS = ['rgb(200,100,0)', 'rgb(100,0,200)']

test('the label is padded by one cell each side, one cell per character', () => {
  expect(chipCells('AB', STOPS).map(c => c.text).join('')).toBe(' AB ')
})

test('the gradient runs from the first stop to the last', () => {
  const cells = chipCells('ABC', STOPS)
  expect(cells[0]?.background).toBe('rgb(200,100,0)')
  expect(cells[4]?.background).toBe('rgb(100,0,200)')
  expect(cells[2]?.background).toBe('rgb(150,50,100)')
})

test('three stops meet at the middle cell', () => {
  const cells = chipCells('ABC', ['rgb(0,0,0)', 'rgb(100,100,100)', 'rgb(200,200,200)'])
  expect(cells.map(c => c.background)).toEqual(['rgb(0,0,0)', 'rgb(50,50,50)', 'rgb(100,100,100)', 'rgb(150,150,150)', 'rgb(200,200,200)'])
})

test('the sweep lightens the cell it is on, less its neighbours, and leaves the rest', () => {
  const still = chipCells('ABCDEFGH', STOPS)
  const swept = chipCells('ABCDEFGH', STOPS, 4)
  expect(swept[4]?.background).toBe('rgb(183,111,135)')
  expect(swept[3]?.background).not.toBe(still[3]?.background)
  expect(swept[5]?.background).not.toBe(still[5]?.background)
  expect(swept[0]?.background).toBe(still[0]?.background)
  expect(swept[9]?.background).toBe(still[9]?.background)
})

test('a sweep past the chip, the pause between passes, draws it still', () => {
  expect(chipCells('AB', STOPS, 11)).toEqual(chipCells('AB', STOPS))
})

test('one stop colours every cell alike', () => {
  expect(new Set(chipCells('ABC', ['rgb(9,9,9)']).map(c => c.background))).toEqual(new Set(['rgb(9,9,9)']))
})
