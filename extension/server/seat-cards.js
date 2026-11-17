// ABOUTME: Draws a council_ask result as one card per seat, with its answer or its error
// ABOUTME: Used by the panels that show answers; answers arrive as markdown blocks from markdown.js
function runNodes(runs) {
  return runs.map(run => run.style === 'text' ? document.createTextNode(run.text) : element(run.style, { textContent: run.text }))
}

function blockNode(block) {
  if (block.type === 'heading') return element(`h${Math.min(block.level + 2, 6)}`, {}, runNodes(block.runs))
  if (block.type === 'paragraph') return element('p', {}, runNodes(block.runs))
  if (block.type === 'code') return element('pre', {}, [element('code', { textContent: block.text })])
  if (block.type === 'rule') return element('hr')
  if (block.type === 'list') {
    return element(block.ordered ? 'ol' : 'ul', {}, block.items.map(item => {
      const node = element('li', {}, runNodes(item.runs))
      node.style.marginLeft = `${item.depth * 18}px`
      return node
    }))
  }
  if (block.type === 'table') {
    const cell = (tag, runs, at) => {
      const node = element(tag, {}, runNodes(runs))
      if (block.align[at]) node.style.textAlign = block.align[at]
      return node
    }
    const header = element('tr', {}, block.header.map((runs, at) => {
      const node = cell('th', runs, at)
      node.scope = 'col'
      return node
    }))
    const rows = block.rows.map(row => element('tr', {}, row.map((runs, at) => cell('td', runs, at))))
    // The wrapper scrolls sideways, so a wide table never widens the panel.
    return element('div', { className: 'table' }, [element('table', {}, [element('thead', {}, [header]), element('tbody', {}, rows)])])
  }
  throw new Error(`unknown markdown block ${block.type}`)
}

function seatHeading(seat) {
  // One span for the mark and the name: the heading spreads its children apart.
  return element('h2', {}, [element('span', {}, [markIcon(seat.provider, seat.model), document.createTextNode(seat.provider)]), element('small', { textContent: seat.model })])
}

// A seat's answer as its markdown. One the reader stops on is drawn as the
// text the seat wrote, under the reader's error, so the cards after it are
// still drawn.
function answerNode(answer) {
  try {
    return element('div', { className: 'answer' }, markdownBlocks(answer).map(blockNode))
  } catch (error) {
    return element('div', { className: 'answer' }, [
      element('p', { className: 'note bad', textContent: `This answer's markdown could not be read (${error.message}), so it is shown as written.` }),
      element('pre', {}, [element('code', { textContent: answer })]),
    ])
  }
}

// `whole` says what Claude has of an answer the card shortened, which differs
// by panel.
function seatCard(seat, whole) {
  const heading = seatHeading(seat)
  const body = seat.error !== undefined
    ? element('div', { className: 'note bad error', textContent: seat.error })
    : answerNode(seat.answer)
  const parts = [heading, body]
  if (seat.shortenedFrom !== undefined) {
    const shown = (seat.answer ?? seat.error).length
    parts.push(element('p', { className: 'note shortened', textContent: `Shortened here to its first ${shown.toLocaleString('en-US')} of ${seat.shortenedFrom.toLocaleString('en-US')} characters. ${whole}` }))
  }
  return element('section', {}, parts)
}

// Draws a council_ask result into `list`: a card per seat, the run's error,
// or its text when it carries no seats; the status line says which.
function showAnswers(result, list, whole) {
  const text = result?.content?.find(part => part.type === 'text')?.text ?? ''
  if (result?.isError) {
    report('failed', true)
    list.replaceChildren(element('p', { className: 'lead bad', textContent: text || 'The council run failed.' }))
    host.reportSize()
    return
  }
  const answers = result?.structuredContent?.seats
  if (!Array.isArray(answers)) {
    report('')
    list.replaceChildren(element('p', { className: 'lead', textContent: text }))
    host.reportSize()
    return
  }
  const answered = answers.filter(seat => seat.error === undefined).length
  report(`${answered} of ${answers.length} answered`, answered === 0)
  list.replaceChildren(...answers.map(seat => seatCard(seat, whole)))
  host.reportSize()
}
