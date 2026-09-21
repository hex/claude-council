// ABOUTME: Tests for rewriting markdown tables too wide for the pane as stacked records
// ABOUTME: Expected output is written out by hand from the GFM table in each fixture
import { test, expect } from 'bun:test'
import { fitTables } from '../hooks/tables'

const WIDE = [
  'Intro.',
  '',
  '| Factor | SQLite | PostgreSQL |',
  '|---|:---:|---|',
  '| **Setup** | Zero setup, works out of the box | Requires a running service |',
  '| Backup | Copy a file | `pg_dump` |',
  '',
  'Verdict: SQLite.',
].join('\n')

test('a table wider than the pane becomes one record per row, labelled by the header', () => {
  expect(fitTables(WIDE, 40)).toBe(
    [
      'Intro.',
      '',
      '**Setup**',
      '- SQLite: Zero setup, works out of the box',
      '- PostgreSQL: Requires a running service',
      '',
      '**Backup**',
      '- SQLite: Copy a file',
      '- PostgreSQL: `pg_dump`',
      '',
      'Verdict: SQLite.',
    ].join('\n'),
  )
})

test('a table that fits the pane is left as written', () => {
  expect(fitTables(WIDE, 200)).toBe(WIDE)
})

test('a table inside a code fence is never rewritten', () => {
  const fenced = ['```', '| a | b |', '|---|---|', '| a very long cell indeed | another long cell here |', '```'].join('\n')
  expect(fitTables(fenced, 10)).toBe(fenced)
})

test('pipes without a separator row are ordinary text', () => {
  const text = 'use a | b to pipe\nthen c | d'
  expect(fitTables(text, 5)).toBe(text)
})
