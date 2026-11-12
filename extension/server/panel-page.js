// ABOUTME: Page helpers every council panel uses: building elements and the status line in the header
// ABOUTME: Elements are built with properties such as textContent, never from HTML text
function element(tag, properties, children) {
  const node = Object.assign(document.createElement(tag), properties ?? {})
  for (const child of children ?? []) node.append(child)
  return node
}

const statusLine = document.getElementById('status')

function report(text, bad) {
  statusLine.textContent = text
  statusLine.className = bad ? 'bad' : ''
}
