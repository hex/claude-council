// ABOUTME: Lifts the council synthesis out of the assistant's reply so the pane can show it
// ABOUTME: Nothing on disk holds the synthesis; the reply's "## Synthesis" section is its only source

export function extractSynthesis(reply: string): string | undefined {
  const lines = reply.split('\n')
  const start = lines.findIndex(line => /^#{1,6}\s+Synthesis\s*$/.test(line))
  if (start < 0) return undefined
  const rest = lines.slice(start + 1)
  const saved = rest.findIndex(line => line.includes('Full output saved'))
  const body = (saved < 0 ? rest : rest.slice(0, saved)).join('\n').replace(/\n-{3,}\s*$/, '').trim()
  return body.replace(/^-{3,}$/, '').trim() || undefined
}
