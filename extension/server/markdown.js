// ABOUTME: Reads the small part of markdown the answers panel draws: headings, paragraphs, lists, code, rules, tables
// ABOUTME: Returns plain data, never HTML, so the page builds every node itself and model text stays text
'use strict'

const FENCE = /^ {0,3}(`{3,}|~{3,})/
const HEADING = /^ {0,3}(#{1,6})[ \t]+(.*)$/
const ITEM = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
const DELIMITER_CELL = /^:?-+:?$/

const isBlank = char => char === undefined || /\s/.test(char)
const isWordChar = char => char !== undefined && /[A-Za-z0-9_]/.test(char)

// The styling markers, tried in this order at each position after inline
// code. A span opens where `opens` holds, and closes at the first later
// marker where `closes` holds with at least one character between.
const SPANS = [
  { marker: '**', style: 'strong', opens: (text, at) => !isBlank(text[at + 2]), closes: (text, at) => !isBlank(text[at - 1]) },
  { marker: '__', style: 'strong', opens: (text, at) => !isBlank(text[at + 2]), closes: (text, at) => !isBlank(text[at - 1]) },
  { marker: '*', style: 'em', opens: (text, at) => !isBlank(text[at + 1]) && text[at + 1] !== '*', closes: (text, at) => !isBlank(text[at - 1]) && text[at - 1] !== '*' },
  // Not inside a word, so snake_case stays as written.
  {
    marker: '_',
    style: 'em',
    opens: (text, at) => !isWordChar(text[at - 1]) && !isBlank(text[at + 1]) && text[at + 1] !== '_',
    closes: (text, at) => !isBlank(text[at - 1]) && text[at - 1] !== '_' && !isWordChar(text[at + 1]),
  },
]

// The first of the ascending positions that is at least `from`. Asked with
// a `from` that never decreases, so one pass over the positions serves a
// whole line: that keeps the reader linear in the answer's length, which a
// model controls.
function nextPosition(positions) {
  let index = 0
  return from => {
    while (index < positions.length && positions[index] < from) index++
    return index < positions.length ? positions[index] : -1
  }
}

// Where each inline code span in `text` closes: a map from the length of a
// run of backticks to a nextPosition over the runs of that length, since a
// run closes only on a run of the same length.
function tickClosers(text) {
  const tickRuns = new Map()
  for (let at = 0; at < text.length;) {
    if (text[at] !== '`') { at++; continue }
    let end = at
    while (text[end] === '`') end++
    if (!tickRuns.has(end - at)) tickRuns.set(end - at, [])
    tickRuns.get(end - at).push(at)
    at = end
  }
  return new Map([...tickRuns].map(([length, starts]) => [length, nextPosition(starts)]))
}

// One line of text as styled runs: {style: 'text' | 'strong' | 'em' | 'code', text}.
// Inline code comes first, so markers inside it stay literal.
function markdownInline(text) {
  const tickCloser = tickClosers(text)
  const closers = SPANS.map(span => {
    const positions = []
    for (let at = text.indexOf(span.marker); at !== -1; at = text.indexOf(span.marker, at + 1)) {
      if (span.closes(text, at)) positions.push(at)
    }
    return nextPosition(positions)
  })

  const runs = []
  let plainFrom = 0
  const emit = (from, style, inner, to) => {
    if (from > plainFrom) runs.push({ style: 'text', text: text.slice(plainFrom, from) })
    runs.push({ style, text: inner })
    plainFrom = to
  }
  for (let at = 0; at < text.length;) {
    if (text[at] === '`') {
      let end = at
      while (text[end] === '`') end++
      const close = tickCloser.get(end - at)(end)
      if (close === -1) { at = end; continue }
      emit(at, 'code', text.slice(end, close).replace(/^ (.*) $/, '$1'), close + end - at)
      at = plainFrom
      continue
    }
    const index = SPANS.findIndex(span => text.startsWith(span.marker, at) && span.opens(text, at))
    const close = index === -1 ? -1 : closers[index](at + SPANS[index].marker.length + 1)
    if (close === -1) { at++; continue }
    const { marker, style } = SPANS[index]
    emit(at, style, text.slice(at + marker.length, close), close + marker.length)
    at = plainFrom
  }
  if (plainFrom < text.length) runs.push({ style: 'text', text: text.slice(plainFrom) })
  return runs
}

// A line's table cells, or null when no pipe divides it. The pipes at either
// end are optional: models write tables both ways. A pipe written as \| or
// inside a code span stays in its cell, where models mean it as text.
function tableCells(line) {
  const text = line.trim()
  if (!text.includes('|')) return null
  const tickCloser = tickClosers(text)
  const dividers = []
  for (let at = 0; at < text.length; at++) {
    if (text[at] === '\\') at++
    else if (text[at] === '|') dividers.push(at)
    else if (text[at] === '`') {
      let end = at
      while (text[end] === '`') end++
      // A backslash before a run skips its first backtick, and the line may
      // hold no run as long as what is left: that has no closer.
      const close = tickCloser.get(end - at)?.(end) ?? -1
      at = (close === -1 ? end : close + end - at) - 1
    }
  }
  if (dividers.length === 0) return null
  const cells = [...dividers, text.length].map((divider, at) => text.slice(at === 0 ? 0 : dividers[at - 1] + 1, divider))
  if (dividers[0] === 0) cells.shift()
  if (dividers[dividers.length - 1] === text.length - 1) cells.pop()
  return cells.map(cell => cell.trim().replaceAll('\\|', '|'))
}

// The answer as blocks: heading {level, runs}, paragraph {runs}, list
// {ordered, items: [{depth, runs}]}, code {text}, rule and table {align,
// header: [runs], rows: [[runs]]}. A paragraph keeps its line breaks, so
// markdown outside this set reads as the lines the model wrote.
function markdownBlocks(markdown) {
  const lines = String(markdown).replace(/\r\n?/g, '\n').split('\n')
  const blocks = []
  let paragraph = null
  let list = null
  let table = null
  const close = () => { paragraph = null; list = null; table = null }
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const fence = line.match(FENCE)
    if (fence) {
      close()
      const code = []
      index++
      while (index < lines.length && !lines[index].trimStart().startsWith(fence[1])) code.push(lines[index++])
      blocks.push({ type: 'code', text: code.join('\n') })
      continue
    }
    // A blank line ends a paragraph but not a list: models put one between
    // items, and an indented paragraph after one still belongs to its item.
    if (line.trim() === '') { paragraph = null; table = null; continue }
    // A table is a header row whose next line is a delimiter row with as
    // many cells; anything less stays the lines the model wrote.
    if (!table) {
      const header = tableCells(line)
      const delimiter = header && index + 1 < lines.length ? tableCells(lines[index + 1]) : null
      if (header?.length > 0 && delimiter?.length === header.length && delimiter.every(cell => DELIMITER_CELL.test(cell))) {
        close()
        const align = delimiter.map(cell => cell.startsWith(':') && cell.endsWith(':') ? 'center' : cell.endsWith(':') ? 'right' : cell.startsWith(':') ? 'left' : null)
        table = { type: 'table', align, header, rows: [] }
        blocks.push(table)
        index++
        continue
      }
    } else {
      // A row keeps the cells it has: dropping extra ones would lose model
      // text, and padding short ones under a header thousands of cells wide
      // would grow the data with the square of the answer's length.
      const cells = tableCells(line)
      if (cells) { table.rows.push(cells); continue }
      table = null
    }
    const heading = line.match(HEADING)
    if (heading) {
      close()
      // Trailing spaces and closing #s go, cut by hand: a pattern anchored at
      // the line's end rescans the rest of the line from every # it meets.
      let end = heading[2].length
      while (end > 0 && ' \t#'.includes(heading[2][end - 1])) end--
      blocks.push({ type: 'heading', level: heading[1].length, runs: markdownInline(heading[2].slice(0, end)) })
      continue
    }
    if (RULE.test(line)) {
      close()
      blocks.push({ type: 'rule' })
      continue
    }
    const item = line.match(ITEM)
    if (item) {
      const ordered = /\d/.test(item[2])
      const depth = Math.floor(item[1].replace(/\t/g, '    ').length / 2)
      // A top-level item of the other kind starts a list of its own.
      if (!list || (depth === 0 && list.ordered !== ordered)) {
        paragraph = null
        list = { type: 'list', ordered, items: [] }
        blocks.push(list)
      }
      list.items.push({ depth, text: item[3] })
      continue
    }
    if (list && /^[ \t]/.test(line)) {
      list.items[list.items.length - 1].text += ` ${line.trim()}`
      continue
    }
    list = null
    if (paragraph) paragraph.text += `\n${line}`
    else {
      paragraph = { type: 'paragraph', text: line }
      blocks.push(paragraph)
    }
  }
  return blocks.map(block => {
    if (block.type === 'paragraph') return { type: 'paragraph', runs: markdownInline(block.text) }
    if (block.type === 'list') return { type: 'list', ordered: block.ordered, items: block.items.map(({ depth, text }) => ({ depth, runs: markdownInline(text) })) }
    if (block.type === 'table') return { type: 'table', align: block.align, header: block.header.map(cell => markdownInline(cell)), rows: block.rows.map(row => row.map(cell => markdownInline(cell))) }
    return block
  })
}

if (typeof module !== 'undefined') module.exports = { markdownBlocks, markdownInline }
