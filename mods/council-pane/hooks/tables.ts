// ABOUTME: Rewrites markdown tables too wide for the pane as one labelled record per row
// ABOUTME: The engine lays a table out to the terminal's width, so a wide one wraps into noise in a narrower pane

const SEPARATOR = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/
const FENCE = /^\s*(```|~~~)/

function cells(row: string): string[] {
  const inner = row.trim().replace(/^\|/, '').replace(/\|$/, '')
  return inner.split(/(?<!\\)\|/).map(cell => cell.trim())
}

// Each column takes its longest cell plus a border and two spaces of padding.
function drawnWidth(rows: string[][]): number {
  const columns = Math.max(...rows.map(row => row.length))
  let width = 1
  for (let column = 0; column < columns; column++) {
    width += Math.max(...rows.map(row => (row[column] ?? '').length)) + 3
  }
  return width
}

function records(header: string[], body: string[][]): string[] {
  const lines: string[] = []
  body.forEach((row, index) => {
    if (index > 0) lines.push('')
    const label = row[0] ?? ''
    lines.push(/^\*\*.*\*\*$/.test(label) ? label : `**${label}**`)
    for (let column = 1; column < header.length; column++) {
      lines.push(`- ${header[column]}: ${row[column] ?? ''}`)
    }
  })
  return lines
}

export function fitTables(markdown: string, paneColumns: number): string {
  const lines = markdown.split('\n')
  const out: string[] = []
  let isFenced = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? ''
    if (FENCE.test(line)) isFenced = !isFenced
    const separator = lines[i + 1] ?? ''
    const isTable = !isFenced && line.includes('|') && separator.includes('-') && SEPARATOR.test(separator)
    if (!isTable) {
      out.push(line)
      continue
    }
    let end = i + 2
    while (end < lines.length && (lines[end] ?? '').includes('|') && (lines[end] ?? '').trim() !== '') end++
    const header = cells(line)
    const body = lines.slice(i + 2, end).map(cells)
    if (drawnWidth([header, ...body]) <= paneColumns) out.push(...lines.slice(i, end))
    else out.push(...records(header, body))
    i = end - 1
  }
  return out.join('\n')
}
