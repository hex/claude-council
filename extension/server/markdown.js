// ABOUTME: Reads the small part of markdown the answers panel draws: headings, paragraphs, lists, code, rules
// ABOUTME: Returns plain data, never HTML, so the page builds every node itself and model text stays text
'use strict'

const FENCE = /^ {0,3}(`{3,}|~{3,})/
const HEADING = /^ {0,3}(#{1,6})[ \t]+(.*?)[ \t#]*$/
const ITEM = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
// Inline code first, so markers inside it stay literal; then bold, then italic.
const INLINE = /(`+)([\s\S]*?[^`])\1(?!`)|\*\*(?=\S)([\s\S]*?\S)\*\*|__(?=\S)([\s\S]*?\S)__|\*(?=[^\s*])([\s\S]*?[^\s*])\*|(?<![A-Za-z0-9_])_(?=[^\s_])([\s\S]*?[^\s_])_(?![A-Za-z0-9_])/g

// One line of text as styled runs: {style: 'text' | 'strong' | 'em' | 'code', text}.
function markdownInline(text) {
  const runs = []
  let last = 0
  for (const match of text.matchAll(INLINE)) {
    if (match.index > last) runs.push({ style: 'text', text: text.slice(last, match.index) })
    if (match[2] !== undefined) runs.push({ style: 'code', text: match[2].replace(/^ (.*) $/, '$1') })
    else if (match[3] !== undefined || match[4] !== undefined) runs.push({ style: 'strong', text: match[3] ?? match[4] })
    else runs.push({ style: 'em', text: match[5] ?? match[6] })
    last = match.index + match[0].length
  }
  if (last < text.length) runs.push({ style: 'text', text: text.slice(last) })
  return runs
}

// The answer as blocks: heading {level, runs}, paragraph {runs}, list
// {ordered, items: [{depth, runs}]}, code {text} and rule. A paragraph keeps
// its line breaks, so a table or other markdown outside this set reads as
// the lines the model wrote.
function markdownBlocks(markdown) {
  const lines = String(markdown).replace(/\r\n?/g, '\n').split('\n')
  const blocks = []
  let paragraph = null
  let list = null
  const close = () => { paragraph = null; list = null }
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
    if (line.trim() === '') { close(); continue }
    const heading = line.match(HEADING)
    if (heading) {
      close()
      blocks.push({ type: 'heading', level: heading[1].length, runs: markdownInline(heading[2]) })
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
    return block
  })
}

if (typeof module !== 'undefined') module.exports = { markdownBlocks, markdownInline }
