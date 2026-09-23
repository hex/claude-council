// ABOUTME: Tests for the chip's shimmer: a highlight that moves across the
// ABOUTME: label's letters while something runs, on an unchanging background
import { test, expect } from 'bun:test'
import { shimmer, SHIMMER_PAUSE } from '../hooks/chip'

const W = 'white'
const PEAK = 'rgb(255,226,150)'
const NEAR = 'rgb(255,242,208)'

test('a still chip is white letter for letter', () => {
  expect(shimmer('ABC')).toEqual([{ text: 'A', color: W }, { text: 'B', color: W }, { text: 'C', color: W }])
})

test('the highlight sits on the frame\'s letter and tints the letters either side', () => {
  expect(shimmer('ABCDE', 2).map(c => c.color)).toEqual([W, NEAR, PEAK, NEAR, W])
})

test('at either end the highlight has one neighbour', () => {
  expect(shimmer('ABC', 0).map(c => c.color)).toEqual([PEAK, NEAR, W])
  expect(shimmer('ABC', 2).map(c => c.color)).toEqual([W, NEAR, PEAK])
})

test('the highlight slides off the end, then the chip holds still for the pause', () => {
  expect(shimmer('ABC', 3).map(c => c.color)).toEqual([W, W, NEAR])
  expect(shimmer('ABC', 4).map(c => c.color)).toEqual([W, W, W])
  expect(shimmer('ABC', 3 + SHIMMER_PAUSE).map(c => c.color)).toEqual([W, W, W])
  expect(shimmer('ABC', 4 + SHIMMER_PAUSE).map(c => c.color)).toEqual([PEAK, NEAR, W])
})
